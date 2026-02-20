---
title: 분산 트랜잭션 - 2. 외부 결제 API 연동과 커넥션 풀 고갈
date: 2026-02-20
categories: [Spring, Project]
tags: [spring-boot, jpa, connection-pool, HikariCP, payment-api, load-test, k6]
image: 
---

## 분산 트랜잭션 #2 - 외부 결제 API 연동과 커넥션 풀 고갈

### 이번 Phase의 목표
`Phase 1`의 모놀리식 주문 시스템에 **Mock 결제 서버**를 추가한다.
`@Transactional` 안에서 외부 `API`를 호출하면 어떤 일이 벌어지는지 직접 확인해본다.

결론부터 말하면, **정합성은 여전히 지켜졌지만 시스템이 사실상 마비**되었다.

---

## 시스템 구조

Phase 1과 동일한 모놀리식 구조에 Mock 결제 서버가 추가되었다. Mock 결제 서버는 같은 Spring Boot 애플리케이션 내에 별도 Controller로 구현했다.

```
Client (k6) → Spring Boot → MySQL
                 │
                 ├── OrderService (주문 생성 + 흐름 조율)
                 ├── StockService (재고 차감)
                 ├── PaymentService (결제 처리)
                 │       │
                 │       └── MockPaymentClient ──→ MockPaymentController
                 │                                   (70% 성공 / 30% 실패)
                 │                                   (100ms ~ 1000ms 지연)
                 └── DB (단일 트랜잭션)
```

실제 운영 환경에서는 `MockPaymentController` 자리에 토스페이먼츠, 카카오페이 같은 외부 PG사 API가 들어간다. Mock 서버를 같은 애플리케이션 안에 둔 이유는 Phase 2의 핵심이 "트랜잭션 안에서 외부 API 호출 시 문제 체감"이기 때문이다. 서비스 분리는 Phase 3 이후에 진행한다.

---

## 핵심 구현

### Phase 1 → Phase 2 변경점

Phase 1에서는 `order.markPaid()`로 바로 완료 처리했다. Phase 2에서는 실제 결제 흐름이 추가되었다.

```
Phase 1: 재고 차감 → 주문 생성 → markPaid() → 끝
Phase 2: 재고 차감 → 주문 생성(PENDING) → 결제 요청 → 성공이면 PAID, 실패면 FAILED + 재고 복구
```

### 주문 흐름

여전히 하나의 `@Transactional` 안에서 모든 과정이 처리된다. **이것이 문제의 핵심이다.**

```java
@Transactional
public OrderResponse createOrder(Long memberId, Long productId, int quantity) {
    // 1. 회원 존재 확인
    memberRepository.findById(memberId)
            .orElseThrow(() -> new BusinessException(ErrorCode.MEMBER_NOT_FOUND));

    // 2. 상품 조회
    Product product = productRepository.findById(productId)
            .orElseThrow(() -> new BusinessException(ErrorCode.PRODUCT_NOT_FOUND));

    // 3. 중복 주문 확인
    if (orderRepository.existsByMemberIdAndProductId(memberId, productId)) {
        throw new BusinessException(ErrorCode.ORDER_ALREADY_EXISTS);
    }

    // 4. 재고 차감 (낙관적 락)
    stockService.decrease(productId, quantity);

    // 5. 주문 생성 (PENDING 상태)
    Order order = Order.create(memberId, productId, quantity, product.getPrice());
    orderRepository.save(order);

    // 6. 결제 요청 ← 여기서 100ms ~ 1000ms 블로킹
    Payment payment = paymentService.processPayment(order.getId(), order.getTotalPrice());

    // 7. 결제 결과에 따라 주문 상태 변경
    if (payment.getStatus() == PaymentStatus.SUCCESS) {
        order.markPaid();
    } else {
        order.markFailed();
        stockService.restore(productId, quantity);  // 결제 실패 → 재고 복구
    }

    return OrderResponse.from(order);
}
```

6번에서 외부 API를 호출하는 동안 이 트랜잭션은 **DB 커넥션을 계속 물고 있다.** 이 한 줄이 모든 문제의 시작이다.

### Mock 결제 서버

실제 PG사 대신 사용하는 가짜 결제 API다. 성공/실패/지연을 시뮬레이션하여 분산 트랜잭션 문제를 재현한다.

```java
@RestController
@RequestMapping("/mock/payment")
public class MockPaymentController {

    private static final double SUCCESS_RATE = 0.7;
    private static final int MIN_DELAY_MS = 100;
    private static final int MAX_DELAY_MS = 1000;

    @PostMapping("/approve")
    public ApiResponse<MockPaymentResponse> approve(
            @RequestParam String paymentCode,
            @RequestParam int amount) {

        simulateDelay();  // 100ms ~ 1000ms 랜덤 지연

        boolean isSuccess = ThreadLocalRandom.current().nextDouble() < SUCCESS_RATE;

        if (isSuccess) {
            return ApiResponse.ok(MockPaymentResponse.success(transactionId));
        } else {
            return ApiResponse.ok(MockPaymentResponse.fail(getRandomFailReason()));
        }
    }
}
```

| 설정 | 값 |
| :--- | :--- |
| 결제 성공률 | 70% |
| 결제 실패률 | 30% |
| 응답 지연 | 100ms ~ 1000ms |
| 실패 사유 | 잔액 부족, 카드 한도 초과, 카드사 점검 중 등 |

### 결제 실패 시 재고 복구

Phase 1에서는 낙관적 락 충돌 시 트랜잭션 전체가 롤백되어 재고가 자동으로 복구되었다. 하지만 Phase 2에서는 상황이 다르다.

```
재고 차감 성공 → 결제 실패 → ???
```

재고는 이미 차감되었는데 결제가 실패한 것이다. 트랜잭션이 아직 열려있으니 롤백할 수도 있지만, Phase 2에서는 **명시적으로 `stockService.restore()`를 호출**하여 재고를 복구하는 방식을 택했다.

```java
if (payment.getStatus() != PaymentStatus.SUCCESS) {
    order.markFailed();
    stockService.restore(productId, quantity);  // 명시적 재고 복구
}
```

이렇게 한 이유는 Phase 3 이후에서 트랜잭션 경계가 분리되면 **자동 롤백이 불가능**해지기 때문이다. 지금부터 보상 트랜잭션의 흐름에 익숙해져야 한다.

### RestTemplate - 외부 API 호출

결제 서버와의 통신은 `RestTemplate`을 사용한다. Java 코드에서 HTTP 요청을 보내는 역할이다.

```java
@Component
public class MockPaymentClient {

    public MockPaymentResponse requestPayment(String paymentCode, int amount) {
        String url = UriComponentsBuilder
                .fromUriString(paymentBaseUrl + "/mock/payment/approve")
                .queryParam("paymentCode", paymentCode)
                .queryParam("amount", amount)
                .toUriString();

        ResponseEntity<ApiResponse<MockPaymentResponse>> response = restTemplate.exchange(
                url, HttpMethod.POST, null, new ParameterizedTypeReference<>() {}
        );

        return response.getBody().data();
    }
}
```

결제 서버 URL은 `application-local.yml`에서 관리한다. 코드 수정 없이 설정만 바꾸면 실제 PG사로 교체할 수 있는 구조다.

```yaml
payment:
  mock:
    base-url: http://localhost:8080   # 나중에 https://api.tosspayments.com 으로 교체 가능
```

---

## DB 스키마

Phase 1의 테이블에 `payments` 테이블이 추가되었다.

```sql
CREATE TABLE payments (
    id                  BIGINT          NOT NULL AUTO_INCREMENT,
    payment_code        VARCHAR(50)     NOT NULL,
    order_id            BIGINT          NOT NULL,
    amount              INT             NOT NULL,
    status              VARCHAR(20)     NOT NULL DEFAULT 'PENDING',
    pg_transaction_id   VARCHAR(100)    NULL,
    failed_reason       VARCHAR(255)    NULL,
    paid_at             DATETIME(6)     NULL,
    created_at          DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at          DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_payments_payment_code (payment_code),
    UNIQUE KEY uk_payments_order_id (order_id),
    CONSTRAINT fk_payments_order FOREIGN KEY (order_id) REFERENCES orders (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

Payment 엔티티도 Order와 동일하게 정적 팩토리 메서드를 사용한다. `paymentCode`는 시스템 자동 발급, `status`는 항상 `PENDING`으로 시작하는 규칙을 강제하기 위해서다.

---

## 왜 낙관적 락을 그대로 유지했는가?

Phase 2에서 동시성 제어 방식을 바꾸지 않은 이유가 있다. Phase 2의 목적은 **결제 API가 트랜잭션 안에 들어왔을 때의 문제**를 보여주는 것이다.

한 번에 두 가지를 바꾸면 뭐가 원인인지 알 수 없다. 결제 추가라는 **변수 하나만** 도입하고 나머지는 Phase 1과 동일하게 유지해야, Phase 1 결과와의 비교가 의미 있다.

> 이전 프로젝트(쿠폰 발급 시스템)에서 낙관적 락 → 비관적 락 → Redis 분산 락 → Redis DECR + Kafka 순서로 동시성 제어를 발전시킨 경험이 있다. 이번 프로젝트의 핵심은 동시성 제어가 아니라 **분산 트랜잭션**이므로, 동시성 제어 방식 변경은 이번 프로젝트의 범위에 포함시키지 않았다.

---

## 부하 테스트

### 테스트 환경

| 설정 | 값 |
| :--- | :--- |
| **동시 사용자(VUs)** | 1,000명 |
| **사용자당 요청** | 1회 |
| **상품 재고** | 100개 |
| **시나리오** | shared-iterations (1,000명이 각 1회 주문) |
| **maxDuration** | 60초 (Phase 1의 30초에서 증가 - 결제 지연 고려) |
| **HikariCP 커넥션 풀** | 20개 |

### 테스트 실행

```bash
# 데이터 초기화
curl -X POST http://host.docker.internal:8080/api/v1/test/reset

# 부하 테스트 실행
docker-compose --profile test run --rm k6 run /k6/order-load-test.js

# 결과 검증
curl http://host.docker.internal:8080/api/v1/orders/summary
curl http://host.docker.internal:8080/api/v1/payments/summary
curl http://host.docker.internal:8080/api/v1/stocks/1/remaining
```

### 테스트 결과

<!-- k6 실행 결과 스크린샷 -->

<!-- orders/summary 결과 스크린샷 -->

<!-- payments/summary 결과 스크린샷 -->

<!-- stocks/remaining 결과 스크린샷 -->

---

## 결과 분석

### 정합성 검증

| 검증 항목 | 결과 |
| :--- | :--- |
| 주문 성공(PAID) | 6건 |
| 주문 실패(FAILED) | 11건 |
| 결제 성공(SUCCESS) | 6건 |
| 결제 실패(FAILED) | 11건 |
| 남은 재고 | 94개 |
| PAID 수 == 결제 SUCCESS 수 | ✅ 일치 (6 == 6) |
| FAILED 수 == 결제 FAILED 수 | ✅ 일치 (11 == 11) |
| 재고 차감 수 == PAID 수 | ✅ 일치 (100 - 94 = 6) |
| 초과 판매 | ✅ 없음 |

**데이터 정합성은 여전히 100% 보장되었다.** 하지만 그게 전부다.

### Phase 1 vs Phase 2 비교

| 항목 | Phase 1 | Phase 2 |
| :--- | :--- | :--- |
| 주문 성공(PAID) | 57건 | 6건 |
| 평균 응답 시간 | 2.81초 | 26.05초 |
| 재고 판매율 | 57% | 6% |
| 총 소요 시간 | 5.5초 | 30.3초 |
| http_req_failed | 98% | 99.4% |

Phase 1에서 57개를 팔았는데, 결제가 추가된 Phase 2에서는 **6개밖에 못 팔았다.** 한정판 스니커즈 94켤레가 창고에 남아있는 셈이다.

### 무엇이 이렇게 만들었는가?

문제의 핵심은 **커넥션 풀 고갈**이다.

```
@Transactional 시작 → DB 커넥션 획득
    ├── 재고 차감          (빠름)
    ├── 주문 생성          (빠름)
    ├── 결제 API 호출      (100ms ~ 1000ms 블로킹) ← 여기서 커넥션을 물고 대기
    └── 결제 결과 반영      (빠름)
@Transactional 종료 → DB 커넥션 반환
```

HikariCP 커넥션 풀은 20개다. 결제 응답을 기다리는 동안 커넥션을 놓지 않으니까 이런 상황이 벌어진다.

```
[0초]     1,000명 동시 요청
[0.1초]   처음 20명이 커넥션 획득 → 결제 대기 중...
          나머지 980명은 커넥션 대기 줄에 서 있음
[1초]     20명 완료 → 다음 20명 진입 → 또 결제 대기...
[2초]     반복...
          ...
[30초]    k6 타임아웃 → 아직 대기 중이던 요청 전부 request timeout
```

1,000건의 요청을 분해하면:

- **~968건**: 커넥션 풀 대기 → 타임아웃 (처리 자체를 못 함)
- **~15건**: 낙관적 락 충돌 → 전체 롤백 (DB에 흔적 없음)
- **11건**: 커넥션 확보 + 재고 확보 + 결제 실패(30%) → FAILED + 재고 복구
- **6건**: 커넥션 확보 + 재고 확보 + 결제 성공 → PAID

### k6 종료 후에도 서버 로그가 계속 올라온다

k6는 30초 타임아웃으로 "응답이 안 오니 포기"하고 테스트를 종료한다. 하지만 Spring Boot는 이미 받아들인 요청을 여전히 처리 중이다.

```
k6 입장:       "30초 지났어, 안 기다려" → 테스트 종료
Spring 입장:   "나 아직 커넥션 대기 중이었는데..." → 커넥션 잡히면 처리 계속 진행
```

이 현상이 실제 서비스였다면, 사용자는 "주문 실패"라고 안내받고 나갔는데 서버에서는 뒤늦게 결제가 성공하여 **돈이 빠져나가는 상태 불일치**가 발생할 수 있다.

---

## 이번 Phase에서 확인한 문제들

### 1. DB 트랜잭션 안에서 외부 API 호출 = 안티패턴

외부 API 응답 시간만큼 DB 커넥션을 불필요하게 점유한다. 결제 API가 100ms만 걸려도 1,000명이 동시에 요청하면 커넥션 20개로는 절대 감당이 안 된다.

### 2. 커넥션 풀 고갈 → 시스템 전체 마비

커넥션 풀이 바닥나면 주문 처리뿐 아니라 **다른 모든 DB 작업도 멈춘다.** 상품 조회, 회원 조회 등 읽기 전용 요청까지 전부 영향을 받는다.

### 3. 클라이언트 타임아웃 vs 서버 처리 불일치

클라이언트가 타임아웃으로 끊어도 서버는 모르고 처리를 계속한다. 결제까지 성공시키면 사용자는 모르는 사이에 돈이 빠져나갈 수 있다.

---

## 이번 Phase에서 배운 것

**외부 API 호출은 DB 트랜잭션과 반드시 분리해야 한다.**

Phase 1에서는 낙관적 락 충돌로 재고의 43%를 못 팔았다. Phase 2에서는 커넥션 풀 고갈까지 겹치면서 **재고의 94%를 못 팔았다.** 문제가 심화된 것이 아니라, 근본적으로 다른 종류의 문제가 추가된 것이다.

해결 방향은 명확하다. DB에 데이터를 저장하는 작업과 외부 API를 호출하는 작업을 **별도의 트랜잭션으로 분리**해야 한다. 그러면 결제 응답을 기다리는 동안 DB 커넥션을 물고 있을 필요가 없다.

이것이 바로 **Transactional Outbox 패턴**이 필요한 이유다.

---

## What's Next

**Phase 3: Transactional Outbox 패턴 도입**

- DB 저장과 외부 API 호출을 분리하여 커넥션 풀 고갈 문제를 해결한다.
- 주문 생성 시 Outbox 테이블에 이벤트를 함께 저장하고, 별도 프로세스가 이벤트를 읽어 결제를 처리한다.
- 이벤트 발행에 Kafka를 활용하여 비동기 결제 처리를 구현한다.
- "DB 저장은 성공했는데 이벤트 발행은 실패하면?" 이라는 새로운 정합성 문제를 해결할 예정이다.