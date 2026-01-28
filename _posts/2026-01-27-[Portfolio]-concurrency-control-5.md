---
title: 동시성 제어 - 5. 데이터 정합성 강화 - Lua 스크립트 + Kafka 안정성
date: 2026-01-27
categories: [Spring, Project]
tags: [spring-boot, redis, kafka, async, concurrency]
image: 
---

# 동시성 제어 #5 - 데이터 정합성 강화: Lua 스크립트 + Kafka 안정성

## 1. 이전 Phase의 문제점

Phase 4에서 Redis DECR + Kafka로 성능을 개선했지만, 원자성 문제가 남아있었다.

```java
// 기존 코드 (CouponStockService)
Long added = redisTemplate.opsForSet().add(issuedKey, memberId);  // 1. 발급 명단 추가
Long remain = redisTemplate.opsForValue().decrement(stockKey);    // 2. 재고 차감
```

### 문제 시나리오

```
1. SADD 성공 → "123" 발급 명단에 등록됨
2. ⚡ 서버 장애 발생
3. DECR 실행 안 됨 → 재고 안 줄어듦

결과:
- 회원 123: 발급 명단에 있음 (다시 요청해도 "중복"으로 거절)
- 재고: 100개 그대로 (차감 안 됨)
- 쿠폰: 실제로 못 받음
```

두 개의 Redis 명령어가 **별개로 실행**되기 때문에 중간에 장애가 발생하면 데이터 불일치가 생긴다.

---

## 2. 해결책: Lua 스크립트

### Lua 스크립트란?

Redis에 내장된 Lua 인터프리터를 활용해 **여러 명령어를 하나의 원자적 연산**으로 실행하는 방법이다.

```
일반 명령어:
┌─────────┐     ┌─────────┐     ┌─────────┐
│  SADD   │ ──► │   GET   │ ──► │  DECR   │
└─────────┘     └─────────┘     └─────────┘
      ↑               ↑               ↑
      └───── 각각 별개 연산 (사이에 끼어들 수 있음)


Lua 스크립트:
┌─────────────────────────────────────────┐
│  SADD → GET → DECR (하나의 원자적 연산)  │
└─────────────────────────────────────────┘
              (끼어들 수 없음)
```

### 왜 원자적인가?

Redis는 **싱글 스레드**로 명령을 처리한다. Lua 스크립트는 하나의 명령어처럼 취급되어 실행 중에 다른 명령이 끼어들 수 없다.

---

## 3. Lua 스크립트 구현

### 3.1 Lua 스크립트 파일

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

### 3.2 RedisScriptConfig

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

### 3.3 StockDecreaseResult

```java
@Getter
public class StockDecreaseResult {

    public enum Status {
        SUCCESS,
        COUPON_NOT_FOUND,
        OUT_OF_STOCK,
        DUPLICATE
    }

    private final Status status;
    private final long remainingStock;

    private StockDecreaseResult(Status status, long remainingStock) {
        this.status = status;
        this.remainingStock = remainingStock;
    }

    public static final StockDecreaseResult COUPON_NOT_FOUND =
            new StockDecreaseResult(Status.COUPON_NOT_FOUND, -1);

    public static final StockDecreaseResult OUT_OF_STOCK =
            new StockDecreaseResult(Status.OUT_OF_STOCK, 0);

    public static final StockDecreaseResult DUPLICATE =
            new StockDecreaseResult(Status.DUPLICATE, -1);

    public static StockDecreaseResult success(long remainingStock) {
        return new StockDecreaseResult(Status.SUCCESS, remainingStock);
    }

    public boolean isSuccess() {
        return status == Status.SUCCESS;
    }
}
```

### 3.4 CouponStockService

```java
@Slf4j
@Service
@RequiredArgsConstructor
public class CouponStockService {

    private final StringRedisTemplate redisTemplate;
    private final RedisScript<Long> decreaseStockScript;

    private static final String STOCK_KEY_PREFIX = "coupon:stock:";
    private static final String ISSUED_SET_PREFIX = "coupon:issued:";

    public StockDecreaseResult decreaseStock(String couponCode, Long memberId) {
        String stockKey = STOCK_KEY_PREFIX + couponCode;
        String issuedKey = ISSUED_SET_PREFIX + couponCode;

        Long result = redisTemplate.execute(
                decreaseStockScript,
                List.of(stockKey, issuedKey),
                String.valueOf(memberId)
        );

        return mapResult(result);
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

    /**
     * Kafka 발행 실패 시 롤백
     */
    public void rollbackStock(String couponCode, Long memberId) {
        String stockKey = STOCK_KEY_PREFIX + couponCode;
        String issuedKey = ISSUED_SET_PREFIX + couponCode;

        redisTemplate.opsForValue().increment(stockKey);
        redisTemplate.opsForSet().remove(issuedKey, String.valueOf(memberId));

        log.info("Redis 롤백 완료 - couponCode: {}, memberId: {}", couponCode, memberId);
    }
}
```

---

## 4. Kafka send 실패 처리

Lua 스크립트로 Redis 원자성은 확보했지만, 그 다음 단계인 **Kafka 발행이 실패**하면 어떻게 될까?

```
1. Lua 스크립트 성공 → Redis에 발급 처리됨
2. ⚡ Kafka send 실패 (네트워크 오류 등)
3. Consumer가 메시지를 못 받음 → DB에 저장 안 됨

결과:
- Redis: 발급됨 ✅
- DB: 발급 안 됨 ❌
- 데이터 불일치 발생!
```

### 해결: Kafka 발행 실패 시 Redis 롤백

```java
@Slf4j
@Service
@RequiredArgsConstructor
public class CouponIssueService {

    private final CouponStockService stockService;
    private final KafkaTemplate<String, CouponIssuedEvent> kafkaTemplate;

    public CouponIssueResponse issueCoupon(String couponCode, Long memberId) {
        // 1. Redis 재고 차감 (Lua 스크립트)
        StockDecreaseResult result = stockService.decreaseStock(couponCode, memberId);

        if (!result.isSuccess()) {
            return CouponIssueResponse.fail(result.getStatus());
        }

        // 2. Kafka 발행
        try {
            CouponIssuedEvent event = new CouponIssuedEvent(couponCode, memberId);
            kafkaTemplate.send("coupon-issued", event).get(5, TimeUnit.SECONDS);
            
            log.info("쿠폰 발급 이벤트 발행 성공 - couponCode: {}, memberId: {}", 
                    couponCode, memberId);
            return CouponIssueResponse.success(result.getRemainingStock());

        } catch (Exception e) {
            // 3. Kafka 실패 시 Redis 롤백
            log.error("Kafka 발행 실패, Redis 롤백 - couponCode: {}, memberId: {}", 
                    couponCode, memberId, e);
            stockService.rollbackStock(couponCode, memberId);
            
            return CouponIssueResponse.fail("일시적인 오류가 발생했습니다. 다시 시도해주세요.");
        }
    }
}
```

### 핵심: 동기 방식으로 Kafka 발행 결과 확인

```java
// ❌ 비동기 (실패 감지 불가)
kafkaTemplate.send("coupon-issued", event);

// ✅ 동기 (실패 시 예외 발생)
kafkaTemplate.send("coupon-issued", event).get(5, TimeUnit.SECONDS);
```

`get()`을 호출하면 Kafka broker의 ack를 기다린다. 실패 시 예외가 발생하므로 롤백 처리가 가능하다.

### 흐름도

```
┌─────────────────────────────────────────────────────────────┐
│                     쿠폰 발급 요청                           │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  1. Lua 스크립트 실행 (Redis)                                │
│     - SADD (발급 명단 등록)                                  │
│     - 재고 검증                                             │
│     - DECR (재고 차감)                                      │
└─────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────┴─────────┐
                    │                   │
                 성공 ✅              실패 ❌
                    │                   │
                    ▼                   ▼
┌──────────────────────────┐    ┌──────────────────────┐
│  2. Kafka 발행 시도       │    │  실패 응답 반환       │
│     .get(5, SECONDS)     │    │  (재고 소진/중복 등)  │
└──────────────────────────┘    └──────────────────────┘
                    │
          ┌────────┴────────┐
          │                 │
       성공 ✅            실패 ❌
          │                 │
          ▼                 ▼
┌─────────────────┐  ┌─────────────────────────┐
│  성공 응답 반환  │  │  3. Redis 롤백           │
│                 │  │     - INCR (재고 복구)   │
│                 │  │     - SREM (명단 제거)   │
│                 │  │  4. 실패 응답 반환       │
└─────────────────┘  └─────────────────────────┘
```

---

## 5. Consumer 멱등성 처리

Kafka Consumer가 같은 메시지를 **중복 처리**할 수 있는 상황이 있다.

### 중복 발생 시나리오

```
1. Consumer가 메시지 수신
2. DB INSERT 성공
3. ⚡ offset commit 전에 Consumer 재시작
4. 같은 메시지 다시 수신
5. DB INSERT 또 시도 → 중복 발급!
```

### 해결: INSERT 전 존재 여부 확인

```java
@Slf4j
@Service
@RequiredArgsConstructor
public class CouponIssueConsumer {

    private final CouponIssueRepository couponIssueRepository;

    @KafkaListener(topics = "coupon-issued", groupId = "coupon-consumer")
    public void consume(CouponIssuedEvent event) {
        String couponCode = event.getCouponCode();
        Long memberId = event.getMemberId();

        // 멱등성 체크: 이미 발급된 건인지 확인
        if (couponIssueRepository.existsByCouponCodeAndMemberId(couponCode, memberId)) {
            log.info("이미 처리된 발급 건 (멱등성) - couponCode: {}, memberId: {}", 
                    couponCode, memberId);
            return;
        }

        // DB 저장
        CouponIssue couponIssue = CouponIssue.builder()
                .couponCode(couponCode)
                .memberId(memberId)
                .issuedAt(LocalDateTime.now())
                .build();

        couponIssueRepository.save(couponIssue);
        log.info("쿠폰 발급 완료 - couponCode: {}, memberId: {}", couponCode, memberId);
    }
}
```

### Repository

```java
public interface CouponIssueRepository extends JpaRepository<CouponIssue, Long> {
    
    boolean existsByCouponCodeAndMemberId(String couponCode, Long memberId);
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

SELECT 후 INSERT 방식은 **명시적이고 DB 독립적**이라는 장점이 있다. 물론 UNIQUE 제약조건도 최후의 안전장치로 함께 설정한다.

```java
@Entity
@Table(
    uniqueConstraints = @UniqueConstraint(
        columnNames = {"coupon_code", "member_id"}
    )
)
public class CouponIssue {
    // ...
}
```

---

## 6. 전체 아키텍처

```
┌─────────────────────────────────────────────────────────────────────┐
│                            API Server                               │
│                                                                     │
│  ┌─────────────┐    ┌─────────────────┐    ┌──────────────────┐    │
│  │   Request   │───►│  Lua Script     │───►│  Kafka send()    │    │
│  │             │    │  (Redis 원자적) │    │  .get() 동기     │    │
│  └─────────────┘    └─────────────────┘    └──────────────────┘    │
│                              │                      │               │
│                         실패 시 return         실패 시              │
│                                                     │               │
│                                              ┌──────▼──────┐        │
│                                              │ Redis 롤백  │        │
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
│  ┌───────────────────┐    ┌─────────────────┐    ┌──────────────┐  │
│  │  메시지 수신       │───►│  멱등성 체크     │───►│  DB INSERT   │  │
│  │                   │    │  (SELECT 존재)  │    │              │  │
│  └───────────────────┘    └─────────────────┘    └──────────────┘  │
│                                   │                                 │
│                              이미 존재 시                           │
│                                   │                                 │
│                                   ▼                                 │
│                           ┌─────────────┐                          │
│                           │    SKIP     │                          │
│                           └─────────────┘                          │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 7. 기존 방식 vs 개선된 방식

| 항목 | 기존 | 개선 후 |
|------|------|--------|
| Redis 원자성 | ❌ SADD, DECR 분리 | ✅ Lua 스크립트로 원자적 |
| Kafka 실패 처리 | ❌ 없음 (불일치 발생) | ✅ 롤백으로 일관성 유지 |
| Consumer 중복 | ❌ 중복 INSERT 가능 | ✅ 멱등성 체크로 방지 |
| 장애 복구 | ❌ 수동 복구 필요 | ✅ 자동 롤백/스킵 |

---

## 8. 정리

이번 Phase에서 데이터 정합성을 위한 세 가지 안전장치를 구현했다.

| 계층 | 해결책 | 역할 |
|------|--------|------|
| Redis | Lua 스크립트 | 재고 차감 + 중복 체크 원자적 처리 |
| Kafka 발행 | 동기 send + 롤백 | 발행 실패 시 Redis 상태 복구 |
| Kafka 소비 | 멱등성 체크 | 중복 메시지 안전하게 무시 |

**아직 남은 문제:**
- Consumer 재시도 실패 시 처리 (DLQ)
- Redis ↔ DB 정합성 검증 (Reconciliation)

다음 포스팅에서 DLQ(Dead Letter Queue)를 통한 실패 메시지 관리를 다룬다.

---

👉 다음: [동시성 제어 #6] DLQ를 활용한 실패 메시지 관리