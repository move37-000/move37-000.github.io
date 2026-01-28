---
title: 동시성 제어 - 5. 데이터 정합성 강화 - Lua 스크립트
date: 2026-01-27
categories: [Spring, Project]
tags: [spring-boot, redis, kafka, async, concurrency]
image: 
---

# 동시성 제어 #5 - 데이터 정합성 강화: Lua 스크립트

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

## 3. 구현

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

**경로:** `src/main/java/.../infrastructure/config/RedisScriptConfig.java`

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

**경로:** `src/main/java/.../application/coupon/dto/StockDecreaseResult.java`

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

### 3.4 CouponStockService (수정)

```java
@Slf4j
@Service
@RequiredArgsConstructor
public class CouponStockService {

    private final StringRedisTemplate redisTemplate;
    private final RedisScript<Long> decreaseStockScript;

    private static final String STOCK_KEY_PREFIX = "coupon:stock:";
    private static final String ISSUED_SET_PREFIX = "coupon:issued:";

    public boolean tryDecreaseStock(String couponCode, Long memberId) {
        String stockKey = STOCK_KEY_PREFIX + couponCode;
        String issuedKey = ISSUED_SET_PREFIX + couponCode;

        // Lua 스크립트 실행 (원자적)
        Long result = redisTemplate.execute(
                decreaseStockScript,
                List.of(stockKey, issuedKey),
                String.valueOf(memberId)
        );

        StockDecreaseResult decreaseResult = mapResult(result);

        if (!decreaseResult.isSuccess()) {
            log.info("재고 차감 실패 - couponCode: {}, memberId: {}, status: {}",
                    couponCode, memberId, decreaseResult.getStatus());
            return false;
        }

        log.info("재고 차감 성공 - couponCode: {}, memberId: {}, 남은 재고: {}",
                couponCode, memberId, decreaseResult.getRemainingStock());
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

    // 기존 메서드들...
}
```

---

## 4. 기존 방식 vs Lua 스크립트

| 항목 | 기존 (DECR + 롤백) | Lua 스크립트 |
|------|-------------------|--------------|
| 원자성 | 단일 연산만 원자적 | 전체 로직 원자적 |
| 음수 재고 | 발생 가능 (롤백 필요) | 발생 불가 |
| 서버 장애 시 | 데이터 불일치 가능 | All or Nothing |
| 롤백 로직 | Java에서 수동 처리 | Lua 내부에서 처리 |
| 코드 복잡도 | 높음 | 낮음 |

---

## 5. 실행 흐름

```
┌─────────────────────────────────────────────────────────────┐
│ Spring                                                      │
│                                                             │
│  redisTemplate.execute(                                     │
│      decreaseStockScript,         ← Lua 스크립트            │
│      List.of(stockKey, issuedKey), ← KEYS[1], KEYS[2]       │
│      String.valueOf(memberId)      ← ARGV[1]                │
│  )                                                          │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ Redis (Lua 스크립트 실행 - 원자적)                           │
│                                                             │
│  1. SADD coupon:issued:FLASH100 "123"                       │
│     └─ 0이면 return -3 (중복)                               │
│                                                             │
│  2. GET coupon:stock:FLASH100                               │
│     └─ nil이면 SREM + return -1 (쿠폰 없음)                 │
│                                                             │
│  3. 재고 검증                                               │
│     └─ 0 이하면 SREM + return -2 (재고 소진)                │
│                                                             │
│  4. DECR coupon:stock:FLASH100                              │
│     └─ 남은 재고 반환                                       │
└─────────────────────────────────────────────────────────────┘
```

---

## 6. 핵심 포인트

### 왜 SADD를 먼저 하는가?

"먼저 자리 잡고, 문제 있으면 빼기" 전략이다.

```lua
-- ✅ 현재 방식: SADD 먼저
SADD → GET → 검증 → DECR
       └─ 실패 시 SREM (롤백)

-- ❌ 반대 방식: 검증 먼저
GET → 검증 → SADD → DECR
             └─ 검증과 SADD 사이에 갭 존재
```

재고 확인 후 SADD 하는 방식은 검증과 쓰기 사이에 논리적 갭이 생긴다. SADD를 먼저 하면 자리를 확보한 상태에서 검증하므로 더 안전하다.

### 실무에서의 Lua 스크립트

| 회사/서비스 | 용도 |
|-------------|------|
| 쿠팡, 배민 | 선착순 이벤트, 재고 차감 |
| 토스, 카카오페이 | 한도 체크, 잔액 차감 |
| 네이버, 카카오 | Rate Limiting (API 호출 제한) |

---

## 7. 정리

Lua 스크립트를 적용해서 Redis 연산의 원자성을 확보했다.

**해결된 문제:**
- 중복 체크 + 재고 차감이 원자적으로 실행
- 서버 장애 시에도 데이터 불일치 없음

**아직 남은 문제:**
- Kafka send 실패 시 처리
- Consumer 중복 처리 (멱등성)
- Consumer 실패 시 무한 재시도 (DLQ)

다음 섹션에서 Kafka 관련 문제들을 해결한다.

---

👉 다음: Kafka send 실패 처리