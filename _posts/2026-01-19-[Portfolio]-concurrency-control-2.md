---
title: 동시성 제어 - 2. 비관적 락
date: 2026-01-19 00:00:00 +09:00
categories: [Spring, Project]
tags: [spring-boot, jpa, pessimistic-lock, concurrency, select-for-update]
image: 
---

## 동시성 제어 #2 - 비관적 락

### 개념
비관적 락(`Pessimistic Lock`)은 **"충돌이 발생할 것"**이라고 비관적으로 가정하는 방식이다. **데이터를 읽는 시점에 락을 걸어서 다른 트랜잭션이 접근하지 못하게 막는다.**

1. 데이터 조회 시 `SELECT ... FOR UPDATE`로 락 획득
2. 트랜잭션이 끝날 때까지 다른 트랜잭션은 대기
3. 커밋 후 락 해제 → 다음 트랜잭션 진행

### 낙관적 락과 비교

| 구분 | 낙관적 락 | 비관적 락 |
| :--- | :--- | :--- |
| **가정** | 충돌 거의 없음 | 충돌 자주 발생 |
| **락 시점** | `UPDATE` 시 검증 | `SELECT` 시 락 획득 |
| **동시성** | **높음(락 없이 조회)** | **낮음(락 대기 발생)** |
| **충돌 처리** | 애플리케이션에서 재시도 | DB에서 순차 처리 |
| **적합 상황** | **읽기 많고 쓰기 적음** | **쓰기 많고 충돌 잦음** |

### 왜 비관적 락으로 전환했나?
`Phase 1` 에서 낙관적 락의 한계를 확인했다. `INSERT`와 `UPDATE`의 락 경합으로 `Deadlock`이 발생했고, `100`개 쿠폰 중 `13`개만 발급됐다. 비관적 락은 **조회 시점에 락을 잡아 순차 처리**하므로 `Deadlock`을 방지할 수 있다.

## 구현 내용

### 전체 흐름
```
클라이언트 요청
    │
    ▼
CouponIssueController
    │
    ▼
CouponIssueService (재시도 로직)
    │  └─ 락 타임아웃 시 재시도
    ▼
CouponIssueTransactionalService (트랜잭션)
    │  ├─ 회원 검증
    │  ├─ 쿠폰 조회 (@Lock + SELECT FOR UPDATE) ← 여기서 락 획득
    │  ├─ 중복 발급 체크
    │  ├─ 재고 차감 (issuedQuantity++)
    │  └─ 발급 이력 저장
    ▼
DB 커밋 (락 해제)
    │
    ├─ 성공 → 응답 반환
    └─ 다음 트랜잭션 진행
```

### 변경 사항

| 위치 | 변경 내용 |
| :--- | :--- |
| `CouponRepository` | `@Lock(OPTIMISTIC)` → `@Lock(PESSIMISTIC_WRITE)` |
| `CouponRepository` | 락 타임아웃 설정 추가 |
| `CouponIssueService` | 예외 처리 대상 변경 |

## 핵심 코드 설명

### CouponRepository - @Lock 변경
```java
public interface CouponRepository extends JpaRepository<Coupon, Long> {

    // 기존: @Lock(LockModeType.OPTIMISTIC)
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @QueryHints(@QueryHint(name = "jakarta.persistence.lock.timeout", value = "3000"))
    @Query("SELECT c FROM Coupon c WHERE c.couponCode = :couponCode")
    Optional<Coupon> findByCouponCodeWithLock(@Param("couponCode") String couponCode);

    ...
}
```

**`@Lock(LockModeType.PESSIMISTIC_WRITE)`**
- 실제 SQL: `SELECT ... FOR UPDATE`
- 조회 시점에 해당 `row`에 배타적 락(`X-Lock`) 획득
- **다른 트랜잭션은 락이 해제될 때까지 대기**

**`@QueryHints(lock.timeout)`**
- 락 대기 최대 시간: `3초`
- 3초 내에 락을 못 잡으면 예외 발생
- **무한 대기 방지**

### SELECT ... FOR UPDATE 동작 원리
```
TX A: SELECT * FROM coupon WHERE coupon_code = 'FLASH100' FOR UPDATE
      → coupon row에 X-Lock 획득
      → UPDATE, INSERT 수행

TX B: SELECT * FROM coupon WHERE coupon_code = 'FLASH100' FOR UPDATE
      → TX A의 락 해제 대기 (블로킹)

TX A: COMMIT → 락 해제

TX B: 락 획득 → 진행
```

낙관적 락과 달리 **동시에 같은 데이터에 접근하는 것 자체를 막는다.**

### CouponIssueService - 예외 처리 변경
```java
@Slf4j
@Service
@RequiredArgsConstructor
public class CouponIssueService {

    private static final int MAX_RETRY_COUNT = 3;
    private final CouponIssueTransactionalService transactionalService;

    public CouponIssueResponse issueCoupon(String couponCode, Long memberId) {
        int retryCount = 0;

        while (retryCount < MAX_RETRY_COUNT) {
            try {
                return transactionalService.issueCouponWithTransaction(couponCode, memberId);
            } catch (PessimisticLockingFailureException e) {
                retryCount++;

                log.warn("비관적 락 획득 실패. 재시도 {}/{} - couponCode: {}, memberId: {}",
                        retryCount, MAX_RETRY_COUNT, couponCode, memberId);

                if (retryCount >= MAX_RETRY_COUNT) {
                    log.error("쿠폰 발급 재시도 횟수 초과 - couponCode: {}, memberId: {}", couponCode, memberId);
                    throw new BusinessException(ErrorCode.COUPON_ISSUE_FAILED);
                }

                try {
                    Thread.sleep((long) Math.pow(2, retryCount) * 10);
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                    throw new BusinessException(ErrorCode.COUPON_ISSUE_FAILED);
                }
            }
        }
        
        throw new BusinessException(ErrorCode.COUPON_ISSUE_FAILED);
    }
}
```

**예외 타입 변경:**

| 락 방식 | 발생 예외 |
| :--- | :--- |
| 낙관적 락 | `ObjectOptimisticLockingFailureException` |
| 비관적 락 | `PessimisticLockingFailureException`, `CannotAcquireLockException` |

비관적 락 에서는 버전 충돌이 아니라 **락 타임아웃**이나 **Deadlock**으로 예외가 발생한다.

### Coupon 엔티티 - @Version 유지
```java
@Entity
@Table(name = "coupons")
public class Coupon {

    ...

    @Version
    private Long version;  // 유지 (선택사항)

    ...
}
```

`@Version`은 제거해도 되지만, **낙관적 락으로 롤백할 가능성**을 고려해 유지했다. **비관적 락 사용 시 `@Version`은 동작하지 않는다.**
> 비관적 락 에서도 `@Version` 이 존재한다면 트랜잭션 종료 시점의 `UPDATE` 에서 `version` 컬럼을 `UPDATE` 한다.

## 부하 테스트 결과

### 테스트 환경

| 항목 | 값 |
|------|-----|
| **동시 사용자** | `500명` |
| **사용자당 요청** | `1회` |
| **쿠폰 수량** | `100개` |
| **DB** | `MySQL 8.0(InnoDB)` |
| **Connection Pool** | `HikariCP(max: 50)` |
| **락 타임아웃** | `3초` |

### 테스트 결과
![](/assets/img/2026-01-19/Portfolio-concurrency-control-2-1.png)*[k6 test]*

```
// 테스트 결과 요약
- 총 요청: 500
- 성공: 100 (20%)
- 실패: 400 (80%)
- 평균 응답시간: 7,310ms
- 최대 응답시간: 9,590ms
```

### 낙관적 락 vs 비관적 락 비교

| 지표 | 낙관적 락 | 비관적 락 | 변화 |
|:---|:---|:---|:---|
| **성공률** | `2.6%(13/500)` | `20%(100/500)` | **`7.7`배 개선** |
| **발급된 쿠폰** | `13개` | `100개` | **목표 달성** |
| **평균 응답시간** | `9,040ms` | `7,310ms` | **`19%` 단축** |
| **최대 응답시간** | `13,610ms` | `9,590ms` | **`30%` 단축** |
| **Deadlock** | 발생 | 없음 | **해결** |

### 결과 분석
**성공 `100`건 = 정상 동작**

`100`개 쿠폰이 정확히 `100`명에게 발급됐다. 나머지 `400`명은 재고 소진 후 요청했기 때문에 실패한 것이다.

**Deadlock 해결**

낙관적 락에서는 `INSERT`와 `UPDATE`의 락 획득 순서가 꼬여 `Deadlock`이 발생했다. 비관적 락은 **`SELECT` 시점에 먼저 락을 잡기 때문에** 이후 작업이 순차적으로 진행된다.

```
낙관적 락:
TX A: INSERT (락1) → UPDATE (락2 대기)
TX B: INSERT (락2) → UPDATE (락1 대기)
→ Deadlock!

비관적 락:
TX A: SELECT FOR UPDATE (락 획득) → INSERT → UPDATE → COMMIT
TX B: SELECT FOR UPDATE (대기) → ... → COMMIT
→ 순차 처리
```

## 여전히 남은 문제

### 응답 시간
평균 `7.3`초는 사용자가 화면을 이탈하거나 다른 요청을 보낼 수 있다.

| 일반적인 기준 | 현재 결과 |
| :--- | :--- |
| 좋음: `< 200ms` | **매우 느림** |
| 보통: `< 1초` | **매우 느림** |
| 나쁨: `> 3초` | **매우 느림** |

### 원인: 락 대기 시간
`500`명이 동시에 요청하면 **`499`명은 락을 기다려야 한다.** `Connection Pool`이 `50`개이므로 최대 `50`개 트랜잭션만 동시 처리 가능하고, 나머지는 대기열에 쌓인다.

```
요청 500개 → Connection Pool 50개 → 락 1개
→ 결국 1명씩 순차 처리
→ 뒤에 있는 요청일수록 응답 시간 증가
```

### 정리: 비관적 락의 한계

| 기대 | 현실 |
| :--- | :--- |
| **Deadlock 해결** | 해결됨 |
| **정확한 재고 관리** | `100개` 정확히 발급 |
| **빠른 응답** | 평균 `7초` |
| **높은 처리량** | 순차 처리로 병목 |

**결론:** 비관적 락은 **정확성**은 보장하지만 **성능**에 한계가 있다. **`DB`락에 의존하는 한 처리량을 높이기 어렵다.**

## 느낀점 및 다음 단계

### 이번 Phase 에서 배운 것
**JPA 비관적 락**
- `@Lock(PESSIMISTIC_WRITE)`는 `SELECT ... FOR UPDATE`로 변환
- **조회 시점에 락을 잡아 동시 접근 자체를 차단**

**Deadlock 해결**
- 락 획득 순서를 일관되게 만들면 `Deadlock` 방지
- 비관적 락은 `SELECT` → `INSERT` → `UPDATE` 순서 보장

**락 타임아웃**
- 무한 대기 방지를 위해 타임아웃 설정 필수
- 타임아웃 시 적절한 예외 처리와 재시도 필요

**성능 트레이드오프**
- 정확성 ↑ vs 성능 ↓
- **`DB` 락만으로는 대용량 트래픽 처리에 한계**

### 다음 단계: Phase 3 - Redis 분산 락
`DB` 락의 한계를 확인했다. 다음에는 **Redis 분산 락**을 적용해본다.

**다룰 내용:**
- `Redisson`을 이용한 분산 락 구현
- `DB` 부하를 `Redis`로 분산
- 비관적 락과 성능 비교
- 분산 환경에서의 동시성 제어