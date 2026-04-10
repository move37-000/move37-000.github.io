---
title: 동시성 제어 - 1. 낙관적 락
date: 2026-01-14
categories: [Spring, Project]
tags: [spring-boot, jpa, optimistic-lock, concurrency, version]
image: 
---

## 동시성 제어 #1 - 낙관적 락

### 개념
낙관적 락(`Optimistic Lock)`은 **"충돌이 거의 없을 것"**이라고 낙관적으로 가정하는 방식이다. **데이터를 읽을 때는 락을 걸지 않고, 수정할 때 다른 사람이 먼저 수정했는지 확인한다.**

1. 데이터 조회 시 `version` 값을 함께 가져온다.
2. 데이터 수정 시 `WHERE version = ?` 조건으로 `UPDATE`
3. `version`이 바뀌어 있으면 `UPDATE` 실패 → 예외 발생 → 재시도

### 비관적 락과 비교

| 구분 | 낙관적 락 | 비관적 락 |
| :--- | :--- | :--- |
| **가정** | 충돌 거의 없음 | 충돌 자주 발생 |
| **락 시점** | `UPDATE` 시 검증 | `SELECT` 시 락 획득 |
| **동시성** | **높음(락 없이 조회)** | **낮음(락 대기 발생)** |
| **충돌 처리** | 애플리케이션에서 재시도 | DB에서 순차 처리 |
| **적합 상황** | **읽기 많고 쓰기 적음** | **쓰기 많고 충돌 잦음** |

### 왜 낙관적 락을 먼저 선택했나?
선착순 쿠폰 발급은 **읽기(조회) 후 쓰기(발급)가 순간적으로 몰리는 상황이다.** 비관적 락은 조회 시점부터 락을 잡아서 대기 시간이 길어질 수 있다. 낙관적 락은 일단 조회를 빠르게 하고, 충돌 시에만 재시도하니까 **처리량(throughput)이 더 높을 것**이라 기대했다.
> 결과적으로 문제가 발생했는데, 이건 뒤에서 다룬다.

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
    │  └─ 낙관적 락 충돌 시 최대 3회 재시도
    ▼
CouponIssueTransactionalService (트랜잭션)
    │  ├─ 회원 검증
    │  ├─ 쿠폰 조회 (@Lock + @Version)
    │  ├─ 중복 발급 체크
    │  ├─ 재고 차감 (issuedQuantity++)
    │  └─ 발급 이력 저장
    ▼
DB 커밋 (version 검증)
    │
    ├─ 성공 → 응답 반환
    └─ 실패 (version 불일치) → OptimisticLockException → 재시도
```

### 적용 위치

| 위치 | 적용 내용 |
| :--- | :--- |
| `Coupon` | `@Version` 필드 추가 |
| `CouponRepository` | `@Lock(OPTIMISTIC)` 쿼리 |
| `CouponIssueService` | 재시도 로직 + 지수 백오프 |
| `CouponIssueTransactionalService` | 트랜잭션 분리 |

---

## 핵심 코드 설명

### Coupon 엔티티 - @Version
```java
@Entity
@Table(name = "coupons")
public class Coupon {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    ... 

    @Version
    private Long version;  // 낙관적 락 버전

    ...

    public void increaseIssuedQuantity() {
        if (!isIssuable()) {
            throw new IllegalStateException("쿠폰 발급이 불가능한 상태입니다.");
        }
        this.issuedQuantity++;
        this.updatedAt = LocalDateTime.now();
    }

    ... 
}
```

**`@Version`**
- JPA가 UPDATE 시 자동으로 `version = version + 1` 처리
- `WHERE id = ? AND version = ?` 조건이 추가됨
- **다른 트랜잭션이 먼저 커밋했으면 `WHERE` 조건 불일치 → 영향받은 row = 0 → 예외 발생** 

### CouponRepository.class - @Lock
```java
public interface CouponRepository extends JpaRepository<Coupon, Long> {

    @Lock(LockModeType.OPTIMISTIC)
    @Query("SELECT c FROM Coupon c WHERE c.couponCode = :couponCode")
    Optional<Coupon> findByCouponCodeWithLock(@Param("couponCode") String couponCode);

    ...
}
```

**`@Lock(LockModeType.OPTIMISTIC)`**
- 조회 시점에 `version`을 읽어온다.
- 엔티티 수정 후 `flush` 시점에 `version`을 비교한다.

### CouponIssueService - 재시도 로직
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
            } catch (ObjectOptimisticLockingFailureException e) {
                retryCount++;

                log.warn("낙관적 락 충돌 발생. 재시도 {}/{} - couponCode: {}, memberId: {}",
                        retryCount, MAX_RETRY_COUNT, couponCode, memberId);

                if (retryCount >= MAX_RETRY_COUNT) {
                    log.error("쿠폰 발급 재시도 횟수 초과 - couponCode: {}, memberId: {}", couponCode, memberId);
                    throw new BusinessException(ErrorCode.COUPON_ISSUE_FAILED);
                }

                // 지수 백오프: 20ms, 40ms, 80ms
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

**지수 백오프(Exponential Backoff):**

충돌 후 즉시 재시도하면 또 충돌할 확률이 높다. 대기 시간을 점점 늘려서 충돌 확률을 낮춘다.

| 재시도 | 대기 시간 | 계산 |
| :--- | :--- | :--- |
| **1회차** | `20ms` | `2^1 × 10` |
| **2회차** | `40ms` | `2^2 × 10` |
| **3회차** | `80ms` | `2^3 × 10` |

### 서비스 분리 - Self-Invocation 문제
처음에는 하나의 서비스에서 재시도 + 트랜잭션을 모두 구현하려 했다.

```java
// 처음 구현시 적용했던 코드
@Service
public class CouponIssueService {

    public CouponIssueResponse issueCoupon(...) {
        try {
            return this.doIssue(...);  // 같은 클래스 내부 호출
        } catch (OptimisticLockException e) {
            // 재시도
        }
    }

    @Transactional
    public CouponIssueResponse doIssue(...) {
        // 비즈니스 로직
    }
}
```

**문제**: `this.doIssue()` 호출이 프록시를 거치지 않아서 `@Transactional`이 동작하지 않았다.

**원인**: `Spring`의 `@Transactional`은 `AOP` 기반 프록시로 동작한다. **외부에서 호출해야 프록시가 끼어들 수 있는데, 같은 클래스 내부에서 호출하면 프록시를 우회한다.**

**해결**: 트랜잭션 로직을 별도 클래스 파일로 분리했다.

```java
// 서비스 분리
@Service
public class CouponIssueService {
    private final CouponIssueTransactionalService transactionalService;

    public CouponIssueResponse issueCoupon(...) {
        try {
            return transactionalService.issueCouponWithTransaction(...);  // 외부 호출
        } catch (OptimisticLockException e) {
            // 재시도
        }
    }
}
```

```java
@Service
public class CouponIssueTransactionalService {

    @Transactional
    public CouponIssueResponse issueCouponWithTransaction(...) {
        // 비즈니스 로직
    }
}
```

| 서비스 | 책임 | @Transactional |
| :--- | :--- | :--- |
| `CouponIssueService` | 재시도 로직, 예외 변환 | 없음 |
| `CouponIssueTransactionalService` | 비즈니스 로직, DB 작업 | 있음 |

### CouponIssueTransactionalService - 비즈니스 로직
```java
@Slf4j
@Service
@RequiredArgsConstructor
public class CouponIssueTransactionalService {

    private static final int COUPON_EXPIRE_DAYS = 30;

    private final CouponRepository couponRepository;
    private final CouponIssueRepository couponIssueRepository;
    private final MemberRepository memberRepository;

    @Transactional
    public CouponIssueResponse issueCouponWithTransaction(String couponCode, Long memberId) {
        // 1. 회원 검증
        Member member = memberRepository.findByIdAndStatus(memberId, MemberStatus.ACTIVE)
                .orElseThrow(() -> new BusinessException(ErrorCode.MEMBER_NOT_FOUND));

        // 2. 쿠폰 조회 (낙관적 락)
        Coupon coupon = couponRepository.findByCouponCodeWithLock(couponCode)
                .orElseThrow(() -> new BusinessException(ErrorCode.COUPON_NOT_FOUND));

        // 3. 중복 발급 체크
        validateDuplicateIssue(coupon.getId(), memberId);

        // 4. 발급 가능 여부 검증
        validateIssuable(coupon);

        // 5. 재고 차감 (version 증가)
        coupon.increaseIssuedQuantity();
        couponRepository.save(coupon);

        // 6. 발급 이력 저장
        CouponIssue couponIssue = CouponIssue.builder()
                .couponId(coupon.getId())
                .memberId(memberId)
                .expireDays(COUPON_EXPIRE_DAYS)
                .build();

        CouponIssue saveIssue = couponIssueRepository.save(couponIssue);

        log.info("쿠폰 발급 완료 - couponCode: {}, memberId: {}, issueId: {}",
                couponCode, memberId, saveIssue.getId());

        return CouponIssueResponse.from(
                saveIssue
                , coupon.getCouponCode()
                , coupon.getCouponName()
                , coupon.getDiscountAmount()
        );
    }
}
```

**처리 순서가 매우 중요하다.**
1. **회원 검증을 먼저** → 존재하지 않는 회원이면 불필요한 락 조회 방지
2. **쿠폰 조회 (낙관적 락)** → 여기서 `version`을 읽어옴
3. **중복 발급 체크** → `UK` 제약조건 전에 애플리케이션에서 먼저 체크
4. **재고 차감** → `version`이 증가됨
5. **트랜잭션 커밋 시 `version` 검증** → 충돌 시 예외 발생

## 부하 테스트 결과

### 테스트 환경

| 항목 | 값 |
|------|-----|
| **동시 사용자** | `500명` |
| **사용자당 요청** | `1회` |
| **쿠폰 재고** | `1,000개` |
| **DB** | `MySQL 8.0(InnoDB)` |
| **Connection Pool** | `HikariCP(max: 50)` |

### 테스트 결과
![](/assets/img/portfolio/lab/concurrency-control/concurrency-control-1/Portfolio-concurrency-control-1-1.png)*[k6 test]*

```
// 테스트 결과 요약
- 총 요청: 500
- 성공: 13 (2.6%)
- 실패: 487 (97.4%)
- 평균 응답시간: 9,040ms
- 최대 응답시간: 13,610ms
```

### 발견된 문제
**테스트 중 예상치 못한 에러가 발생했다.**
> 또한 쿠폰 재고 수 100개를 다 채우지도 못했다.

![](/assets/img/portfolio/lab/concurrency-control/concurrency-control-1/Portfolio-concurrency-control-1-2.png)*[Deadlock]*

```
com.mysql.cj.jdbc.exceptions.MySQLTransactionRollbackException:
Deadlock found when trying to get lock; try restarting transaction
```

🤔

## 문제 분석

### Deadlock 발생 원인
낙관적 락은 **애플리케이션 레벨**의 동시성 제어다. `@Version`은 `UPDATE` 시점에만 검증하고, 그 사이에 발생하는 **`DB` 레벨의 락 경합**은 방지하지 못한다.

### Unique Index + Insert/Update 충돌
`coupon_issues` 테이블에는 `UK(coupon_id, member_id)` 제약조건이 있다. 여러 트랜잭션이 동시에 `INSERT`와 `UPDATE`를 수행하면 락 획득 순서가 꼬이면서 데드락이 발생한다.

```
TX A: INSERT INTO coupon_issues (coupon_id=2, member_id=1) → 인덱스 락 획득
TX B: INSERT INTO coupon_issues (coupon_id=2, member_id=2) → 인덱스 락 획득
TX A: UPDATE coupon SET issued_quantity=99 WHERE id=2 → B의 락 대기
TX B: UPDATE coupon SET issued_quantity=99 WHERE id=2 → A의 락 대기
→ Deadlock!
```

핵심은 **`INSERT`와 `UPDATE`가 서로 다른 순서로 락을 잡는다**는 점이다. `INSERT`는 `coupon_issues` 테이블을, `UPDATE`는 `coupon` 테이블을 잠그는데, 500개 트랜잭션이 동시에 실행되면 이 순서가 뒤엉켜 교착 상태에 빠진다.

### 정리: 낙관적 락의 한계

| 기대 | 현실 |
| :--- | :--- |
| `version`만 검증하면 됨 | `DB` 레벨에서 다른 락이 발생 |
| 충돌 시 깔끔하게 재시도 | `Deadlock`으로 트랜잭션 롤백 |
| 높은 처리량 | 인덱스 락 경합으로 성능 저하 |

**결론:** 낙관적 락은 **`UPDATE` 충돌**만 감지한다. 같은 트랜잭션 내에서 발생하는 **`INSERT`의 락 경합**은 별개 문제다. 동시 트래픽이 높은 상황에서는 낙관적 락만으로 부족하다.

## 느낀점 및 다음 단계

### 이번 Phase 에서 배운 것

**JPA 낙관적 락**
- `@Version`은 `UPDATE` 시점에 버전을 비교해 충돌 감지
- `DB` 락을 사용하지 않아 동시 읽기는 허용하지만, `INSERT` 경합은 막지 못함

**Spring 트랜잭션**
- 같은 클래스 내 메서드 호출(`Self-Invocation`)은 프록시를 거치지 않아 트랜잭션 미적용
- 트랜잭션 경계를 명확히 하려면 서비스 분리 필요

**동시성 테스트의 중요성**
- 단위 테스트로는 발견할 수 없는 문제가 부하 테스트에서 드러남
- 낙관적 락 + `INSERT` 조합에서 예상치 못한 `Deadlock` 발생

### 다음 단계: Phase 2 - 비관적 락

낙관적 락의 한계를 확인했다. 다음에는 **비관적 락(`Pessimistic Lock`)**을 적용해본다.

**다룰 내용:**
- `@Lock(PESSIMISTIC_WRITE)` 적용
- `SELECT ... FOR UPDATE`의 동작 원리
- 낙관적 락과 성능 비교
- `Deadlock` 해결 여부 검증