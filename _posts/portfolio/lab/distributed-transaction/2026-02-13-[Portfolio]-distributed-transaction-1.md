---
title: 분산 트랜잭션 - 1. 모놀리식 주문 시스템과 낙관적 락의 한계
date: 2026-02-13
categories: [Spring, Project]
tags: [spring-boot, jpa, optimistic-lock, concurrency, load-test, k6]
image: 
---

## 분산 트랜잭션 #1 - 모놀리식 주문 시스템과 낙관적 락의 한계

### 이번 Phase의 목표
`Phase 0`에서 설계한 한정 수량 주문 시스템을 **단일 트랜잭션 + 낙관적 락**으로 구현한다.
`1,000명`이 동시에 재고 `100개`짜리 한정판 스니커즈를 주문하는 상황에서, 낙관적 락이 동시성을 얼마나 잘 제어하는지 직접 확인해본다.
결론부터 말하면, **정합성은 지켜졌지만 효율성에서 심각한 문제**가 드러났다.

## 시스템 구조
`Phase 1`은 모놀리식이다. 하나의 `Spring Boot` 애플리케이션 안에서 **주문, 재고, 회원 관리를 모두 처리**한다.

```
Client (k6) → Spring Boot → MySQL
                 │
                 ├── OrderService (주문 생성 + 흐름 조율)
                 ├── StockService (재고 차감)
                 └── DB (단일 트랜잭션)
```

## 핵심 구현

### 주문 흐름
하나의 `@Transactional` 안에서 모든 과정이 처리된다.

```java
@Transactional
public OrderResponse createOrder(Long memberId, Long productId, int quantity) {
    // 1. 회원 존재 확인
    memberRepository.findById(memberId)
            .orElseThrow(() -> new BusinessException(ErrorCode.MEMBER_NOT_FOUND));

    // 2. 상품 조회
    Product product = productRepository.findById(productId)
            .orElseThrow(() -> new BusinessException(ErrorCode.PRODUCT_NOT_FOUND));

    // 3. 중복 주문 확인 (DB UK로도 방어하지만, 명시적으로 먼저 체크)
    if (orderRepository.existsByMemberIdAndProductId(memberId, productId)) {
        throw new BusinessException(ErrorCode.ORDER_ALREADY_EXISTS);
    }

    // 4. 재고 차감 (낙관적 락) (StockService에 위임)
    stockService.decrease(productId, quantity);

    // 5. 주문 생성
    Order order = Order.create(memberId, productId, quantity, product.getPrice());
    order.markPaid(); // 강제 결재 
    orderRepository.save(order);

    return OrderResponse.from(order);
}
```

### 낙관적 락 (Optimistic Lock)
재고 엔티티에 `@Version`을 사용한다.

```java
@Entity
@Table(name = "stocks")
public class Stock extends BaseTimeEntity {

    @Version
    @Column(nullable = false)
    private int version;

    public void decrease(int quantity) {
        if (getRemaining() < quantity) {
            throw new BusinessException(ErrorCode.STOCK_SOLD_OUT);
        }
        this.soldQuantity += quantity;
    }
}
```

```
Thread A: Stock 조회 (version = 0)
Thread B: Stock 조회 (version = 0)
Thread A: UPDATE ... SET version = 1 WHERE version = 0  → 성공
Thread B: UPDATE ... SET version = 1 WHERE version = 0  → 실패 (이미 version = 1)
         → ObjectOptimisticLockingFailureException 발생
```

### 왜 Retry를 넣지 않았는가?
낙관적 락에서 충돌이 발생하면 보통 재시도 로직을 붙이는 것이 일반적이다. 
이번에는 **의도적으로 Retry를 넣지 않았다.** 이 `Phase`의 목적이 낙관적 락의 한계를 체감하는 것이기 때문이다.
`Retry`를 넣으면 성공률이 올라가면서 문제가 가려진다.
`Retry` 없이 `1,000`명을 동시에 쏟아부어야 "재고 `100개`를 다 못 팔았다"는 비즈니스 손실이 눈에 보인다.

> 쿠폰 발급 시스템의 `Phase 1`(낙관적 락) 에선 재시도 3회 로직(while) 문을 사용했지만, 이번 프로젝트에선 위의 이유로 아예 제외시켰다.

### Order 엔티티 - 정적 팩토리 메서드
`Order` 엔티티는 다른 엔티티와 달리 `@Builder` 대신 **정적 팩토리 메서드**를 사용한다.

```java
public static Order create(Long memberId, Long productId, int quantity, int price) {
    Order order = new Order();
    order.orderCode = UUID.randomUUID().toString().substring(0, 8).toUpperCase();
    order.memberId = memberId;
    order.productId = productId;
    order.quantity = quantity;
    order.totalPrice = price * quantity;
    order.status = OrderStatus.PENDING;
    return order;
}
```

`Member`나 `Product`는 단순히 데이터를 담는 역할이라 `Builder`가 자연스럽다. 하지만 `Order`는 생성 자체가 **비즈니스 행위**다.
- `orderCode`는 외부 입력이 아니라 시스템이 자동 발급해야 한다.
- `totalPrice`는 `price * quantity` 계산으로만 결정되어야 한다.
- `status`는 항상 `PENDING`으로 시작해야 한다.

`Builder`로 열어두면 이 규칙을 우회할 수 있기 때문에, `Order.create()`를 통해서만 생성하도록 강제한다.

### 중복 주문 방지 - 이중 방어
중복 주문 방지는 두 레이어에서 방어한다.

```java
// 1. 애플리케이션 레벨 - 명시적 체크
if (orderRepository.existsByMemberIdAndProductId(memberId, productId)) {
    throw new BusinessException(ErrorCode.ORDER_ALREADY_EXISTS);
}

// 2. DB 레벨 - UK 제약 조건
// UK(member_id, product_id)
```

애플리케이션 레벨에서 먼저 체크하는 이유는 **불필요한 재고 차감 시도를 방지**하기 위해서다.
`UK`만으로도 중복 주문을 막을 수 있지만, 그 경우 재고 차감까지 진행한 뒤에 `UK` 위반으로 전체 롤백이 발생한다.
미리 체크하면 재고에 대한 쓰기 연산과 락 경합을 줄일 수 있다.

## DB 스키마
`Flyway`로 관리하며, `@Table(indexes = ...)`는 사용하지 않는다.

`Flyway`가 스키마의 유일한 진실 소스(`Single Source of Truth`)이고, `JPA`는 `ddl-auto=validate`로 검증만 수행한다.
인덱스 정보를 엔티티에도 중복으로 관리하면 양쪽을 동기화해야 하는 부담이 생기기 때문이다.

> 쿠폰 발급 시스템 프로젝트에선 `@Table(indexes = ...)` 를 사용했지만, 이번 프로젝트에선 위의 이유로 아예 제외시켰다.

```sql
-- 재고 테이블: 상품과 분리하여 락 범위 최소화
CREATE TABLE stocks (
    id              BIGINT      NOT NULL AUTO_INCREMENT,
    product_id      BIGINT      NOT NULL,
    total_quantity  INT         NOT NULL,
    sold_quantity   INT         NOT NULL DEFAULT 0,
    version         INT         NOT NULL DEFAULT 0,
    created_at      DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at      DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_stocks_product_id (product_id),
    CONSTRAINT fk_stocks_product FOREIGN KEY (product_id) REFERENCES products (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

`products`와 `stocks`를 분리한 이유는 재고 업데이트 시 상품 테이블까지 락이 걸리는 것을 방지하기 위해서다.

## 부하 테스트

### 테스트 환경

| 설정 | 값 |
| :--- | :--- |
| **동시 사용자(VUs)** | `1,000명` |
| **사용자당 요청** | `1회` |
| **상품 재고** | `100개` |
| **시나리오** | `shared-iterations (1,000명이 각 1회 주문)` |

### k6 스크립트

```javascript
export const options = {
    scenarios: {
        burst_order: {
            executor: 'shared-iterations',
            vus: 1000,
            iterations: 1000,
            maxDuration: '30s',
        },
    },
};
```

### 테스트 실행

```bash
# 부하 테스트 실행
docker-compose --profile test run --rm --no-deps otl-k6 run /k6/order-load-test.js

# 결과 검증
curl http://localhost:8080/api/v1/orders/summary
curl http://localhost:8080/api/v1/stocks/1/remaining
```

### 테스트 결과
![](/assets/img/portfolio/lab/distributed-transaction/distributed-transaction-1/Portfolio-distributed-transaction-1-1.png)*[k6 test]*

![](/assets/img/portfolio/lab/distributed-transaction/distributed-transaction-1/Portfolio-distributed-transaction-1-2.png)*[orders/summary]*

![](/assets/img/portfolio/lab/distributed-transaction/distributed-transaction-1/Portfolio-distributed-transaction-1-3.png)*[stocks/remaining]*

## 결과 분석

### 정합성 검증

| 검증 항목                       | 결과              |
|:----------------------------|:----------------|
| **주문 성공(PAID)**             | `57건`           |
| **남은 재고                     | `43개`           |
| **sold_quantity == PAID 수** | 일치 (`57 == 57`) |
| **초과 판매**                   | 없음              |
| **중복 주문**                   |  없음             |

**데이터 정합성은 100% 보장되었다.** 낙관적 락이 동시성 안전성은 확실히 지켜준다.

### 효율성 문제
하지만 재고 `100개` 중 **57개만 판매**되었다. **43개를 더 팔 수 있었는데 못 판 것이다.**

```
1,000명 동시 요청
    ↓
Stock version=0 을 대부분이 동시에 읽음
    ↓
첫 번째 커밋 성공 → version=1
    ↓
나머지 대부분 version 불일치 → ObjectOptimisticLockingFailureException
    ↓
Retry 없음 → 즉시 실패
    ↓
재고가 남았는데도 주문 실패
```

실패한 `943건` 중 실제로 재고 소진으로 실패해야 하는 건 `900건`뿐이다. 나머지 `43건`은 **재고가 있었는데 락 충돌 때문에 실패**한 것이다.

### 낙관적 락 평가

| 항목 | 평가                         |
| :--- |:---------------------------|
| **정합성** | `100%` 보장 (초과 판매 없음)       |
| **효율성** | 재고 `100개` 중 `57개`만 판매 (`43% 손실`) |
| **원인** | `Retry` 없이 충돌 시 즉시 실패 처리     |

## Phase 1 에서 의도적으로 빠진 것들

### 결제 로직
`Phase 1`에서는 결제 없이 `order.markPaid()`로 바로 완료 처리한다. 그래서 `orders` 테이블에는 `PAID` 상태만 존재한다.
`Phase 2`에서 `Mock` 결제 서버가 추가되면 `PENDING → PAID / FAILED` 분기가 생기고, 결제 실패 시 재고 롤백이라는 새로운 문제가 등장할 예정이다.

### Retry 로직
위에서 설명한 대로, 한계를 체감하기 위해 의도적으로 빠졌다. 실무에서 낙관적 락을 사용한다면 당연히 `Retry`를 붙여야 한다.

## 이번 Phase에서 배운 것
**낙관적 락은 정합성은 보장하지만, 대량 동시 요청에서는 비효율적이다.**
재고 `100개`를 완판하지 못하고 `57개`만 판매된 건 비즈니스 관점에서 큰 손실이다. 한정판 스니커즈 `43켤레`가 **창고에 남아있는 셈이다.**
이전 프로젝트(쿠폰 발급 시스템)에서는 이 문제를 **비관적 락 →** `Redis` **분산 락 →** `Redis DECR + Kafka` 순서로 해결해나갔다.** 하지만 이번 프로젝트의 핵심은 동시성 제어 자체가 아니라 **분산 트랜잭션**이다.
다음 `Phase`에서 결제 `API`가 추가되면 동시성보다 더 근본적인 문제가 터진다. `DB` **트랜잭션 안에서 외부** `API`**를 호출하면 어떤 일이 벌어지는가?**

## What's Next
**Phase 2: 외부 결제 API 연동**
- `Mock` 결제 서버를 구축하여 성공/실패/타임아웃을 시뮬레이션한다.
- `@Transactional` 안에서 외부 `API`를 호출했을 때 발생하는 문제를 확인한다.
    - 결제 응답 대기 중 `DB` 커넥션 점유
    - 결제 실패 시 재고 롤백 필요
    - 결제 타임아웃 시 주문 상태 불일치
- 이 문제들이 왜 `Transactional Outbox` **패턴의 필요성으로 이어지는지 직접 체감할 예정이다.**