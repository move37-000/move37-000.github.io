---
title: 동시성 제어 - 9. 프로젝트 정리
date: 2026-02-03
categories: [Spring, Project]
tags: [concurrency, redis, kafka, retrospective]
image: 
published: false
---

## 프로젝트 개요

선착순 쿠폰 발급 시스템은 **대규모 트래픽 환경에서의 동시성 제어**를 학습하기 위한 포트폴리오 프로젝트다. 단순한 기능 구현이 아니라, 실제 대기업에서 사용하는 아키텍처 패턴을 직접 구현하고 그 과정에서 발생하는 문제들을 해결하는 데 초점을 맞췄다.

### 프로젝트 목표

- 수천~수만 명이 동시에 요청하는 상황에서 **데이터 정합성** 보장
- **빠른 응답 시간** 유지 (사용자 경험)
- 장애 상황에서도 **데이터 유실 없이 복구** 가능한 구조 설계

### 기술 스택

| 분류 | 기술 |
| :--- | :--- |
| Backend | Spring Boot 4.0, Java 17 |
| Database | MySQL 8.0 |
| Cache | Redis (Redisson) |
| Message Queue | Apache Kafka |
| Testing | k6 (부하 테스트) |

---

## Phase별 진행 과정

### Phase 1: 낙관적 락 (Optimistic Lock)

DB 락 없이 버전 기반으로 충돌을 감지하는 방식을 먼저 구현했다.

```java
@Version
private Long version;
```

쿠폰 엔티티에 `@Version`을 추가하고, 업데이트 시 버전이 달라지면 `OptimisticLockException`이 발생하도록 했다.

**결과:** 동시 요청 시 대부분 실패. 충돌이 너무 빈번하게 발생했다.

**배운 점:** 낙관적 락은 **충돌이 적은 환경**에서 적합하다. 선착순처럼 동시 요청이 폭주하는 상황에서는 맞지 않았다.

---

### Phase 2: 비관적 락 (Pessimistic Lock)

낙관적 락의 한계를 확인한 후, DB 레벨에서 직접 락을 거는 비관적 락을 적용했다.

```java
@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT c FROM Coupon c WHERE c.couponCode = :couponCode")
Optional<Coupon> findByCouponCodeWithLock(@Param("couponCode") String couponCode);
```

**결과:** 데이터 정합성은 보장됐지만, 처리량이 급격히 떨어졌다. 모든 요청이 하나의 락을 기다리면서 직렬화되는 문제가 발생했다.

**배운 점:** 비관적 락은 정합성을 확실히 보장하지만, 고트래픽 환경에서는 **병목 지점**이 된다. 그리고 서버가 여러 대면 어떡하지? 라는 생각이 들었다. DB 락만으로는 분산 환경에서 한계가 있다.

---

### Phase 3: Redis 분산락 (Distributed Lock)

서버가 여러 대인 분산 환경에서도 동작하는 락이 필요했다. Redis 기반의 분산락을 Redisson으로 구현했다.

```java
RLock lock = redissonClient.getLock("coupon:" + couponCode);
try {
    if (lock.tryLock(5, 10, TimeUnit.SECONDS)) {
        // 쿠폰 발급 로직
    }
} finally {
    lock.unlock();
}
```

**결과:** 분산 환경에서도 정합성이 보장됐다. 하지만 여전히 락 경합으로 인한 성능 저하가 있었다.

**배운 점:** 분산락은 분산 환경에서 필수지만, 락 자체가 **병목**이라는 본질적인 문제는 그대로였다. 락 없이 동시성을 제어할 방법이 필요했다.

---

### Phase 4: Redis DECR + Kafka 비동기

발상을 전환했다. 락을 거는 대신 **Redis의 원자적 연산**으로 재고를 관리하고, DB 저장은 **Kafka를 통해 비동기**로 처리하기로 했다.

```
요청 → Redis DECR (재고 차감) → Kafka 발행 → 즉시 응답
                                    ↓
                        Consumer → DB 저장 (백그라운드)
```

**핵심 변화:**
- 사용자 응답이 Redis에서 끝남 → **응답 속도 향상**
- DB 저장은 백그라운드 → **DB 부하 분산**

**결과:** 응답 속도가 비약적으로 빨라졌다. 하지만 새로운 문제가 생겼다. DECR만으로는 **중복 발급 방지**가 안 됐다.

---

### Phase 5: Lua 스크립트로 원자적 처리

Redis에서 재고 차감과 중복 체크를 **하나의 원자적 연산**으로 처리해야 했다. Lua 스크립트를 도입했다.

```lua
-- 1. 이미 발급받았는지 확인
if redis.call('SISMEMBER', issuedKey, memberId) == 1 then
    return -1  -- 중복
end

-- 2. 재고 확인 및 차감
local stock = tonumber(redis.call('GET', stockKey) or '0')
if stock <= 0 then
    return 0  -- 매진
end

-- 3. 재고 차감 + 발급 기록 (원자적)
redis.call('DECR', stockKey)
redis.call('SADD', issuedKey, memberId)
return 1  -- 성공
```

**핵심:** 세 가지 연산이 **하나의 트랜잭션**처럼 동작한다. 중간에 다른 요청이 끼어들 수 없다.

**결과:** 중복 발급 없이 빠른 처리가 가능해졌다.

---

### Phase 6: DLQ + @Retryable (실패 복구)

Kafka Consumer에서 DB 저장 실패 시 어떻게 할지 고민했다. **Dead Letter Queue(DLQ)**와 Spring의 `@Retryable`을 조합했다.

```
Main Consumer 실패 → 3회 재시도 → DLQ로 이동
                                    ↓
                    DLQ Consumer → 3회 재시도 → 최종 실패 시 실패 테이블 저장
```

**DLQ Consumer에서 @Retryable 적용:**

```java
@Retryable(
    value = Exception.class,
    maxAttempts = 3,
    backoff = @Backoff(delay = 1000, multiplier = 2)
)
@Transactional
public void processIssue(CouponIssuedEvent event) {
    // DB 저장 로직
}

@Recover
public void recover(Exception e, CouponIssuedEvent event) {
    // 최종 실패 처리: Redis 롤백 + 실패 테이블 저장
}
```

**중요한 발견:** 처음에 `@Retryable`과 `@Transactional`을 같은 메서드에 붙이면 재시도가 안 될 줄 알았다. 알고 보니 `@Retryable`은 **메서드를 다시 호출**하는 것이라 매번 새로운 트랜잭션이 시작됐다. 트랜잭션 오염 문제가 없었다.

**배운 점:** `@Retryable`의 동작 원리를 정확히 이해하게 됐다. 그리고 `@Backoff`로 지수 백오프를 선언적으로 구현할 수 있어서 코드가 깔끔해졌다.

---

### Phase 7: Reconciliation Batch (정합성 검증)

DLQ까지 실패하면 **Redis와 DB 사이에 불일치**가 발생할 수 있다. 이를 감지하고 복구하는 배치를 구현했다.

```java
@Scheduled(initialDelay = 300000, fixedRate = 300000)  // 5분마다
public void runReconciliation() {
    // 1. Redis 발급 목록 조회
    // 2. DB 발급 목록 조회
    // 3. 불일치 감지 → 복구
}
```

**검증 로직:**

| 상황 | 조치 |
| :--- | :--- |
| Redis O, DB X | DB에 INSERT (Consumer 실패 복구) |
| Redis X, DB O | 발생 불가 (Redis 없이 DB 저장 경로 없음) |

**왜 Redis X, DB O는 불가능한가?**

현재 구조에서는 **Redis를 거치지 않으면 Kafka 발행 자체가 안 된다**. Consumer는 Kafka 메시지를 받아야만 DB에 저장하므로, Redis 없이 DB에만 데이터가 있는 경우는 정상 흐름에서 발생하지 않는다.

---

### Phase 8: Kafka 파티션 확장

마지막으로 Consumer의 병렬 처리 능력을 높이기 위해 파티션을 확장했다.

```
Before: Producer → Partition 0 → Consumer 1 → DB

After:  Producer → Partition 0 → Consumer 1 → DB
                → Partition 1 → Consumer 2 → DB
                → Partition 2 → Consumer 3 → DB
```

**구현 과정에서 겪은 문제들:**

1. **NewTopic Bean만으로 토픽이 안 만들어짐** → `KafkaAdmin` Bean 추가 필요
2. **Consumer가 먼저 연결하면 파티션 1개로 자동 생성** → `allow.auto.create.topics = false` 설정
3. **메시지가 한 파티션에만 몰림** → Sticky Partitioner가 기본값이라서 발생. 대용량 트래픽에서는 자연스럽게 분산되므로 기본값 유지

**중요한 깨달음:**

파티션을 늘려도 **API 응답 시간은 변하지 않는다**. 응답은 이미 Redis에서 끝나기 때문이다. 파티션 확장의 효과는 **Consumer의 처리량 증가**에 있다. 처음에 k6로 측정해서 차이가 없길래 당황했는데, 측정 대상이 잘못됐던 것이다.

---

## 실무와의 차이점

### Transactional Outbox Pattern 미적용

처음에는 **Transactional Outbox Pattern**도 고려했다. DB와 Kafka 발행의 원자성을 보장하는 패턴이다.

```
일반적인 구조:
Redis 처리 → Kafka 발행 → 응답 (Kafka 실패 시 불일치)

Outbox Pattern:
DB 저장 + Outbox 테이블 저장 (하나의 트랜잭션)
→ CDC/Polling으로 Outbox → Kafka 발행
```

**적용하지 않은 이유:**

| 항목 | Outbox Pattern | 현재 구조 |
| :--- | :--- | :--- |
| 메인 저장소 | DB | Redis |
| 추가 오버헤드 | DB 폴링 or CDC | 없음 |
| 지연 시간 | 증가 | 최소화 |
| 적합한 케이스 | 주문/결제 | 선착순 쿠폰 |

선착순 쿠폰 시스템의 핵심은 **빠른 응답과 가용성**이다. 실시간 정합성을 위해 사용자를 대기시키는 것보다, **빠르게 이벤트를 처리하고 사후에 데이터를 맞추는 전략**이 더 적합하다고 판단했다.

대신 DLQ + @Retryable + Reconciliation Batch로 **이중 안전망**을 구축해서 정합성을 보장했다.

---

### 실시간 리밸런싱 미적용

파티션 테스트 시 토픽을 삭제하고 재생성하는 방식을 사용했다. 실제 운영 환경에서는 **서비스 중단 없이 실시간 리밸런싱**을 활용한다.

**실시간 리밸런싱이란:**
- 서비스 운영 중에 Kafka CLI로 파티션 수를 늘리면, 브로커가 이를 감지하고 Consumer들에게 파티션 소유권을 재배분한다.
- Kubernetes에서 Consumer Pod를 늘리는 것만으로 즉각적인 Scale-out이 가능하다.

**고려할 점:**
- 리밸런싱 중 짧은 순간 Consumer 읽기가 일시 정지될 수 있다.
- 메시지 중복 처리 위험이 있어 **멱등성 설계**가 필수다.

본 프로젝트는 로컬 환경에서 파티션 구조 변화에 따른 동시성 제어 메커니즘을 확인하는 데 목적이 있어서, 토픽 삭제 후 재생성 방식을 택했다.

---

## 최종 아키텍처

```
┌─────────────────────────────────────────────────────────────────┐
│  API Layer                                                      │
│  - 요청 → Redis Lua (원자적 처리) → 즉시 응답                    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ Kafka 비동기 발행
┌─────────────────────────────────────────────────────────────────┐
│  Kafka (파티션 3개)                                              │
│  - 실패 시 3회 재시도 → DLQ 이동                                 │
└─────────────────────────────────────────────────────────────────┘
          │                   │                   │
          ▼                   ▼                   ▼
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ Consumer 1  │     │ Consumer 2  │     │ Consumer 3  │
│ Partition 0 │     │ Partition 1 │     │ Partition 2 │
└─────────────┘     └─────────────┘     └─────────────┘
          │                   │                   │
          └───────────────────┴───────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  DB Layer                                                       │
│  - 병렬로 INSERT 처리                                           │
│  - DLQ + @Retryable로 실패 복구                                 │
│  - Reconciliation Batch로 정합성 검증                           │
└─────────────────────────────────────────────────────────────────┘
```

---

## 배운 점

### 기술적 학습

| 주제 | 배운 점 |
| :--- | :--- |
| 락의 종류 | 낙관적/비관적/분산락 각각의 적합한 사용처 |
| Redis Lua | 여러 연산을 원자적으로 처리하는 방법 |
| Kafka | DLQ, 파티션, Partitioner의 동작 원리 |
| Spring | @Retryable + @Transactional 조합 시 트랜잭션 관리 |
| 아키텍처 | 동기 vs 비동기, 실시간 정합성 vs 최종 정합성의 트레이드오프 |

### 설계 관점

- **측정 대상을 정확히 이해해야 한다.** 파티션을 늘렸는데 k6 결과가 똑같아서 헤맸다. API 응답 시간이 아니라 Consumer 처리량을 봤어야 했다.

- **실무 패턴을 무조건 따르는 것이 능사가 아니다.** Transactional Outbox Pattern은 좋은 패턴이지만, 현재 요구사항에는 과했다. 상황에 맞는 선택이 중요하다.

- **이중 안전망이 중요하다.** 한 단계에서 실패해도 다음 단계에서 복구할 수 있는 구조를 만들어야 한다. DLQ → @Retryable → Reconciliation Batch 순으로 점점 넓은 그물을 쳤다.

---

## 아쉬운 점 및 개선 방향

### 테스트 환경의 한계

로컬 PC 환경에서 1,000명 동시 접속이 한계였다. 실제 수만~수십만 트래픽을 테스트하려면 클라우드 환경이 필요하다.

### 모니터링 부재

Prometheus + Grafana를 연동하면 Consumer Lag, 처리량, 에러율 등을 실시간으로 확인할 수 있다. 다음 프로젝트에서는 모니터링을 함께 구축할 예정이다.

### 단일 WAS 환경

현재는 WAS 1대로 테스트했다. Nginx 로드밸런싱 + WAS 다중화까지 하면 더 현실적인 환경이 될 것이다.

---

## 마무리

이번 프로젝트를 통해 **고트래픽 환경에서의 동시성 제어**를 단순한 이론이 아닌 직접 구현과 문제 해결을 통해 학습했다. 특히 각 Phase마다 발생한 문제를 해결하면서 **왜 이 기술을 선택해야 하는지**에 대한 근거를 명확히 갖게 됐다.

단순히 "Redis 분산락을 썼습니다"가 아니라, "낙관적 락 → 비관적 락 → 분산락을 거치면서 각각의 한계를 확인하고, 최종적으로 Lua 스크립트 기반의 락 없는 동시성 제어를 선택했습니다"라고 설명할 수 있게 됐다.

이것이 이번 프로젝트의 가장 큰 수확이다.