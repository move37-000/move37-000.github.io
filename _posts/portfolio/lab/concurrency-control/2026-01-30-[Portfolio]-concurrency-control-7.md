---
title: 동시성 제어 - 7. Reconciliation Batch - 비동기 전환과 정합성 검증
date: 2026-01-30
categories: [Spring, Project]
tags: [kafka, batch, reconciliation, scheduler, async]
image: 
---

## 동시성 제어 #7 - Reconciliation Batch

### 이전 Phase의 구조
`Phase 6`까지 `DLQ` 기반 실패 복구 체계를 구축했다. 하지만 한 가지 개선점이 남아있었다.

```java
// 기존 코드 - 동기 방식
kafkaTemplate.send("coupon-issued", couponCode, event).get(5, TimeUnit.SECONDS);
```

`.get()`을 사용한 동기 전송은 **데이터 정합성을 보장하는 확실한 방법**이지만, 고트래픽 환경에서는 **'양날의 검'**이다.

| 장점 | 단점 |
| :--- | :--- |
| `Kafka` 브로커 안착 보장 | `WAS` 스레드 블로킹 |
| 실패 시 즉각 롤백 가능 | 스레드 풀 고갈 위험 |

선착순 시스템의 핵심은 **'빠른 응답과 가용성'**이다. 실시간 정합성을 위해 사용자를 대기시키는 대신, **빠르게 처리하고 사후에 정합성을 맞추는 전략**으로 전환하기로 했다.

### 개선된 아키텍처
```
┌─────────────────────────────────────────────────────────────────┐
│  Layer 1: 실시간 방어                                            │
│  - Kafka 비동기 발행 + 콜백                                       │
│  - 발행 실패 시 즉시 Redis 롤백                                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Layer 2: 실패 복구 (Phase 6)                                    │
│  - DLQ + @Retryable                                             │
│  - 최종 실패 시 보상 트랜잭션 + 실패 테이블                       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Layer 3: 정합성 검증 - 안전망 (이번 Phase)                       │
│  - Reconciliation Batch                                         │
│  - Redis ↔ DB 주기적 비교                                        │
│  - 불일치 감지 시 자동 복구                                       │
│  - 발급 수량 통계 동기화                                          │
└─────────────────────────────────────────────────────────────────┘
```

**3단계 방어 체계**로 데이터 정합성을 보장한다.

## 구현

### 비동기 + 콜백으로 전환
```java
@Slf4j
@Service
@RequiredArgsConstructor
public class CouponIssueService {

    ...

    public CouponIssueResponse issueCoupon(String couponCode, Long memberId) {
        
        ...

        kafkaTemplate.send("coupon-issued", couponCode, event)
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

        ...
    }
}
```

**변경점:**
- `.get()` 제거 → **스레드 블로킹 없음**
- `.whenComplete()` 콜백 → **비동기로 결과 처리**
- 발행 실패 시 콜백에서 `Redis` 롤백

### ReconciliationService
```java
@Slf4j
@Service
@RequiredArgsConstructor
public class ReconciliationService {

    private final StringRedisTemplate redisTemplate;
    private final CouponRepository couponRepository;
    private final CouponIssueRepository couponIssueRepository;
    private final FailedCouponIssueRepository failedCouponIssueRepository;

    private static final String ISSUED_SET_PREFIX = "coupon:issued:";

    /**
     * Redis ↔ DB 정합성 검증
     * - Redis에는 있는데 DB에 없으면 → 불일치 (Consumer 실패)
     */
    public ReconciliationResult reconcile(String couponCode) {
        // 1. Redis에서 발급된 멤버 목록 조회
        Set<String> redisMembers = redisTemplate.opsForSet().members(ISSUED_SET_PREFIX + couponCode);

        if (redisMembers == null || redisMembers.isEmpty()) {
            log.info("Redis에 발급 내역 없음 - couponCode: {}", couponCode);
            return new ReconciliationResult(0, 0, List.of());
        }

        // 2. DB에서 발급된 멤버 목록 조회
        Coupon coupon = couponRepository.findByCouponCode(couponCode)
                .orElseThrow(() -> new IllegalArgumentException("쿠폰 없음: " + couponCode));

        List<Long> dbMembers = couponIssueRepository.findMemberIdsByCouponId(coupon.getId());
        Set<Long> dbMemberSet = new HashSet<>(dbMembers);

        // 3. 불일치 감지 (Redis O, DB X)
        List<Long> mismatched = redisMembers.stream()
                .map(Long::valueOf)
                .filter(memberId -> !dbMemberSet.contains(memberId))
                .toList();

        if (!mismatched.isEmpty()) {
            log.warn("[RECONCILIATION] 불일치 발견 - couponCode: {}, memberIds: {}", couponCode, mismatched);
        }

        return new ReconciliationResult(
                redisMembers.size(),
                dbMembers.size(),
                mismatched
        );
    }

    /**
     * 불일치 건 자동 복구
     * - Redis에서 제거 (롤백)
     * - 실패 테이블에 기록
     */
    public void recover(String couponCode, List<Long> mismatchedMembers) {
        for (Long memberId : mismatchedMembers) {
            try {
                // Redis에서 제거
                redisTemplate.opsForSet().remove(ISSUED_SET_PREFIX + couponCode, String.valueOf(memberId));
                redisTemplate.opsForValue().increment("coupon:stock:" + couponCode);

                // 실패 테이블에 기록
                FailedCouponIssue failedIssue = FailedCouponIssue.builder()
                        .couponCode(couponCode)
                        .memberId(memberId)
                        .reason("Reconciliation 불일치 감지 - Redis에만 존재")
                        .build();

                failedCouponIssueRepository.save(failedIssue);
            } catch (Exception e) {
                log.error("복구 실패 - couponCode: {}, memberId: {}, error: {}", couponCode, memberId, e.getMessage());
            }
        }
    }

    /**
     * 발급 수량 동기화
     * - DB의 실제 발급 건수를 쿠폰 테이블에 반영
     */
    @Transactional
    public void syncIssuedQuantity(Coupon coupon) {
        int actualCount = couponIssueRepository.countByCouponId(coupon.getId());

        if (coupon.getIssuedQuantity() != actualCount) {
            coupon.updateIssuedQuantity(actualCount);
            couponRepository.save(coupon);
        }
    }
}
```

### ReconciliationResult
```java
public record ReconciliationResult(int redisCount, int dbCount, List<Long> mismatchedMemberIds) {

    public boolean hasMismatch() {
        return !mismatchedMemberIds.isEmpty();
    }

    public int mismatchCount() {
        return mismatchedMemberIds.size();
    }
}
```

### ReconciliationScheduler
```java
@Slf4j
@Component
@RequiredArgsConstructor
public class ReconciliationScheduler {

    private final ReconciliationService reconciliationService;
    private final CouponRepository couponRepository;

    /**
     * 5분마다 정합성 검증 실행
     */
    @Scheduled(fixedRate = 300000)
    public void runReconciliation() {
        List<Coupon> activeCoupons = couponRepository.findAllByStatus(CouponStatus.ACTIVE);

        for (Coupon coupon : activeCoupons) {
            try {
                // 1. 정합성 검증
                ReconciliationResult result = reconciliationService.reconcile(coupon.getCouponCode());

                if (result.hasMismatch()) {
                    reconciliationService.recover(coupon.getCouponCode(), result.mismatchedMemberIds());
                }

                // 2. 발급 수량 동기화
                reconciliationService.syncIssuedQuantity(coupon);
            } catch (Exception e) {
                log.error("Reconciliation 실패 - couponCode: {}, error: {}", coupon.getCouponCode(), e.getMessage());
            }
        }
    }
}
```

### HighTrafficLabApplication
```java
@EnableRetry
@EnableScheduling  // 추가
@SpringBootApplication
public class HighTrafficLabApplication {
    public static void main(String[] args) {
        SpringApplication.run(HighTrafficLabApplication.class, args);
    }
}
```

### CouponIssueRepository
```java
// 추가
@Query("SELECT ci.memberId FROM CouponIssue ci WHERE ci.couponId = :couponId")
List<Long> findMemberIdsByCouponId(@Param("couponId") Long couponId);

// 추가
int countByCouponId(Long couponId);
```

### CouponRepository
```java
// 추가
List<Coupon> findAllByStatus(CouponStatus status);
```

### Coupon
```java
// 추가
public void updateIssuedQuantity(int quantity) {
        this.issuedQuantity = quantity;
}
```
## 왜 발급 수량을 Batch에서 처리하는가?
기존에 주석 처리했던 코드가 있었다.

```java
// CouponIssueConsumer.handleCouponIssued 
// coupon.increaseIssuedQuantity();
// couponRepository.save(coupon);
```


### Consumer에서 처리하면?
```
Consumer 1: SELECT issued_quantity → 50
Consumer 2: SELECT issued_quantity → 50
Consumer 1: UPDATE issued_quantity = 51
Consumer 2: UPDATE issued_quantity = 51  ← 52여야 함!
```

**동시성 이슈 발생.** 락을 걸면 해결되지만, 트래픽 몰릴 때 성능이 급감한다.

### Batch에서 처리하면?
```java
int actualCount = couponIssueRepository.countByCouponId(coupon.getId());
coupon.updateIssuedQuantity(actualCount);
```

**DB에서 실제 건수를 COUNT** → 동시성 이슈 없음.

| 방식 | 장점 | 단점 |
| :--- | :--- | :--- |
| Consumer + 락 | 실시간 | 성능 저하 |
| **Batch + COUNT** | 동시성 이슈 없음 | 실시간 아님 |

## 실행 흐름 정리
```
┌─────────────────────────────────────────────────────────────────┐
│  Reconciliation Batch (5분마다)                                  │
│  ─────────────────────────────────────────────────────────────  │
│                                                                 │
│  for (활성 쿠폰) {                                               │
│      1. Redis 발급 목록 조회                                     │
│      2. DB 발급 목록 조회                                        │
│      3. 비교 → 불일치 감지                                       │
│      4. 불일치 건 복구 (Redis 롤백 + 실패 테이블 저장)            │
│      5. 발급 수량 동기화 (COUNT → UPDATE)                        │
│  }                                                              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## 정리
이번 `Phase`에서 비동기 전환과 `Reconciliation Batch`를 구현했다.

### 변경 사항

| 항목 | Before | After |
| :--- | :--- | :--- |
| Kafka 발행 | `.get()` 동기 | **비동기 + 콜백** |
| 정합성 검증 | 없음 | **Batch로 주기적 검증** |
| 발급 수량 통계 | 주석 처리 | **Batch에서 COUNT** |

### 3단계 방어 체계

| Layer | 역할 | 감지 시점 |
| :--- | :--- | :--- |
| 콜백 | `Kafka` 발행 실패 | 즉시 |
| `DLQ` | `Consumer` 처리 실패 | 즉시 |
| **Batch** | 모든 케이스 (최후 안전망) | 주기적 |

### 아직 남은 것
- 트래픽을 대용량으로 늘려서 테스트해보기

다음 포스팅에서 `Kafka` 파티션 확장을 통하여 대량 트래픽을 테스트해본다.