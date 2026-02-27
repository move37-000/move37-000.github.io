---
title: 분산 트랜잭션 - 3. Transactional Outbox 패턴으로 커넥션 풀 고갈 해결
date: 2026-02-26
categories: [Spring, Project]
tags: [spring-boot, jpa, Kafka, outbox-pattern, transactional-outbox, load-test, k6]
image: 
published: false  
---

## 분산 트랜잭션 #3 - Transactional Outbox 패턴으로 커넥션 풀 고갈 해결

### 이번 Phase의 목표
`Phase 2`에서 확인한 **커넥션 풀 고갈** 문제를 `Transactional Outbox` 패턴으로 해결한다.
`DB` 트랜잭션에서 외부 `API` 호출을 분리하고, `Kafka`를 통해 비동기로 결제를 처리한다.

결론부터 말하면, **커넥션 풀 고갈이 완전히 해소**되었고, 응답 시간이 `26초`에서 `6초`로 `4배` 개선되었다.

## 시스템 구조
`Phase 2`에서는 하나의 트랜잭션 안에서 재고 차감부터 결제 `API` 호출까지 전부 처리했다. `Phase 3`에서는 결제를 트랜잭션 밖으로 분리했다.

```
[사용자 요청 트랜잭션 - 빠르게 끝남]
Client (k6) → Spring Boot → MySQL
                 │
                 ├── OrderService
                 │   ├── 재고 차감
                 │   ├── 주문 생성 (PENDING)
                 │   ├── 결제 정보 생성 (PENDING)
                 │   └── Outbox 이벤트 저장
                 │
                 └── 트랜잭션 종료, 커넥션 즉시 반환

[비동기 결제 처리 - 별도 프로세스]
Scheduler (100ms 간격)
    └── Outbox 테이블 조회 (PENDING) → Kafka 발행 → PUBLISHED로 변경

Kafka Consumer (별도 스레드)
    └── 이벤트 수신 → Mock 결제 API 호출
        ├── 성공 → Order PAID + Payment SUCCESS
        └── 실패 → Order FAILED + Payment FAILED + 재고 복구
```

핵심 변화는 단순하다. **결제 API 호출이 사용자 요청 트랜잭션에서 빠졌다.** 이것만으로 커넥션 풀 고갈이 해결된다.

## Transactional Outbox 패턴이란?
비즈니스 데이터와 이벤트를 **같은 트랜잭션에 저장**하는 패턴이다.

```
@Transactional {
    주문 저장     → orders 테이블
    결제 저장     → payments 테이블
    이벤트 저장   → outbox_events 테이블   ← 핵심
}
```

`DB` 저장이 성공하면 이벤트 저장도 반드시 성공한다. **같은 트랜잭션이니까 원자성이 보장된다.** 이후 별도 프로세스가 `Outbox` 테이블을 읽어 Kafka로 발행한다.

이렇게 하면 "DB는 저장됐는데 Kafka 발행 실패"라는 데이터 불일치 문제를 방지할 수 있다.

## 핵심 구현

### Phase 2 → Phase 3 변경점
```
Phase 2: 재고 차감 → 주문 생성 → [결제 API 호출] → 결과 반영   ← 전부 하나의 트랜잭션
Phase 3: 재고 차감 → 주문 생성 → 결제 생성 → Outbox 저장       ← 트랜잭션은 여기서 끝
         (별도) Outbox Polling → Kafka → Consumer → 결제 처리
```

### 주문 흐름 (사용자 트랜잭션)
`Phase 2`에서 결제 `API` 호출 부분이 `Outbox` 이벤트 저장으로 대체되었다.

```java
@Transactional
public OrderResponse createOrder(Long memberId, Long productId, int quantity) {
    // 1 ~ 3. 회원 확인, 상품 조회, 중복 주문 확인 (Phase 2와 동일)

    // 4. 재고 차감 (낙관적 락)
    stockService.decrease(productId, quantity);

    // 5. 주문 생성 (PENDING 상태)
    Order order = Order.create(memberId, productId, quantity, product.getPrice());
    orderRepository.save(order);

    // 6. 결제 정보 생성 (PENDING 상태)
    Payment payment = Payment.create(order.getId(), order.getTotalPrice());
    paymentRepository.save(payment);

    // 7. Outbox 이벤트 저장 (같은 트랜잭션)
    OrderPaymentRequestedEvent event = new OrderPaymentRequestedEvent(
            order.getId(), productId, quantity,
            order.getTotalPrice(), payment.getPaymentCode()
    );
    OutboxEvent outboxEvent = OutboxEvent.create(
            "ORDER", order.getId(), "PAYMENT_REQUESTED", toJson(event)
    );
    outboxEventRepository.save(outboxEvent);

    return OrderResponse.from(order);
}
// 여기서 트랜잭션 종료 → 커넥션 즉시 반환
```

`Phase 2`에서는 6번 자리에 `paymentService.processPayment()`가 있었고, 이 안에서 결제 `API`를 호출하며 `100ms~1000ms`를 블로킹했다. `Phase 3`에서는 `Outbox`에 이벤트만 저장하고 끝이다. **DB INSERT 몇 건이 전부이므로 트랜잭션이 수 ms 내에 끝난다.**

### Outbox 이벤트 발행 (Polling)
스케줄러가 `100ms` 간격으로 `Outbox` 테이블에서 `PENDING` 이벤트를 조회하여 `Kafka`로 발행한다.

```java
@Component
public class OutboxEventPublisher {

    @Scheduled(fixedDelay = 100)
    @Transactional
    public void publishPendingEvents() {
        List<OutboxEvent> pendingEvents = outboxEventRepository
                .findTop100ByStatusOrderByCreatedAtAsc(OutboxEventStatus.PENDING);

        for (OutboxEvent event : pendingEvents) {
            try {
                kafkaTemplate.send(
                        TOPIC_PAYMENT_REQUEST,
                        String.valueOf(event.getAggregateId()),
                        event.getPayload()
                ).get();

                event.markPublished();
            } catch (Exception e) {
                event.markFailed();
            }
        }
    }
}
```

스케줄러가 직접 결제 `API`를 호출하지 않고 **Kafka에 발행만 하는 이유**가 있다. 스케줄러가 직접 결제를 호출하면 결제 응답을 기다리는 동안 다음 이벤트 처리가 밀린다. `Kafka`에 넘기면 발행은 `수 ms`로 끝나고, 시간이 걸리는 결제 처리는 `Consumer`에게 위임할 수 있다.

### 발행 실패 시 재시도
`Outbox` 이벤트는 최대 `3회`까지 재시도한다. `3회` 초과 시 `FAILED`로 마킹되어 수동 확인이 필요한 상태로 전환된다.

```java
public void markFailed() {
    this.retryCount++;
    if (this.retryCount >= MAX_RETRY_COUNT) {
        this.status = OutboxEventStatus.FAILED;
    }
    this.processedAt = LocalDateTime.now();
}
```

이전 프로젝트(쿠폰 발급 시스템)에서는 `Kafka`가 핵심 파이프라인이어서 `Kafka` 레벨의 `DLQ + ErrorHandler`로 재시도를 처리했다. 이번 프로젝트에서는 `Outbox` 테이블 자체가 안전망 역할을 하므로, **Outbox 레벨에서 재시도를 관리**한다. `Kafka` 발행이 실패해도 `Outbox`에 원본이 남아있으니 다음 `Polling`에서 다시 시도할 수 있다.

### Kafka Consumer (비동기 결제 처리)
`Kafka`에서 이벤트를 수신하여 결제를 처리한다. 이 과정은 사용자 요청 트랜잭션과 **완전히 별개의 스레드, 별개의 트랜잭션**에서 실행된다.

```java
@KafkaListener(topics = "payment-request", groupId = "payment-consumer-group")
public void handlePaymentRequest(String message) {
    OrderPaymentRequestedEvent event = objectMapper.readValue(
            message, OrderPaymentRequestedEvent.class
    );
    paymentService.processPaymentAsync(event);
}
```

```java
@Transactional
public void processPaymentAsync(OrderPaymentRequestedEvent event) {
    Payment payment = paymentRepository.findByOrderId(event.orderId())...;
    Order order = orderRepository.findById(event.orderId())...;

    // 결제 API 호출 - 이 지연이 더 이상 사용자 트랜잭션을 블로킹하지 않음
    MockPaymentResponse pgResponse = mockPaymentClient.requestPayment(
            event.paymentCode(), event.totalPrice()
    );

    if (pgResponse.success()) {
        payment.markSuccess(pgResponse.transactionId());
        order.markPaid();
    } else {
        payment.markFailed(pgResponse.failReason());
        order.markFailed();
        stockService.restore(event.productId(), event.quantity());  // 보상 트랜잭션
    }
}
```

결제 API의 `100ms ~ 1000ms` 지연이 여전히 존재하지만, **사용자 요청과 무관한 별도 스레드에서 실행**되므로 사용자 트랜잭션의 커넥션을 점유하지 않는다.

## DB 스키마
`Phase 2`의 테이블에 `outbox_events` 테이블이 추가되었다.

```sql
CREATE TABLE outbox_events (
    id              BIGINT          NOT NULL AUTO_INCREMENT,
    aggregate_type  VARCHAR(50)     NOT NULL,
    aggregate_id    BIGINT          NOT NULL,
    event_type      VARCHAR(50)     NOT NULL,
    payload         TEXT            NOT NULL,
    status          VARCHAR(20)     NOT NULL DEFAULT 'PENDING',
    retry_count     INT             NOT NULL DEFAULT 0,
    created_at      DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    processed_at    DATETIME(6)     NULL,
    PRIMARY KEY (id),
    INDEX idx_outbox_status_created (status, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

`payload`에는 이벤트 내용이 `JSON` 문자열로 저장된다. `OrderService`에서 `Outbox`를 저장할 때 이미 `JSON`으로 직렬화하므로, `Kafka` 발행 시 별도의 변환 없이 그대로 보낼 수 있다.

`idx_outbox_status_created` 인덱스는 `Polling` 시 `WHERE status='PENDING' ORDER BY created_at` 쿼리를 효율적으로 수행하기 위한 것이다.

## 실무와의 차이
이 프로젝트에서는 **결제 자체를 비동기로 분리**했다. 사용자가 주문 버튼을 누르면 `PENDING` 상태로 즉시 응답하고, 결제는 `Kafka Consumer`가 나중에 처리한다.

하지만 실무에서는 이렇게 하지 않는다. 실제 이커머스(쿠팡, 배달의민족 등)에서는 **결제까지는 동기로 처리**한다. 사용자가 결제 버튼을 누르면 PG사 결제창이 뜨고, 결제가 완료된 뒤에야 "주문 완료" 화면을 보여준다. 돈이 빠져나갔는지를 사용자가 즉시 알 수 있어야 하기 때문이다.

```
실무:         결제(동기) → 재고 확정 + 알림 + 포인트(비동기)
이번 프로젝트:  재고 차감(동기) → 결제(비동기)
```

실무에서 Outbox + Kafka가 사용되는 영역은 결제 이후의 **후속 처리**다. 결제가 완료된 뒤 재고 확정, 판매자 알림, 포인트 적립, 배송 준비 등을 비동기로 처리한다. 이 과정에서 문제가 생기면 보상 트랜잭션으로 처리한다.

이번 프로젝트에서 결제까지 비동기로 뺀 이유는 **Outbox 패턴의 효과를 극대화하기 위해서**다. "트랜잭션에서 외부 호출을 분리한다"는 개념을 가장 명확하게 보여줄 수 있는 구조가 결제를 비동기로 빼는 것이기 때문이다. Outbox 패턴이 해결하는 문제의 본질 — "DB 트랜잭션과 외부 호출의 분리, 이벤트 유실 방지" — 은 실무와 동일하다.

---

## 부하 테스트

### 테스트 환경

| 설정 | 값 |
| :--- | :--- |
| **동시 사용자(VUs)** | 1,000명 |
| **사용자당 요청** | 1회 |
| **상품 재고** | 100개 |
| **시나리오** | shared-iterations (1,000명이 각 1회 주문) |
| **maxDuration** | 30초 (Phase 2의 60초에서 감소 - 결제 동기 대기 없음) |
| **HikariCP 커넥션 풀** | 20개 |

### 테스트 실행

```bash
# 데이터 초기화
curl -X POST http://host.docker.internal:8080/api/v1/test/reset

# 부하 테스트 실행
docker-compose --profile test run --rm k6 run /k6/order-load-test.js

# 비동기 처리 대기 (결제가 비동기이므로 30초 후 조회)
sleep 30

# 결과 검증
curl http://host.docker.internal:8080/api/v1/orders/summary
curl http://host.docker.internal:8080/api/v1/payments/summary
curl http://host.docker.internal:8080/api/v1/outbox/summary
curl http://host.docker.internal:8080/api/v1/stocks/1/remaining
```

### 테스트 결과

<!-- k6 실행 결과 스크린샷 -->

<!-- orders/summary 결과 스크린샷 -->

<!-- payments/summary 결과 스크린샷 -->

<!-- outbox/summary 결과 스크린샷 -->

<!-- stocks/remaining 결과 스크린샷 -->

---

## 결과 분석

### 정합성 검증

| 검증 항목 | 결과 |
| :--- | :--- |
| 주문 성공(PAID) | 15건 |
| 주문 실패(FAILED) | 5건 |
| 결제 성공(SUCCESS) | 15건 |
| 결제 실패(FAILED) | 5건 |
| 남은 재고 | 85개 |
| Outbox PUBLISHED | 20건 (전부 발행 완료) |
| PAID 수 == 결제 SUCCESS 수 | ✅ 일치 (15 == 15) |
| FAILED 수 == 결제 FAILED 수 | ✅ 일치 (5 == 5) |
| 재고 차감 수 == PAID 수 | ✅ 일치 (100 - 85 = 15) |
| 초과 판매 | ✅ 없음 |

**데이터 정합성은 여전히 100% 보장되었다.** Outbox 이벤트도 전부 정상 발행되었다.

### Phase 1 → Phase 2 → Phase 3 비교

| 항목 | Phase 1 | Phase 2 | Phase 3 |
| :--- | :--- | :--- | :--- |
| 주문 성공(PAID) | 57건 | 6건 | 15건 |
| 평균 응답 시간 | 2.81초 | 26.05초 | 6.03초 |
| 총 소요 시간 | 5.5초 | 30.3초 | 11.9초 |
| 재고 판매율 | 57% | 6% | 15% |
| request timeout | 0건 | 대량 | 0건 |
| 커넥션 풀 고갈 | 없음 | 발생 | 없음 |
| 결제 방식 | 없음 | 동기 (트랜잭션 내) | 비동기 (Outbox + Kafka) |

Phase 2에서 6건밖에 못 팔던 재고가 Phase 3에서 15건으로 올라갔다. 응답 시간도 26초에서 6초로 **4배 개선**되었고, request timeout은 완전히 사라졌다.

### Phase 2의 문제가 어떻게 해결되었는가?

| Phase 2 문제 | Phase 3 해결 |
| :--- | :--- |
| 결제 대기 동안 커넥션 점유 | 트랜잭션에서 결제 제거 → 커넥션 즉시 반환 |
| 커넥션 풀 고갈 → 대량 타임아웃 | 트랜잭션이 짧아져서 고갈 안 됨 |
| k6 종료 후 서버가 결제 처리 (상태 불일치) | 주문 API는 PENDING으로 즉시 응답, 결제는 비동기 |

### Phase 1보다 성공 건수가 적은 이유

Phase 3의 15건은 Phase 1의 57건보다 낮다. 이는 Phase 3에서 **결제 실패(30%)** 라는 변수가 추가되었기 때문이다.

Phase 1에서는 재고 확보에 성공하면 바로 PAID였지만, Phase 3에서는 재고 확보 후에도 결제에서 실패할 수 있다. 20건이 재고를 확보했지만 그중 5건이 결제 실패로 FAILED 처리되어 최종 15건만 PAID가 된 것이다.

낙관적 락 충돌로 인한 손실은 Phase 1과 동일하게 존재한다. 1,000명이 동시에 version=0을 읽고 충돌하는 구조는 바뀌지 않았기 때문이다. 이 프로젝트에서 동시성 제어 방식 변경은 범위에 포함시키지 않았다.

---

## Outbox 패턴에서의 이벤트 흐름 정리

```
1. 사용자 주문 → @Transactional 내에서 주문 + Outbox 저장 → 커넥션 반환
2. Scheduler (100ms) → Outbox PENDING 조회 → Kafka 발행 → PUBLISHED
3. Kafka Consumer → 결제 API 호출 → 성공이면 PAID / 실패면 FAILED + 재고 복구
```

각 단계가 **독립된 트랜잭션**에서 실행되므로, 하나가 느려도 다른 단계에 영향을 주지 않는다. 사용자 트랜잭션은 수 ms만에 끝나고, 시간이 걸리는 결제 처리는 별도로 진행된다.

---

## 이번 Phase에서 배운 것

**Transactional Outbox 패턴은 DB 트랜잭션과 외부 호출을 안전하게 분리하는 핵심 패턴이다.**

Phase 2에서 재고의 94%를 못 팔았던 시스템이 Phase 3에서는 정상적으로 동작하기 시작했다. 커넥션 풀 고갈이 사라지고, 응답 시간이 4배 개선되었으며, 데이터 정합성도 100% 유지되었다.

Outbox 패턴의 핵심은 **"이벤트를 비즈니스 데이터와 같은 트랜잭션에 저장한다"**는 한 줄로 요약된다. 이 단순한 원리 하나로 "DB 저장은 성공했는데 이벤트 발행은 실패"하는 불일치 문제를 원천 차단할 수 있다.

---

## What's Next

**Phase 4: SAGA 패턴 - 보상 트랜잭션 자동화**

- 현재는 결제 실패 시 Consumer 안에서 직접 `stockService.restore()`를 호출한다. 서비스가 늘어나면 보상 로직이 복잡해진다.
- SAGA 패턴(Choreography 또는 Orchestration)을 도입하여 보상 트랜잭션을 체계적으로 관리한다.
- "결제는 성공했는데 배송 서비스가 실패하면?" 같은 다단계 보상 시나리오를 처리할 예정이다.