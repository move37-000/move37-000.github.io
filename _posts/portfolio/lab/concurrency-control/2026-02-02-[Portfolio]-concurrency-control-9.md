---
title: 동시성 제어 - 9. 프로젝트 정리
date: 2026-02-02
categories: [Spring, Project]
tags: [concurrency, redis, kafka, retrospective]
image: 
---

## 프로젝트 개요
선착순 쿠폰 발급 시스템은 **대규모 트래픽 환경에서의 동시성 제어**를 경험해보기 위한 포트폴리오 프로젝트다. 단순한 기능 구현이 아니라, 실제 현업에서 사용하는 아키텍처 패턴을 직접 구현하고 그 과정에서 발생하는 문제들을 해결하는 데 초점을 맞췄다.

### 프로젝트 목표
- 수천 ~ 수만 명이 동시에 요청하는 상황에서 **데이터 정합성** 보장
- **빠른 응답 시간** 유지 (사용자 경험)
- 장애 상황에서도 **데이터 유실 없이 복구** 가능한 구조 설계

### 기술 스택

| 분류 | 기술 |
| :--- | :--- |
| `Backend` | `Spring Boot 4.0, Java 17` |
| `Database` | `MySQL 8.0` |
| `Cache` | `Redis (Redisson)` |
| `Message Queue` | `Apache Kafka` |
| `Testing` | `k6` (부하 테스트) |

### Phase 1: 낙관적 락 (Optimistic Lock) <a href="/posts/Portfolio-concurrency-control-1" target="_blank" class="btn btn-outline-secondary" style="font-size: 11px; padding: 2px 6px; border-color: #6c757d80; color: #6c757d;"><i class="fas fa-external-link-alt fa-xs"></i></a>
`DB` 락 없이 버전 기반으로 충돌을 감지하는 방식을 먼저 구현했다.

```java
// Coupon.java

@Version
private Long version;
```

쿠폰 엔티티에 `@Version`을 추가하고, 업데이트 시 버전이 달라지면 `OptimisticLockException`이 발생하도록 했다.

**결과:** 동시 요청 시 대부분 실패. 쿠폰의 재고 테이블을 동시에 여러 요청이 `UPDATE` 하다 보니 **충돌이 너무 빈번하게 발생했다.**

**배운 점:** 낙관적 락은 **충돌이 적은 환경**에서 적합하다. 내 프로젝트처럼 **동시 요청이 폭주하는 상황에서는 맞지 않았다.**

### Phase 2: 비관적 락 (Pessimistic Lock) <a href="/posts/Portfolio-concurrency-control-2" target="_blank" class="btn btn-outline-secondary" style="font-size: 11px; padding: 2px 6px; border-color: #6c757d80; color: #6c757d;"><i class="fas fa-external-link-alt fa-xs"></i></a>
낙관적 락의 한계를 확인한 후, `DB` 레벨에서 직접 락을 거는 **비관적 락**을 적용했다.

```java
// CouponRepository.java

@Lock(LockModeType.PESSIMISTIC_WRITE)
@Query("SELECT c FROM Coupon c WHERE c.couponCode = :couponCode")
Optional<Coupon> findByCouponCodeWithLock(@Param("couponCode") String couponCode);
```

**결과:** 데이터 정합성은 보장됐지만, **처리량이 급격히 떨어졌다.** 모든 요청이 순차적으로 **하나의 락을 기다리면서 직렬화되는 문제가 발생했다.**

**배운 점:** 비관적 락은 **정합성을 확실히 보장**하지만, 고트래픽 환경에서는 **병목 지점**이 된다. 또한 서버가 여러대일 경우도 문제가 되었다. `DB` 락만으로는 분산 환경에서 한계가 있다.

### Phase 3: Redis 분산락 (Distributed Lock) <a href="/posts/Portfolio-concurrency-control-3" target="_blank" class="btn btn-outline-secondary" style="font-size: 11px; padding: 2px 6px; border-color: #6c757d80; color: #6c757d;"><i class="fas fa-external-link-alt fa-xs"></i></a>
서버가 여러 대인 분산 환경에서도 동작하는 락이 필요했다. `Redis` 기반의 분산락을 `Redisson`으로 구현했다.

> 서버(WAS)를 여러대로 늘려서 진행하진 않았지만, 실제 상황을 고려하여 진행했다.

```java
// CouponIssueService.java

RLock lock = redissonClient.getLock("coupon:" + couponCode);
try {
    if (lock.tryLock(5, 10, TimeUnit.SECONDS)) {
        ...
    }
} finally {
    lock.unlock();
}
```

**결과:** 분산 환경에서도 정합성이 보장됐다. 하지만 여전히 **락 경합으로 인한 성능 저하가 있었다.**                                                                                    

**배운 점:** 분산락은 분산 환경에서 필수지만, 락 자체가 **병목**이라는 본질적인 문제는 그대로였다. 락 없이 동시성을 제어할 방법이 필요했다.

### Phase 4: Redis DECR + Kafka 비동기 <a href="/posts/Portfolio-concurrency-control-4" target="_blank" class="btn btn-outline-secondary" style="font-size: 11px; padding: 2px 6px; border-color: #6c757d80; color: #6c757d;"><i class="fas fa-external-link-alt fa-xs"></i></a>
발상을 전환했다. 락을 거는 대신 `Redis`**의 원자적 연산**으로 재고를 관리하고, `DB` 저장은 `Kafka`**를 통해 비동기**로 처리하기로 했다.

```
요청 → Redis DECR (재고 차감) → Kafka 발행 → 즉시 응답
                                    ↓
                        Consumer → DB 저장 (백그라운드)
```

**핵심 변화:**
- 사용자 응답이 `Redis`에서 끝남 → **응답 속도 향상**
- `DB` 저장은 백그라운드 → `DB` **부하 분산**

**결과:** 
- 응답 속도가 매우 빨라졌다. 하지만 새로운 문제가 생겼다. `DECR`만으로는 **데이터 정합성 유지**가 안 됐다.
- `Kafka Consumer` 에서 쿠폰의 재고 테이블을 **동시에 여러 요청이** `UPDATE` **하는 문제가 발생했었다.**

> `Kafka` 비동기를 유지하는 한 해당 문제는 해결할 수 없었다. 결국 `Kafka Consumer` 에서 재고 컬럼 `UPDATE` 로직을 제거했다.

### Phase 5: Lua 스크립트로 원자적 처리, Kafka 안전성 <a href="/posts/Portfolio-concurrency-control-5" target="_blank" class="btn btn-outline-secondary" style="font-size: 11px; padding: 2px 6px; border-color: #6c757d80; color: #6c757d;"><i class="fas fa-external-link-alt fa-xs"></i></a>
`Redis`에서 재고 차감과 중복 체크를 **하나의 원자적 연산**으로 처리해야 했다. `Lua` 스크립트를 도입했다.

```lua
-- decrease_stock.lua

-- 1. 중복 체크
local added = redis.call('SADD', KEYS[2], ARGV[1])
if added == 0 then
	return -3
end

-- 2. 재고 확인
local stock = redis.call('GET', KEYS[1])
if not stock then
	redis.call('SREM', KEYS[2], ARGV[1])
	return -1
end

-- 3.재고 수량 검증
stock = tonumber(stock)
if stock <= 0 then
	redis.call('SREM', KEYS[2], ARGV[1])
	return -2
end

-- 4. 재고 차감
return redis.call('DECR', KEYS[1])
```

또한, '`Kafka` 에 `get()` 을 추가하여 **데이터 정합성** 을 향상시켰다.

```java
// CouponIssueService.java

kafkaTemplate.send(TOPIC, couponcode, event).get(5, TimeUnit.SECONDS);
```

**핵심 변화:**
- `Lua` 스크립트로 인해 세 가지 연산이 **하나의 트랜잭션**처럼 동작한다. **중간에 다른 요청이 끼어들 수 없다.**
- `get()` 으로 인해 `Kafka` 발행 실패시의 `Redis` 와 `DB` 간의 **데이터 정합성을 유지시켰다.**

**결과:** **데이터 정합성이 매우 크게 상승했다.** 하지만 `get()` 사용으로 인하여 **트래픽의 많을 경우 치명적인 대기 시간(**`50ms`**)이 발생해버렸다.**

### Phase 6: DLQ + @Retryable (실패 복구) <a href="/posts/Portfolio-concurrency-control-6" target="_blank" class="btn btn-outline-secondary" style="font-size: 11px; padding: 2px 6px; border-color: #6c757d80; color: #6c757d;"><i class="fas fa-external-link-alt fa-xs"></i></a>
`Kafka Consumer`에서 `DB` 저장 실패 시 어떻게 할지 고민했다. `Dead Letter Queue(DLQ)`와 Spring의 `@Retryable`을 조합했다.

```
Main Consumer 실패 → 3회 재시도 → DLQ로 이동
                                    ↓
                    DLQ Consumer → 3회 재시도 → 최종 실패 시 실패 테이블 저장
```

```java
// CouponIssueDlqProcessor.java

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

**핵심 변화:**
- 네트워크 오류 등 일시적인 오류로 인한 `Kafka` **메시지 발행의 문제 해결(재시도 로직)**
- `DLQ` 로직 추가로 인한 **실패 메시지 보존, 실패 기록 관리**
- `DLQ` 로직에서의 **보상 트랜잭션(**`Redis` **롤백)**

> `@Retryable`의 동작 원리를 정확히 이해하게 됐다. 그리고 `@Backoff`로 지수 백오프를 선언적으로 구현할 수 있어서 코드가 깔끔해졌다.

### Phase 7: Reconciliation Batch (정합성 검증) 과 비동기 전환 <a href="/posts/Portfolio-concurrency-control-7" target="_blank" class="btn btn-outline-secondary" style="font-size: 11px; padding: 2px 6px; border-color: #6c757d80; color: #6c757d;"><i class="fas fa-external-link-alt fa-xs"></i></a>
`DLQ`까지 실패하면 `Redis`와 `DB` **사이에 불일치**가 발생할 수 있다. 이를 감지하고 복구하는 배치를 구현했다.

```java
// ReconciliationScheduler.java

@Scheduled(initialDelay = 300000, fixedRate = 300000)  // 5분마다
public void runReconciliation() {
    // 1. DB 발급 목록 조회
    // 2. Redis 발급 목록 조회
    // 3. 불일치 감지 → 복구(Redis 제거)
    // 4. 실패 테이블 기록
    // 5. 발급 수량 동기화
}
```

> 발급 수량 동기화를 통해 `Phase 4` 에서 발생한 재고 테이블(컬럼) 락 문제를 해결하였다.

또한 `Phase 5` 에서 발생한 `get()` 사용으로 인한 **대기 시간** 문제를 비동기 전환으로 해결하였다.

```java
// CouponIssueService.java

kafkaTemplate.send("coupon-issued", event)
                .whenComplete((result, ex) -> {
                    if (ex != null) {
                        log.error("Kafka 발행 실패 - couponCode: {}, memberId: {}, error: {}", couponCode, memberId, ex.getMessage());

                        // 실패 시 Redis 롤백
                        try {
                            stockService.rollbackStock(couponCode, memberId);
                            log.info("Redis 롤백 완료 - couponCode: {}, memberId: {}", couponCode, memberId);
                        } catch (Exception rollbackEx) {
                            log.error("Redis 롤백 실패 - couponCode: {}, memberId: {}, error: {}", couponCode, memberId, rollbackEx.getMessage());
                        }
                    } else {
                        log.debug("Kafka 발행 성공 - couponCode: {}, memberId: {}", couponCode, memberId);
                    }
                });
```

**Reconciliation Batch 를 통한 검증 로직:**

| 상황 | 조치 |
| :--- | :--- |
| `Redis O, DB X` | `DB`에 `INSERT` (`Consumer` 실패 복구) |
| `Redis X, DB O` | 발생 불가 (`Redis` 없이 `DB` 저장 경로 없음) |

> 현재 구조에서는 `Redis`를 거치지 않으면 `Kafka` 발행 자체가 안 된다. `Redis` 없이 `DB`에만 데이터가 있는 경우는 정상 흐름에서 발생하지 않는다.

### 비고: Phase 5 에서의 선택과 Phase 7 에서의 전환
`Phase 5`에서 `get()`을 사용한 이유는 `Kafka` 발행 실패 시 `Redis`와 `DB` 간 **불일치를 방지**하기 위해서였다. 

> 발행 성공을 확인해야만 사용자에게 응답할 수 있었다.

하지만 `Phase 6`에서 `DLQ + @Retryable, Phase 7`에서 `Reconciliation Batch`를 구축하면서 **사후 복구 메커니즘이 충분히 갖춰졌다.** 

이제 `Kafka` 발행이 실패해도:
1. `whenComplete()` 콜백에서 즉시 `Redis` 롤백
2. 혹시 롤백도 실패하면 `Reconciliation Batch`가 `5분`마다 정합성 검증

이 이중 안전망 덕분에 동기 대기(`get()`) 없이도 **정합성을 보장할 수 있게 되어 비동기로 전환했다.**

### Phase 8: Kafka 파티션 확장 <a href="/posts/Portfolio-concurrency-control-8" target="_blank" class="btn btn-outline-secondary" style="font-size: 11px; padding: 2px 6px; border-color: #6c757d80; color: #6c757d;"><i class="fas fa-external-link-alt fa-xs"></i></a>
마지막으로 `Consumer`의 **병렬 처리 능력을 높이기 위해 파티션을 확장했다.**

```
Before: Producer → Partition 0 → Consumer 1 → DB

After:  Producer → Partition 0 → Consumer 1 → DB
                 → Partition 1 → Consumer 2 → DB
                 → Partition 2 → Consumer 3 → DB
```

**구현 과정에서 겪은 문제들:**
1. `NewTopic Bean`**만으로 토픽이 안 만들어짐** → `KafkaAdmin Bean` 추가 필요
2. `Consumer`**가 먼저 연결하면 파티션 1개로 자동 생성** → `allow.auto.create.topics = false` 설정
3. **메시지가 한 파티션에만 몰림** → `Sticky Partitioner`가 기본값이라서 발생. 대용량 트래픽에서는 자연스럽게 분산되므로 기본값 유지

> `RoundRobin` 을 적용하면 여러 파티션으로 메시지가 분산되지만 로컬 환경상 트래픽이 많지 않아 기본값인 `Sticky` 를 적용했다.

### 비고: 멱등성(Idempotency) 보장
`DLQ` 재시도나 파티션 분산 처리 시 같은 메시지가 여러 번 처리될 수 있다. 이를 방지하기 위해 **멱등성을 보장하는 구조를 설계했다.**

**1차 방어: Redis SADD(원자적 중복 체크)**
```lua
-- decrease_stock.lua

local added = redis.call('SADD', KEYS[2], ARGV[1])
```

`SADD`는 추가 성공 시 `1`, 이미 존재하면 `0` 을 반환한다. `SISMEMBER`로 체크 후 `SADD`하는 방식보다 원자적이라 `Race Condition`이 발생하지 않는다.

**2차 방어: DB Unique 제약조건**
```sql
CONSTRAINT uk_coupon_member UNIQUE (coupon_id, member_id)
```

같은 `(couponm_id, member_id)` 조합으로 중복 `INSERT` 시 `DB` 에서 예외가 발생한다.

**3차 방어: Consumer 로직**
```java
// CouponIssueConsumer.java

if (couponIssueRepository.existsByCouponIdAndMemberId(coupon.getId(), event.getMemberId())) {
    log.info("이미 처리된 메시지 - couponCode: {}, memberId: {}", event.getCouponCode, event.getMemberId());
    return;
}
```

`INSERT` 전에 한 번 더 체크하여 불필요한 예외 발생을 방지한다.

## 실무와의 차이점

### Transactional Outbox Pattern 미적용
처음에는 `Transactional Outbox Pattern`도 고려했다. `DB`와 `Kafka` 발행의 **원자성을 보장하는 패턴이다.**

```
일반적인 구조:(현 프로젝트 구조)
Redis 처리 → Kafka 발행 → 응답 (Kafka 실패 시 불일치)

Outbox Pattern:
DB 저장 + Outbox 테이블 저장 (하나의 트랜잭션)
→ CDC/Polling으로 Outbox → Kafka 발행
```

**적용하지 않은 이유:**

| 항목 | Outbox Pattern | 현재 구조 |
| :--- | :--- | :--- |
| **메인 저장소** | `DB` | `Redis` |
| **추가 오버헤드** | `DB Polling or CDC` | **없음** |
| **지연 시간** | 증가 | **최소화** |
| **적합한 케이스** | 주문/결제 | **선착순 쿠폰** |

선착순 쿠폰 시스템의 핵심은 **빠른 응답과 가용성**이다. 실시간 정합성을 위해 사용자를 대기시키는 것보다, **빠르게 이벤트를 처리하고 사후에 데이터를 맞추는 전략**이 더 적합하다고 판단했다.

대신 `DLQ + @Retryable + Reconciliation Batch`로 **이중 안전망**을 구축해서 정합성을 보장했다.

### 실시간 리밸런싱 미적용
파티션 테스트 시(`Phase 8`) **토픽을 삭제하고 재생성하는 방식을 사용했다.** 실제 운영 환경에서는 **서비스 중단 없이 실시간 리밸런싱**을 활용한다.

**실시간 리밸런싱이란:**
- 서비스 운영 중에 `Kafka CLI`로 파티션 수를 늘리면, 브로커가 이를 감지하고 `Consumer`들에게 파티션 소유권을 재배분한다.
- `Kubernetes`에서 `Consumer Pod`를 늘리는 것만으로 즉각적인 `Scale-out`이 가능하다.

**고려할 점:**
- 리밸런싱 중 짧은 순간 `Consumer` 읽기가 일시 정지될 수 있다.
- 메시지 중복 처리 위험이 있어 **멱등성 설계**가 필수다.

본 프로젝트는 로컬 환경에서 파티션 구조 변화에 따른 동시성 제어 메커니즘을 확인하는 데 목적이 있어서, 토픽 삭제 후 재생성 방식을 택했다.

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
│  - 병렬로 INSERT 처리                                            │
│  - DLQ + @Retryable로 실패 복구                                  │
│  - Reconciliation Batch로 정합성 검증                            │
└─────────────────────────────────────────────────────────────────┘
```

## 배운 점

### 기술적 학습

| 주제 | 배운 점 |
| :--- | :--- |
| **락의 종류** | 낙관적/비관적/분산락 각각의 적합한 사용처 |
| `Redis Lua` | 여러 연산을 원자적으로 처리하는 방법 |
| `Kafka` | `DLQ`, `Partition`, `Partitioner`의 동작 원리 |
| `Spring` | `@Retryable + @Transactional` 조합 시 트랜잭션 관리 |
| **아키텍처** | 동기 vs 비동기, 실시간 정합성 vs 최종 정합성의 트레이드오프 |

### 설계 관점
- **실무 패턴을 무조건 따르는 것이 능사가 아니다.** `Transactional Outbox Pattern`은 좋은 패턴이지만, 현재 요구사항에는 과했다. 상황에 맞는 선택이 중요하다.
- **이중 안전망이 중요하다.** 한 단계에서 실패해도 다음 단계에서 복구할 수 있는 구조를 만들어야 한다. `DLQ → @Retryable → Reconciliation Batch` 순으로 점점 넓은 그물을 쳤다.

## 아쉬운 점 및 개선 방향

### 테스트 환경의 한계
로컬 `PC` 환경에서 `1,000`명 동시 접속이 한계였다. **실제 수만 ~ 수십만 트래픽을 테스트하려면 클라우드 환경이 필요하다.**

### 모니터링 부재
`Prometheus + Grafana`를 연동하면 `Consumer Lag`, **처리량, 에러율 등을 실시간으로 확인**할 수 있다. 다음 프로젝트에서는 모니터링을 함께 구축할 예정이다.

### 단일 WAS 환경
현재는 `WAS 1대`로 테스트했다. `Nginx` **로드밸런싱** + `WAS` **다중화**까지 하면 더 현실적인 환경이 될 것이다.


## 마무리
이번 프로젝트를 통해 **고트래픽 환경에서의 동시성 제어**를 단순한 이론이 아닌 직접 구현과 문제 해결을 통해 학습했다. 특히 각 `Phase`마다 발생한 문제를 해결하면서 **왜 이 기술을 선택해야 하는지**에 대한 근거를 명확히 갖게 됐다.

단순히 "`Redis` 분산락을 썼습니다."가 아니라, "낙관적 락 → 비관적 락 → 분산락을 거치면서 각각의 한계를 확인하고, 최종적으로 `Lua` 스크립트 기반의 락 없는 동시성 제어를 선택했습니다."라고 설명할 수 있게 됐다.

이것이 이번 프로젝트의 가장 큰 수확이다.