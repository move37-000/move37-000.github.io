---
title: 동시성 제어 - 3. Redis 분산 락
date: 2026-01-21 00:00:00 +09:00
categories: [Spring, Project]
tags: [spring-boot, redis, redisson, distributed-lock, concurrency]
image: 
---

## 동시성 제어 #3 - Redis 분산 락

### 개념
`Redis` 분산 락은 `DB`**가 아닌** `Redis`**에서 락을 관리**하는 방식이다. `Redis`는 `In-Memory` 데이터 저장소로, 디스크 기반 `DB`보다 훨씬 빠르게 락을 획득/해제할 수 있다.

1. `Redis`에서 락 획득 시도 (`SET key value NX PX`)
2. 락 획득 성공 → `DB` 작업 수행
3. 락 획득 실패 → 대기 또는 실패 처리
4. 작업 완료 후 락 해제

### 비관적 락과 비교

| 구분 | 비관적 락 | `Redis` 분산 락 |
| :--- | :--- | :--- |
| **락 저장 위치** | `MySQL`(디스크) | `Redis`(메모리) |
| **락 확인 속도** | `~ms` | `~μs`(`1000배` 빠름) |
| **락 대기 중 자원** | `DB Connection` 점유 | **`Connection` 안 잡음** |
| **Connection Pool** | 빠르게 소진 | **여유 있음** |
| **적합 상황** | 단일 `DB` 환경 | **분산 환경, 대용량 트래픽** |

### 왜 Redis 분산 락으로 전환했나?
`Phase 2`에서 비관적 락의 한계를 확인했다. 정확성은 보장됐지만 **평균 응답시간이** `7.3초`로 프로덕션에서 사용하기 어려웠다. 원인은 **락 대기 중에도** `DB Connection`**을 점유**하기 때문이다. `Redis` 분산 락은 락 관리를 `Redis`로 분리해서 이 문제를 해결한다.

## 비관적 락의 문제점 상세 분석

### Connection Pool 동작 원리
`DB`에 연결하려면 `Connection`이 필요하다. 매번 연결을 새로 만들면 느리니까, **미리 일정 개수(기본 50개)를 만들어놓고 재사용한다.** 이게 `Connection Pool`이다.

### 500개 요청이 동시에 들어오면?
1. **메서드 진입:** 500개 요청 모두 `@Transactional` 메서드에 진입한다.
2. **Connection 획득 경쟁:** `@Transactional`이 시작되면 `Spring`이 `Connection Pool`에서 `Connection`을 요청한다.
```
요청 1 ~ 50   : Connection 획득  → 다음 코드 실행
요청 51 ~ 500 : Connection 없음  → HikariCP 대기열에서 대기 
```
3. **락 획득 경쟁:** `Connection`을 획득한 `50`개 요청 중에서 **락 경쟁이 발생한다.**
```
요청 1     : SELECT FOR UPDATE → 락 획득 
요청 2 ~ 50: SELECT FOR UPDATE → 락 대기(Connection 점유 중)
```

### 문제의 핵심
1. **요청 2 ~ 50 은 지금 뭐하고 있나?**
    - 아무것도 안 함
    - 그냥 락 풀리길 기다리는 중
    - **그런데** `Connection`**은 연결되어 있음**

2. **그동안 요청 51 ~ 500 은?**
    - `Connection`조차 못 잡고 밖에서 대기 중

**49개의** `Connection`**이 '아무것도 안 하면서' 자리만 차지하는 상황**이다.

### 500 번째 요청의 순서 
```
1단계: HikariCP 대기
요청 500: [HikariCP 대기~~~~~~~~~~~~~~~~~~~~~~~]
                                              ↑
                          450번째 요청이 Connection 반환하면 획득

2단계: 락 대기  
요청 500: [Conn 획득][락 대기~~~~~~~~~~~~~~~~~~]
                                              ↑
                          499번째 요청이 COMMIT하면 락 획득

3단계: 드디어 처리
요청 500: [처리][COMMIT]
```

`500`번째 요청은 **HikariCP 대기 + 락 대기**를 모두 겪어야 한다. 그래서 최대 응답시간이 `9.5초`였다.

## Redis는 왜 빠른가?

### In-Memory 저장소
`Redis`는 데이터를 디스크가 아닌 **메모리(**`RAM`**)**에 저장한다.

```
MySQL:  디스크에서 읽기/쓰기 → 느림 (ms 단위)
Redis:  메모리에서 읽기/쓰기 → 빠름 (μs 단위, 1000배 차이)
```

### 싱글 스레드 + 원자적 연산
`Redis`는 **싱글 스레드**로 동작한다. **모든 명령이 순차적으로 처리된다.**

```
요청 A: SET lock:coupon "A" NX  → 성공
요청 B: SET lock:coupon "B" NX  → 실패 (이미 있음)
요청 C: SET lock:coupon "C" NX  → 실패 (이미 있음)
```

**동시에 들어와도 하나씩 처리 → 락 충돌이 원천적으로 불가능하다.**

### 락 대기 중 Connection 미점유
**이게 가장 중요한 차이다.**

```
비관적 락:
─────────────────────────────────────────────
요청 1:  [Connection 잡음][락 잡음][처리 중...]
요청 2:  [Connection 잡음][락 대기~~~~~~~~][처리]
요청 3:  [Connection 잡음][락 대기~~~~~~~~~~~~][처리]
         ^^^^^^^^^^^^^^^^
         Connection 잡은 채로 대기 = 자원 낭비

Redis 락:
─────────────────────────────────────────────
요청 1:  [Redis 락 잡음][Connection 잡음][처리][반환]
요청 2:  [Redis 대기~~~][Redis 락 잡음][Connection 잡음][처리][반환]
요청 3:  [Redis 대기~~~~~~~~~][Redis 락 잡음][Connection 잡음][처리][반환]
         ^^^^^^^^^^^^^^^
         대기할 때 Connection 안 잡음 = 자원 절약
```

## 구현 내용

### 전체 흐름
```
클라이언트 요청
    │
    ▼
CouponIssueService
    │  ├─ 1. Redis 락 획득 시도 (tryLock)
    │  │      └─ 실패 시 최대 5초 대기
    │  │
    │  ├─ 2. 락 획득 성공
    │  │      └─ CouponIssueTransactionalService 호출
    │  │
    │  └─ 3. finally에서 락 해제
    ▼
CouponIssueTransactionalService (트랜잭션)
    │  ├─ 회원 검증
    │  ├─ 쿠폰 조회 (일반 SELECT, 락 없음)
    │  ├─ 중복 발급 체크
    │  ├─ 재고 차감
    │  └─ 발급 이력 저장
    ▼
응답 반환
```

### 변경 사항

| 위치 | 변경 내용 |
| :--- | :--- |
| `build.gradle` | `Redisson` 의존성 추가 |
| `RedissonConfig` | `RedissonClient` 빈 등록 |
| `CouponIssueTransactionalService` | `Redis` 분산 락 로직으로 교체(`findByCouponCode` 메소드 사용) |

---

## 핵심 코드 설명

### build.gradle - 의존성 추가
```gradle
implementation 'org.redisson:redisson:3.24.3'
```
> `Redisson starter` 가 `Spring Boot 4.0` 버전을 지원하지 않기 때문에 `Redisson` 코어만 사용

`Redisson`은 `Redis` 기반 분산 락을 쉽게 구현할 수 있게 해주는 라이브러리다.

### RedissonConfig - 설정 클래스
```java
@Configuration
public class RedissonConfig {

    @Value("${spring.data.redis.host}")
    private String host;

    @Value("${spring.data.redis.port}")
    private int port;

    @Bean
    public RedissonClient redissonClient() {
        Config config = new Config();
        config.useSingleServer()
              .setAddress("redis://" + host + ":" + port);
        return Redisson.create(config);
    }
}
```

`RedissonClient` 빈을 등록해서 애플리케이션 전체에서 사용할 수 있게 한다.

### CouponIssueService - Redis 분산 락 적용
```java
@Slf4j
@Service
@RequiredArgsConstructor
public class CouponIssueService {

    private final RedissonClient redissonClient;
    private final CouponIssueTransactionalService transactionalService;

    private static final String LOCK_PREFIX = "coupon:lock:";

    public CouponIssueResponse issueCoupon(String couponCode, Long memberId) {
        String lockKey = LOCK_PREFIX + couponCode;
        RLock lock = redissonClient.getLock(lockKey);

        try {
            boolean acquired = lock.tryLock(5, 3, TimeUnit.SECONDS);

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

### CouponIssueService - @Lock 어노테이션 미적용
```java
@Slf4j
@Service
@RequiredArgsConstructor
public class CouponIssueTransactionalService {
    
    ...

    @Transactional
    public CouponIssueResponse issueCouponWithTransaction(String couponCode, Long memberId) {
        ...
        // @Lock 어노테이션이 없는 로직 사용
        Coupon coupon = couponRepository.findByCouponCode(couponCode)
                .orElseThrow(() -> new BusinessException(ErrorCode.COUPON_NOT_FOUND));
        ...
    }   

    ...
}
```

### 코드 상세 설명
1. **락 키 생성**
```java
String lockKey = LOCK_PREFIX + couponCode;
// 예: "coupon:lock:FLASH100"
```
**쿠폰 코드별로 별도의 락을 생성한다. 다른 쿠폰끼리는 락 경합이 없다.**

2. **락 획득 시도**
```java
boolean acquired = lock.tryLock(5, 3, TimeUnit.SECONDS);
//                              │  │
//                              │  └─ leaseTime: 락 유지 시간(락 획득 후 3초 뒤 자동 해제)
//                              └─ waitTime: 락 대기 시간(락을 못 잡으면 최대 5초 까지 대기)
```

3. **락 해제**
```java
// 예외 발생해도 반드시 락 해제
finally {
    if (lock.isHeldByCurrentThread()) { // 본인이 잡은 락만 해제 가능
        lock.unlock();    
    }                     
}
```

### 만약 서버가 죽어서 unlock()을 못 호출하면?

| `leaseTime` 없음 | `leaseTime` 있음 |
| :--- | :--- |
| **락이 영원히 남음** | `3초` 후 자동 해제 |
| **데드락 발생** | 다른 요청이 진행 가능 |

이게 `Redis` 분산 락의 **안전장치**다.

### Redis 내부 동작
```
TX A: tryLock("coupon:lock:FLASH100")
      │
      ▼
Redis: SET coupon:lock:FLASH100 <thread-id> NX PX 3000
       │                                    │  │
       │                                    │  └─ 3000ms 후 만료
       │                                    └─ 키가 없을 때만 SET
       │
       └─ 성공 → 락 획득

TX B: tryLock("coupon:lock:FLASH100")
      │
      ▼
Redis: SET coupon:lock:FLASH100 ... NX ...
       │
       └─ 실패 (이미 키 존재) → 대기
```

**NX 옵션**이 핵심이다. 키가 없을 때만 SET → **원자적 연산으로 동시성을 보장한다.**

## 부하 테스트 결과

### 테스트 환경

| 항목 | 값 |
|------|-----|
| **동시 사용자** | `500명` |
| **사용자당 요청** | `1회` |
| **쿠폰 수량** | `100개` |
| **DB** | `MySQL 8.0(InnoDB)` |
| **Connection Pool** | `HikariCP(max: 50)` |
| **Redis** | `Redis 7.0` |

### 테스트 결과
![](/assets/img/2026-01-16/Portfolio-concurrency-control-3-1.png)*[k6 test]*

```
// 테스트 결과 요약
- 총 요청: 500
- 성공: 100 (20%)
- 실패: 400 (80%)
- 평균 응답시간: 2,280ms
- 최대 응답시간: 3,630ms
```

### 전체 비교: 낙관적 락 vs 비관적 락 vs Redis 락

| 지표 | 낙관적 락 | 비관적 락 | `Redis` 락 |
|:---|:---|:---|:---|
| **성공률** | `2.6%(13)` | `20%(100)` | `20%(100)` |
| **발급된 쿠폰** | `13개` | `100개` | `100개` |
| **평균 응답시간** | `9,040ms` | `7,310ms` | `2,280ms` |
| **최대 응답시간** | `13,610ms` | `9,590ms` | `3,630ms` |
| **총 소요시간** | `13.9s` | `10.3s` | `3.9s` |
| **Deadlock** | 발생 | 없음 | 없음 |

### 결과 분석
**비관적 락 대비 3배 성능 향상**
```
비관적 락: 총 10.3초, 평균 7.3초
Redis 락: 총 3.9초,  평균 2.3초
```

**왜 빨라졌나?**
```
비관적 락:
요청 → [DB Connection 획득] → [DB 락 대기] → [처리] → [락 해제]
       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       DB에서 모든 걸 처리 (병목)

Redis 락:
요청 → [Redis 락 대기] → [DB Connection] → [처리] → [락 해제]
       ^^^^^^^^^^^^^^^
       Redis가 락 관리 (빠름)
```

`DB Connection`을 잡고 대기하지 않으니 `Connection Pool` **고갈 문제가 해결**됐다.

## 정리: 락 방식별 비교

| 구분 | 낙관적 락 | 비관적 락 | Redis 분산 락 |
| :--- | :--- | :--- | :--- |
| **정확성** | `Deadlock` 발생 | 정확함 | **정확함** |
| **성능** | `9초` | `7.3초` | `2.3초` |
| **DB 부하** | 중간 | 높음 | **낮음** |
| **적합 상황** | 충돌 적은 환경 | 단일 서버 | **대용량 트래픽** |

## 느낀점 및 다음 단계

### 이번 Phase에서 배운 것
**Redis 분산 락**
- `Redisson`의 `tryLock(waitTime, leaseTime)`으로 간단하게 구현
- `NX` 옵션(`tryLock`)으로 원자적 락 획득 보장
- `leaseTime`으로 데드락 방지

**Connection Pool 과 락의 관계**
- 비관적 락은 락 대기 중에도 `Connection` 점유
- `Redis` 락은 락 획득 후에만 `Connection` 사용
- 이 차이가 `3배` 성능 향상의 핵심

**락 관리 위치의 중요성**
- `DB`에서 락 관리 → `DB` 병목
- `Redis`에서 락 관리 → `DB` 부하 분산

### 여전히 남은 문제
평균 `2.3초`는 많이 개선됐지만, 여전히 **동기 처리의 한계**가 있다. `500명`이 동시에 요청하면 순차적으로 처리해야 하니까 **뒤에 있는 요청은 대기할 수밖에 없다.**

### 다음 단계: Phase 4 - Kafka 비동기 처리
동기 처리의 한계를 확인했다. 다음에는 `Kafka`**를 이용한 비동기 처리**를 적용해본다.

**다룰 내용:**
- 요청 즉시 응답, 백그라운드에서 처리
- `Kafka Producer/Consumer` 구현
- 비동기 처리의 장단점
- 최종 성능 비교