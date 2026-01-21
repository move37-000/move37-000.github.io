---
title: 동시성 제어 - 3. Redis 분산 락
date: 2026-01-21 00:00:00 +09:00
categories: [Spring, Project]
tags: [spring-boot, redis, redisson, distributed-lock, concurrency]
image: 
published: false
---

## Watchdog을 이용한 락 자동 연장

### 기존 코드의 문제점
```java
lock.tryLock(5, 3, TimeUnit.SECONDS);
//              ↑
//          leaseTime = 3초
```

`leaseTime`을 3초로 설정하면, 처리가 3초 이상 걸릴 때 **락이 자동 해제**된다. Java는 이를 모른 채 처리를 계속하고, 다음 요청이 락을 획득해버린다.
```
요청 1: [락 획득][────── 처리 4초 걸림 ──────]
                              │
                        3초 경과, 락 해제됨 (모름)
                              │
요청 2:                   [락 획득][처리]

→ 두 요청이 동시에 DB 작업 💀
→ 재고 꼬임, 중복 발급 가능
```

### Watchdog이란?

Redisson이 제공하는 **락 자동 연장 기능**이다. `leaseTime`을 `-1`로 설정하면 활성화된다.
```java
lock.tryLock(5, -1, TimeUnit.SECONDS);
//              ↑
//          -1 = Watchdog 활성화
```

### Watchdog 동작 원리
```
기본 락 유지 시간: 30초
갱신 주기: 10초마다 (30초의 1/3)

시간 →

Java:      [락 획득][────────── 처리 중 ──────────][unlock]
                │         │         │
                0초      10초      20초
                │         │         │
                ▼         ▼         ▼
Watchdog:   [30초 설정] [30초 연장] [30초 연장]...
```

- 처리가 끝날 때까지 **자동으로 락 연장**
- `unlock()` 호출하면 즉시 해제
- 서버가 죽으면 Watchdog도 멈춤 → 30초 후 자동 해제

### 적용 코드
```java
@Slf4j
@Service
@RequiredArgsConstructor
public class CouponIssueService {

    private final RedissonClient redissonClient;
    private final CouponIssueTransactionalService transactionalService;

    private static final String LOCK_PREFIX = "coupon:lock:";
    private static final long WAIT_TIME = 5L;

    public CouponIssueResponse issueCoupon(String couponCode, Long memberId) {
        String lockKey = LOCK_PREFIX + couponCode;
        RLock lock = redissonClient.getLock(lockKey);

        try {
            // leaseTime = -1 → Watchdog 활성화
            boolean acquired = lock.tryLock(WAIT_TIME, -1, TimeUnit.SECONDS);

            if (!acquired) {
                log.warn("락 획득 실패 - couponCode: {}, memberId: {}", couponCode, memberId);
                throw new BusinessException(ErrorCode.COUPON_ISSUE_FAILED);
            }

            return transactionalService.issueCouponWithTransaction(couponCode, memberId);

        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new BusinessException(ErrorCode.COUPON_ISSUE_FAILED);
        } finally {
            if (lock.isHeldByCurrentThread()) {
                lock.unlock();
            }
        }
    }
}
```

### 기존 코드와 비교

| 항목 | 기존 (`leaseTime = 3`) | 변경 (`leaseTime = -1`) |
| :--- | :--- | :--- |
| 락 유지 시간 | 최대 3초 | **처리 끝날 때까지** |
| 처리 오래 걸리면 | 락 강제 해제 (위험) | **자동 연장 (안전)** |
| 서버 죽으면 | 3초 후 해제 | 30초 후 해제 |

### 실제 운영 환경에서의 권장 사항

**Watchdog 사용이 표준**이다. 처리 시간을 예측할 필요 없이, 작업이 끝날 때까지 락이 유지된다.