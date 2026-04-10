---
title: 동시성 제어 - 5. 데이터 정합성 강화 - Lua 스크립트 + Kafka 안정성
date: 2026-01-27
categories: [Spring, Project]
tags: [spring-boot, redis, kafka, async, concurrency]
image: 
---

## 동시성 제어 #5 - 데이터 정합성 강화: Lua 스크립트 + Kafka 안정성

### 이전 Phase의 문제점
`Phase 4` 에서 `Redis DECR + Kafka`로 성능을 개선했지만, 원자성 문제가 남아있었다.

```java
// 기존 코드 (CouponStockService)
Long added = redisTemplate.opsForSet().add(issuedKey, memberId);  // 1. 발급 명단 추가
Long remain = redisTemplate.opsForValue().decrement(stockKey);    // 2. 재고 차감
```

### 문제 시나리오
```
1. SADD(add) 성공 → memberId:123 발급 명단에 등록됨
2. 서버 장애 발생
3. DECR(decrement) 실행 안 됨 → 재고 안 줄어듦

결과:
- memberId 123: 발급 명단에 있음 (다시 요청해도 중복으로 거절)
- 재고: 100개 그대로 (차감 안 됨)
- 쿠폰: 실제로 못 받음
```

두 개의 `Redis` 명령어가 **별개로 실행**되기 때문에 중간에 장애가 발생하면 데이터 불일치가 생긴다.

## Lua Script

### Lua Script?
`Redis`에 내장된 `Lua` 인터프리터를 활용해 **여러 명령어를 하나의 원자적 연산**으로 실행하는 방법이다.

```
일반 명령어:
┌─────────┐     ┌─────────┐     ┌─────────┐
│  SADD   │ ──► │   GET   │ ──► │  DECR   │
└─────────┘     └─────────┘     └─────────┘
      ↑               ↑               ↑
      └───── 각각 별개 연산 (사이에 끼어들 수 있음)


Lua Script:
┌─────────────────────────────────────────┐
│  SADD → GET → DECR (하나의 원자적 연산)   │
└─────────────────────────────────────────┘
              (끼어들 수 없음)
```

### 왜 원자적인가?
`Redis`는 **싱글 스레드**로 명령을 처리한다. `Lua Script`는 **하나의 명령어처럼 취급되어 실행 중에 다른 명령이 끼어들 수 없다.**

## Lua Script 구현

### Lua Script 파일
**경로:** `src/main/resources/redis/scripts/decrease_stock.lua`

```lua
-- KEYS[1]: 재고 키 (coupon:stock:{couponCode})
-- KEYS[2]: 발급 명단 키 (coupon:issued:{couponCode})
-- ARGV[1]: 회원 ID
-- 반환값: -3 (중복), -1 (쿠폰 없음), -2 (재고 소진), 0 이상 (남은 재고)

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

-- 3. 재고 수량 검증
stock = tonumber(stock)
if stock <= 0 then
    redis.call('SREM', KEYS[2], ARGV[1])
    return -2
end

-- 4. 재고 차감
return redis.call('DECR', KEYS[1])
```

### RedisScriptConfig
```java
@Configuration
public class RedisScriptConfig {

    @Bean
    public RedisScript<Long> decreaseStockScript() {
        Resource script = new ClassPathResource("redis/scripts/decrease_stock.lua");
        return RedisScript.of(script, Long.class);
    }
}
```

### StockDecreaseResult
```java
public record StockDecreaseResult(Status status, long remainingStock) {

    public enum Status {
        SUCCESS, COUPON_NOT_FOUND, OUT_OF_STOCK, DUPLICATE
    }

    public static final StockDecreaseResult COUPON_NOT_FOUND =
            new StockDecreaseResult(Status.COUPON_NOT_FOUND, -1);

    public static final StockDecreaseResult OUT_OF_STOCK =
            new StockDecreaseResult(Status.OUT_OF_STOCK, -2);

    public static final StockDecreaseResult DUPLICATE =
            new StockDecreaseResult(Status.DUPLICATE, -3);

    public static StockDecreaseResult success(long remainingStock) {
        return new StockDecreaseResult(Status.SUCCESS, remainingStock);
    }

    public boolean isSuccess() {
        return status == Status.SUCCESS;
    }
}
```

> record 구현

### CouponStockService
```java
@Slf4j
@Service
@RequiredArgsConstructor
public class CouponStockService {

    private final StringRedisTemplate redisTemplate;
    private final RedisScript<Long> decreaseStockScript;

    private static final String STOCK_KEY_PREFIX = "coupon:stock:";
    private static final String ISSUED_SET_PREFIX = "coupon:issued:";

    ...

    public boolean tryDecreaseStock(String couponCode, Long memberId) {
        String stockKey = STOCK_KEY_PREFIX + couponCode;
        String issuedKey = ISSUED_SET_PREFIX + couponCode;

        // Lua Script
        Long result = redisTemplate.execute(
                decreaseStockScript,
                List.of(stockKey, issuedKey),
                String.valueOf(memberId)
        );

        StockDecreaseResult decreaseResult = mapResult(result);

        if (!decreaseResult.isSuccess()) {
            log.info("재고 차감 실패 - couponCode: {}, memberId: {}, status: {}",
                    couponCode, memberId, decreaseResult.status());
            return false;
        }

        log.info("재고 차감 성공 - couponCode: {}, memberId: {}, 남은 재고: {}",
                couponCode, memberId, decreaseResult.remainingStock());

        return true;
    }

    private StockDecreaseResult mapResult(Long result) {
        if (result == null || result == -1) {
            return StockDecreaseResult.COUPON_NOT_FOUND;
        }
        if (result == -2) {
            return StockDecreaseResult.OUT_OF_STOCK;
        }
        if (result == -3) {
            return StockDecreaseResult.DUPLICATE;
        }
        return StockDecreaseResult.success(result);
    }

    ...
}
```

## Kafka send 실패 처리
`Lua Script`로 `Redis` 원자성은 확보했지만, 그 다음 단계인 `Kafka` **발행이 실패**하면 어떻게 될까?

```
1. Lua 스크립트 성공 → Redis에 발급 처리됨
2. Kafka send 실패 (네트워크 오류 등)
3. Consumer가 메시지를 못 받음 → DB에 저장 안 됨

결과:
- Redis: 발급됨
- DB: 발급 안 됨
- 데이터 불일치 발생!
```

### Kafka 발행 실패 시 Redis 롤백
```java
@Slf4j
@Service
@RequiredArgsConstructor
public class CouponIssueService {

    private final CouponStockService stockService;
    private final MemberRepository memberRepository;
    private final KafkaTemplate<String, CouponIssuedEvent> kafkaTemplate;

    private static final String TOPIC = "coupon-issued";

    public CouponIssueResponse issueCoupon(String couponCode, Long memberId) {
        memberRepository.findByIdAndStatus(memberId, MemberStatus.ACTIVE)
                .orElseThrow(() -> new BusinessException(ErrorCode.MEMBER_NOT_FOUND));

        // Lua Script
        boolean success = stockService.tryDecreaseStock(couponCode, memberId);

        if (!success) throw new BusinessException(ErrorCode.COUPON_SOLD_OUT);

        try {
            CouponIssuedEvent event = CouponIssuedEvent.builder()
                    .couponCode(couponCode)
                    .memberId(memberId)
                    .requestedAt(LocalDateTime.now())
                    .build();

            kafkaTemplate.send(TOPIC, couponCode, event)
                    .get(5, TimeUnit.SECONDS);  // 5초 타임아웃
        } catch (Exception e) {
            try {
                // Kafka 실패 시 Redis 롤백
                log.error("Kafka 발행 실패, Redis 롤백 - couponCode: {}, memberId: {}", couponCode, memberId, e);
                stockService.rollbackStock(couponCode, memberId);
                throw new BusinessException(ErrorCode.COUPON_ISSUE_FAILED);
            } catch (Exception rollbackEx) {
                log.error("롤백도 실패! 수동 조치 필요 - couponCode: {}, memberId: {}",
                        couponCode, memberId, rollbackEx);
            }
            throw new BusinessException(ErrorCode.COUPON_ISSUE_FAILED);
        }

        return CouponIssueResponse.issued(couponCode, memberId);
    }
}
```

> `rollbackStock` 마저 실패하면 `Redis`와 `DB`의 **불일치가 확정된다.**

> 이를 대응하기 위해 `Reconciliation Batch` 로직이 **반드시 필요하다.**

### CouponStockService (Redis 롤백 추가)
```java
@Slf4j
@Service
@RequiredArgsConstructor
public class CouponStockService {

    ...

    public void rollbackStock(String couponCode, Long memberId) {
        String stockKey = STOCK_KEY_PREFIX + couponCode;
        String issuedKey = ISSUED_SET_PREFIX + couponCode;

        // 재고 복구
        redisTemplate.opsForValue().increment(stockKey);

        // 발급 명단에서 제거
        redisTemplate.opsForSet().remove(issuedKey, String.valueOf(memberId));
    }

    ...
}
```

### 핵심: 동기 방식으로 Kafka 발행 결과 확인

```java
// 비동기 (실패 감지 불가)
kafkaTemplate.send("coupon-issued", event);

// 동기 (실패 시 예외 발생)
kafkaTemplate.send("coupon-issued", event).get(5, TimeUnit.SECONDS);
```

`get()`을 호출하면 `Kafka broker`의 `ack`를 기다린다. **실패 시 예외가 발생하므로 롤백 처리가 가능하다.**

### 흐름도
```
┌─────────────────────────────────────────────────────────────┐
│                     쿠폰 발급 요청                              │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  1. Lua 스크립트 실행 (Redis)                                   │
│     - SADD (발급 명단 등록)                                     │
│     - 재고 검증                                                │
│     - DECR (재고 차감)                                         │
└─────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────┴─────────┐
                    │                   │
                   성공                 실패
                    │                   │
                    ▼                   ▼
┌──────────────────────────┐    ┌──────────────────────┐
│  2. Kafka 발행 시도         │   │  실패 응답 반환          │
│     .get(5, SECONDS)     │    │  (재고 소진/중복 등)     │
└──────────────────────────┘    └──────────────────────┘
                    │
           ┌────────┴────────┐
           │                 │
          성공               실패 
           │                 │
           ▼                 ▼
┌─────────────────┐  ┌─────────────────────────┐
│  성공 응답 반환     │ │  3. Redis 롤백            │
│                 │  │     - INCR (재고 복구)     │
│                 │  │     - SREM (명단 제거)     │
│                 │  │  4. 실패 응답 반환          │
└─────────────────┘  └─────────────────────────┘
```

> 이는 데이터 정합성을 증가시키지만, 트래픽이 많으면 `.get()`으로 인한 **50ms 대기**가 치명적이다.

## Consumer 멱등성 처리

`Kafka Consumer`가 같은 메시지를 **중복 처리**할 수 있는 상황이 있다.

### 중복 발생 시나리오
```
1. Consumer가 메시지 수신
2. DB INSERT 성공
3. offset commit 전에 Consumer 재시작
4. 같은 메시지 다시 수신
5. DB INSERT 또 시도 → 중복 발급!
```

### INSERT 전 존재 여부 확인
```java
@Slf4j
@Service
@RequiredArgsConstructor
public class CouponIssueConsumer {

    private final CouponRepository couponRepository;
    private final CouponIssueRepository couponIssueRepository;

    private static final int COUPON_EXPIRE_DAYS = 30;

    @KafkaListener(topics = "coupon-issued", groupId = "coupon-service")
    @Transactional
    public void handleCouponIssued(CouponIssuedEvent event) {
        // 멱등성 체크에 couponId 필요
        Coupon coupon = couponRepository.findByCouponCode(event.getCouponCode())
                .orElseThrow(() -> new BusinessException(ErrorCode.COUPON_NOT_FOUND));

        // 멱등성 체크
        if (couponIssueRepository.existsByCouponIdAndMemberId(coupon.getId(), event.getMemberId())) {
            log.info("이미 처리된 메시지, 스킵 - couponCode: {}, memberId: {}",
                    event.getCouponCode(), event.getMemberId());
            return;
        }

        ...

    }
}
```

> `Select-then-Insert` 사이의 찰나에 다른 컨슈머 쓰레드가 개입할 수 있는 `Race Condition`**이 존재한다.**

### Repository
```java
public interface CouponIssueRepository extends JpaRepository<CouponIssue, Long> {
    
    ...

    boolean existsByCouponCodeAndMemberId(Long couponCode, Long memberId);
}
```

### 왜 SELECT 후 INSERT인가?
```
방법 1: UNIQUE 제약조건만 의존
- INSERT 시도 → 중복이면 예외 발생 → 예외 처리
- 문제: 예외 발생 자체가 비용, 로그 오염

방법 2: SELECT 후 INSERT (현재 방식)
- 존재 확인 → 있으면 스킵, 없으면 INSERT
- 장점: 정상 흐름으로 처리, 명확한 의도

방법 3: UPSERT (INSERT ON DUPLICATE KEY UPDATE)
- MySQL 특화 문법
- 장점: 한 번의 쿼리로 처리
```

> 현재 프로젝트의 DB 가 MySQL 이지만 의도를 확고하게 하기 위해 방법 2 적용

`SELECT` 후 `INSERT` 방식은 **명시적이고 DB 독립적**이라는 장점이 있다. 하지만 `Race Condition` 을 대비하기 위해 `UNIQUE` 제약조건도 최후의 안전장치로 함께 설정한다.

```java
@Entity
@Table(
    name = "coupon_issues"
        , uniqueConstraints = {
                @UniqueConstraint(
                        name = "uk_coupon_member"
                        , columnNames = {"coupon_id", "member_id"}
                )
        }
    ...
)
public class CouponIssue {
    ...
}
```

## 전체 아키텍처
```
┌─────────────────────────────────────────────────────────────────────┐
│                            API Server                               │
│                                                                     │
│  ┌─────────────┐    ┌─────────────────┐    ┌──────────────────┐     │
│  │   Request   │───►│  Lua Script     │───►│  Kafka send()    │     │
│  │             │    │  (Redis 원자적)   │    │  .get() 동기      │     │
│  └─────────────┘    └─────────────────┘    └──────────────────┘     │
│                              │                      │               │
│                         실패 시 return             실패 시              │
│                                                     │               │
│                                              ┌──────▼──────┐        │
│                                              │ Redis 롤백   │        │
│                                              │ INCR + SREM │        │
│                                              └─────────────┘        │
└─────────────────────────────────────────────────────────────────────┘
                                                      │
                                                      │ 성공 시
                                                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          Kafka Broker                               │
│                       [coupon-issued topic]                         │
└─────────────────────────────────────────────────────────────────────┘
                                                      │
                                                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│                           Consumer                                  │
│                                                                     │
│  ┌───────────────────┐    ┌─────────────────┐    ┌──────────────┐   │
│  │  메시지 수신         │───►│  멱등성 체크       │───►│  DB INSERT   │   │
│  │                   │    │  (SELECT 존재)    │   │              │   │
│  └───────────────────┘    └─────────────────┘    └──────────────┘   │
│                                   │                                 │
│                              이미 존재 시                              │
│                                   │                                 │
│                                   ▼                                 │
│                           ┌─────────────┐                           │
│                           │    SKIP     │                           │
│                           └─────────────┘                           │
└─────────────────────────────────────────────────────────────────────┘
```

## 느낀점

### 이번 Phase에서 배운 것

이번 `Phase`에서 데이터 정합성을 위한 세 가지 안전장치를 구현했다.

| 계층 | 해결책 | 역할 |
| :--- | :--- | :--- |
| Redis | Lua 스크립트 | 재고 차감 + 중복 체크 원자적 처리 |
| Kafka 발행 | 동기 send + 롤백 | 발행 실패 시 Redis 상태 복구 |
| Kafka 소비 | 멱등성 체크 | 중복 메시지 안전하게 무시 |

이러한 안전장치를 통해

| 항목 | 기존 | 개선 후 |
| :--- | :--- | :--- |
| **Redis 원자성** | SADD, DECR 분리 | **Lua 스크립트로 원자적** |
| **Kafka 실패 처리** | 없음 (불일치 발생) | **롤백으로 일관성 유지** |
| **Consumer 중복** | 중복 INSERT 가능 | **멱등성 체크로 방지** |
| **장애 복구** | 수동 복구 필요 | **자동 롤백/스킵** |

**데이터 정합성을 개선시켰다.**

### 하지만?
`.get()`을 활용한 **동기 전송과 롤백은 데이터 정합성을 보장하는 확실한 방법이지만,** 선착순 이벤트와 같은 고트래픽 환경에서는 **'양날의 검'** 이다.
- 장점: `Kafka` 브로커에 메시지가 안전하게 안착되었음을 보장하며, **실패 시 즉각적인** `Redis` **롤백이 가능**
- 단점: 응답을 기다리는 동안 `WAS` **스레드가 차단(**`Blocking`**)**되어, **스레드 풀 고갈 발생 가능**

처음에는 `DB`와 메시지 큐의 원자성을 위해 `Transactional Outbox` 패턴도 고려했다. 하지만 `Redis`를 메인 저장소로 사용하는 현재 구조에서 `DB` 트랜잭션을 추가하는 것은 **성능상 이점이 크지 않다고 판단했다.**

선착순 시스템의 핵심은 **'빠른 응답과 가용성'**이다. 실시간성 정합성을 위해 사용자를 대기시키는 대신, **일단 빠르게 이벤트를 처리하고 사후에 데이터를 맞추는 전략**으로 선회하기로 했다.

> 추후 `Reconciliation Batch` 적용 시 `.get()` 삭제 예정

### 다음 단계: Phase 5 - 데이터 정합성 강화 - DLQ

**아직 남은 문제:**
- `Consumer` 재시도 실패 시 처리 (`DLQ`)
- `Redis ↔ DB` 정합성 검증 (`Reconciliation Batch`)

다음 포스팅에서 `DLQ(Dead Letter Queue)`를 통한 실패 메시지 관리를 다룬다.