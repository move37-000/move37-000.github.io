---
title: 동시성 제어 - 4. Redis DECR + Kafka 비동기 처리
date: 2026-01-26 00:00:00 +09:00
categories: [Spring, Project]
tags: [spring-boot, redis, kafka, async, concurrency]
image: 
---

## 동시성 제어 #4 - Redis DECR + Kafka 비동기 처리

### 개념
`Redis DECR`은 **락 없이 원자적으로 재고를 차감**하는 방식이다. `Kafka`는 `DB` **저장을 비동기로 분리**해서 사용자 응답 속도를 극대화한다.

1. `Redis DECR`로 재고 차감 (원자적 연산)
2. 성공 시 `Kafka`로 이벤트 발행
3. 즉시 응답 반환 (`DB` 저장 안 기다림)
4. `Kafka Consumer`가 백그라운드에서 `DB` 저장

### Redis 분산 락과 비교

| 구분 | `Redis` 분산 락 | `Redis DECR` + `Kafka` |
| :--- | :--- | :--- |
| **재고 확인** | DB SELECT | **Redis GET** |
| **재고 차감** | DB UPDATE | **Redis DECR** |
| **처리 방식** | 순차 (한 명씩) | **동시 (원자적 연산)** |
| **DB 저장** | 동기 (응답 전) | **비동기 (응답 후)** |
| **응답 시점** | DB 저장 후 | **Redis 처리 후 즉시** |

### 왜 Redis DECR + Kafka 로 전환했나?
`Phase 3`에서 `Redis` 분산 락으로 `4.1초`까지 개선했지만, 근본적인 한계가 있었다. **락 기반은 '줄 세우기'**다. 한 번에 하나만 처리하니까 `500명`이 오면 `499명`은 대기해야 한다.

**선착순 쿠폰의 본질:**
```
필요한 건 "락"이 아니라 "재고 차감"
────────────────────────────────
락 방식  :  락 획득 → 재고 확인 → 차감 → 락 해제 (4단계)
DECR 방식: 재고 차감 (1단계, 결과로 성공/실패 판단)
```

`DECR`은 **읽기-수정-저장을 한 번에 처리**한다. 락으로 보호할 필요 없이, 명령어 자체가 원자적이다.

## DECR 이 왜 락 없이 동시성을 보장하나?

### Redis는 싱글 스레드
`Redis`는 명령어를 **한 번에 하나씩 순차 처리**한다. 동시에 `100개` 요청이 와도 내부적으로는 `1번`, `2번`, `3번`... 순서대로 실행된다.

```
초기 상태: coupon:stock:FLASH100 = 3 (재고 3개)

동시에 5명이 요청:
─────────────────────────────────────────
요청 A → DECR → 결과: 2 (성공 ✓)
요청 B → DECR → 결과: 1 (성공 ✓)
요청 C → DECR → 결과: 0 (성공 ✓)
요청 D → DECR → 결과: -1 (실패 ✗ → 복구)
요청 E → DECR → 결과: -2 (실패 ✗ → 복구)

※ 동시에 들어와도 Redis 내부에서 순차 처리됨
```

### 락 방식 vs DECR 방식
```
락 방식:
─────────────────────────────────────────
1. 값 읽기     ← 여기서 다른 요청이 끼어들면?
2. 값 수정
3. 값 저장     ← 덮어쓰기 문제 발생!

DECR 방식:
─────────────────────────────────────────
1. DECR       ← 읽기 + 수정 + 저장이 한 번에 끝남
              ← 끼어들 틈이 없음!
```

## Kafka는 왜 쓰나?

### 기존 구조 (동기)
```
요청 → Redis 락 → DB 조회 → 검증 → 재고 차감 → 이력 저장 → 응답
       └──────────────── 4초 ──────────────────┘
```
사용자는 **DB 작업이 다 끝날 때까지** 기다려야 한다.

### 변경 구조 (비동기)
```
요청 → Redis DECR → 즉시 응답 (수십 ms)
           │
           └─ 성공 시 Kafka 발행(MQ 등록)
                    │
                    ▼ (백그라운드)
              Consumer: DB 저장
```
사용자는 **Redis 판정만 끝나면 바로 응답** 받는다.

### 왜 빨라지나?

| 작업 | 소요 시간 | 동기 | 비동기 |
| :--- | :--- | :--- | :--- |
| Redis DECR | ~1ms | ✓ | ✓ |
| DB 조회/저장 | ~50ms | ✓ 대기 | 나중에 |
| **사용자 체감** | | **~50ms+** | **~수십ms** |

### Kafka = 메시지 큐(MQ)
```
kafkaTemplate.send()
    │
    ▼
┌─────────────────────────┐
│    Kafka (메시지 큐)      │
│                         │
│  [메시지 1] ← 쌓임         │
│  [메시지 2] ← 쌓임         │
│  [메시지 3] ← 쌓임         │
│                         │
└─────────────────────────┘
    │
    │ Consumer 가 하나씩 꺼내서 처리
    ▼
@KafkaListener
```
보내는 쪽은 **큐에 넣고 끝**. `Consumer`가 처리하든 말든 신경 안 쓴다.

## 구조

### 역할 분담
```
[Redis]
─────────
- 재고 숫자만 들고 있음: coupon:FLASH100:stock = 100
- DECR 로 차감, 결과 확인
- 0 이상 → 성공
- 음수 → 실패 (복구)

[Kafka Consumer]
─────────
- 쿠폰 발급 이력 INSERT
- 회원-쿠폰 매핑 저장
- 통계(발급 이력) 업데이트
```

### 전체 흐름
```
요청 500개
    │
    ▼
┌────────────────────────────────┐
│  Redis (재고 판정)               │
│  ─────────────────             │
│  • DECR 로 재고 차감 (원자적)       │
│  • Set 으로 중복 체크              │
│  • 성공/실패 즉시 판정              │
│                                │
│  → 100명 성공, 400명 즉시 실패 응답  │
└────────────────────────────────┘
    │
    │ 성공한 100명만
    ▼
┌─────────────────────────────────────┐
│  Kafka (후처리)                       │
│  ─────────────────                  │
│  • 메시지 큐에 쌓음                     │
│  • Consumer가 순차적으로 처리            │
│  • DB 저장 (발급 이력)                  │
│  • 실패 시 재시도                       │
└─────────────────────────────────────┘
```

## 구현 내용

### 변경 사항

| 위치 | 변경 내용 |
| :--- | :--- |
| `build.gradle` | `spring-kafka`, `jackson-datatype-jsr310` 의존성 추가 |
| `application.yml` | `Kafka` 설정 추가 |
| `docker-compose.yml` | `Zookeeper`, `Kafka` 컨테이너 추가 |
| `KafkaConfig` | `Producer`, `Consumer` 설정 |
| `CouponIssuedEvent` | `Kafka` 전송용 이벤트 객체 |
| `CouponStockService` | `Redis` 재고 관리 (DECR) |
| `CouponIssueService` | `Redis` 판정 + `Kafka` 발행 |
| `CouponIssueConsumer` | `Kafka Consumer` - DB 저장 |

### 삭제된 파일

| 파일 | 이유 |
| :--- | :--- |
| `RedissonConfig.java` | 분산 락 더 이상 안 씀 |
| `CouponIssueTransactionalService.java` | `Consumer`로 대체 |

---

## 핵심 코드 설명

### build.gradle - 의존성 추가
```gradle
implementation 'org.springframework.kafka:spring-kafka'
implementation 'com.fasterxml.jackson.datatype:jackson-datatype-jsr310'
```

### application.yml - Kafka 설정
```yaml
spring:
  kafka:
    bootstrap-servers: ${SPRING_KAFKA_BOOTSTRAP_SERVERS:localhost:9092}
    producer:
      key-serializer: org.apache.kafka.common.serialization.StringSerializer
      value-serializer: org.springframework.kafka.support.serializer.JsonSerializer
    consumer:
      group-id: coupon-service
      key-deserializer: org.apache.kafka.common.serialization.StringDeserializer
      value-deserializer: org.springframework.kafka.support.serializer.JsonDeserializer
      properties:
        spring.json.trusted.packages: "*"
      auto-offset-reset: earliest
```

### docker-compose.yml - Kafka 추가
```yaml
  zookeeper:
    image: confluentinc/cp-zookeeper:latest
    container_name: zookeeper
    environment:
      ZOOKEEPER_CLIENT_PORT: 2181
      ZOOKEEPER_TICK_TIME: 2000
    ports:
      - "2181:2181"
    networks:
      - backend-network

  kafka:
    image: confluentinc/cp-kafka:latest
    container_name: kafka
    depends_on:
      - zookeeper
    ports:
      - "9092:9092"
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka:9092
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT
      KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_AUTO_CREATE_TOPICS_ENABLE: "true"
    networks:
      - backend-network
```

> `Kafka`는 `Zookeeper`와 세트로 사용된다. `Zookeeper`가 `Kafka` 클러스터를 관리한다.

### CouponIssuedEvent - Kafka 전송용 이벤트
```java
@Getter
@NoArgsConstructor(access = AccessLevel.PROTECTED)
@AllArgsConstructor(access = AccessLevel.PRIVATE)
@Builder
public class CouponIssuedEvent {
    private String couponCode;
    private Long memberId;
    
    @JsonSerialize(using = LocalDateTimeSerializer.class)
    @JsonDeserialize(using = LocalDateTimeDeserializer.class)
    @JsonFormat(pattern = "yyyy-MM-dd'T'HH:mm:ss")
    private LocalDateTime requestedAt;
}
```

> `LocalDateTime`은 `Jackson`이 기본적으로 직렬화를 못 하기 때문에 어노테이션을 추가해야 한다.

### CouponStockService - Redis 재고 관리
```java
@Slf4j
@Service
@RequiredArgsConstructor
public class CouponStockService {

    private final StringRedisTemplate redisTemplate;

    private static final String STOCK_KEY_PREFIX = "coupon:stock:";
    private static final String ISSUED_SET_PREFIX = "coupon:issued:";

    /**
     * 재고 초기화
     * - 현재 프로젝트에서는 테스트용 API를 통해 수동 호출
     * - 프로덕션 환경에서는 관리자 페이지에서 이벤트 등록 시 호출하거나,
     *   스케줄러를 통해 이벤트 시작 전 자동 등록
     */
    public void initializeStock(String couponCode, int quantity) {
        String stockKey = STOCK_KEY_PREFIX + couponCode;
        redisTemplate.opsForValue().set(stockKey, String.valueOf(quantity));
        log.info("재고 초기화 - couponCode: {}, quantity: {}", couponCode, quantity);
    }

    /**
     * 재고 차감 시도
     * @return true: 성공, false: 실패 (재고 없음 또는 중복)
     */
    public boolean tryDecreaseStock(String couponCode, Long memberId) {
        String issuedKey = ISSUED_SET_PREFIX + couponCode;
        String stockKey = STOCK_KEY_PREFIX + couponCode;

        // 1. 중복 발급 체크 (Set에 이미 있으면 중복)
        Long added = redisTemplate.opsForSet().add(issuedKey, String.valueOf(memberId));
        if (added == null || added == 0) {
            log.info("중복 발급 시도 - couponCode: {}, memberId: {}", couponCode, memberId);
            return false;
        }

        // 2. 재고 차감
        Long remain = redisTemplate.opsForValue().decrement(stockKey);

        // 3. 재고 부족 시 롤백
        if (remain == null || remain < 0) {
            redisTemplate.opsForValue().increment(stockKey);
            redisTemplate.opsForSet().remove(issuedKey, String.valueOf(memberId));
            log.info("재고 소진 - couponCode: {}, memberId: {}", couponCode, memberId);
            return false;
        }

        log.info("재고 차감 성공 - couponCode: {}, memberId: {}, 남은 재고: {}",
                couponCode, memberId, remain);
        return true;
    }
}
```

### 코드 상세 설명

**1. 중복 발급 체크**
```java
Long added = redisTemplate.opsForSet().add(issuedKey, String.valueOf(memberId));
```
`Redis Set`에 `memberId`를 추가한다. **이미 존재하면** `0`**을 반환**한다.
- 반환값 `1` → 새로 추가됨 (처음 요청)
- 반환값 `0` → 이미 존재 (중복 요청)

`add()`가 **조회와 저장을 동시에 원자적으로 처리**한다.

**2. 재고 차감**
```java
Long remain = redisTemplate.opsForValue().decrement(stockKey);
```
`DECR` 명령어로 재고를 `1` 감소시킨다. **결과값(남은 재고)**을 반환한다.
- 결과 `>= 0` → 성공
- 결과 `< 0` → 재고 없음 (이미 소진된 상태에서 차감됨)

**3. 재고 부족 시 롤백**
```java
if (remain == null || remain < 0) {
    redisTemplate.opsForValue().increment(stockKey);  // 재고 복구
    redisTemplate.opsForSet().remove(issuedKey, String.valueOf(memberId));  // 명단 제거
    return false;
}
```
재고가 이미 `0`인 상태에서 `DECR`하면 `-1`이 된다. 이때:
- `increment()`로 재고 복구 (`-1` → `0`)
- `remove()`로 발급 명단에서 제거 (다음에 다시 시도 가능)

### CouponIssueService - Redis 판정 + Kafka 발행
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
        // 1. 회원 검증
        memberRepository.findByIdAndStatus(memberId, MemberStatus.ACTIVE)
                .orElseThrow(() -> new BusinessException(ErrorCode.MEMBER_NOT_FOUND));

        // 2. Redis에서 재고 차감 시도 (원자적 연산)
        boolean success = stockService.tryDecreaseStock(couponCode, memberId);

        if (!success) {
            throw new BusinessException(ErrorCode.COUPON_SOLD_OUT);
        }

        // 3. Kafka로 이벤트 발행 (DB 저장은 Consumer가 처리)
        CouponIssuedEvent event = CouponIssuedEvent.builder()
                .couponCode(couponCode)
                .memberId(memberId)
                .requestedAt(LocalDateTime.now())
                .build();

        kafkaTemplate.send(TOPIC, couponCode, event);

        log.info("쿠폰 발급 이벤트 발행 - couponCode: {}, memberId: {}", couponCode, memberId);

        // 4. 즉시 응답 (DB 저장 전)
        return CouponIssueResponse.issued(couponCode, memberId);
    }
}
```

### kafkaTemplate.send() 상세
```java
kafkaTemplate.send(TOPIC, couponCode, event);
//                  (1)      (2)       (3)
```

| 순서 | 값 | 역할 |
|:---|:---|:---|
| (1) TOPIC | `"coupon-issued"` | 어떤 채널로 보낼지 (업무 묶음) |
| (2) couponCode | `"FLASH100"` | 메시지 키 (같은 쿠폰은 같은 파티션) |
| (3) event | `CouponIssuedEvent` | 실제 전송 데이터 |

### CouponIssueConsumer - Kafka Consumer
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
        log.info("쿠폰 발급 이벤트 수신 - couponCode: {}, memberId: {}",
                event.getCouponCode(), event.getMemberId());

        try {
            // 1. 쿠폰 조회
            Coupon coupon = couponRepository.findByCouponCode(event.getCouponCode())
                    .orElseThrow(() -> new BusinessException(ErrorCode.COUPON_NOT_FOUND));

            // 2. 발급 이력 저장
            CouponIssue couponIssue = CouponIssue.builder()
                    .couponId(coupon.getId())
                    .memberId(event.getMemberId())
                    .expireDays(COUPON_EXPIRE_DAYS)
                    .build();

            couponIssueRepository.save(couponIssue);

            // 3. 쿠폰 발급 수량 증가 (통계용)
            coupon.increaseIssuedQuantity();
            couponRepository.save(coupon);

            log.info("쿠폰 발급 DB 저장 완료 - couponCode: {}, memberId: {}",
                    event.getCouponCode(), event.getMemberId());

        } catch (Exception e) {
            log.error("쿠폰 발급 처리 실패 - couponCode: {}, memberId: {}, error: {}",
                    event.getCouponCode(), event.getMemberId(), e.getMessage());
            throw e; // 재시도를 위해 예외 던짐
        }
    }
}
```

### @KafkaListener 동작 원리
```
[보내는 쪽 - CouponIssueService]
kafkaTemplate.send("coupon-issued", couponCode, event);
    │
    │ 메시지 발행
    ▼
┌─────────────────────────────────┐
│         Kafka 서버               │
│  "coupon-issued" 토픽에 쌓임     │
└─────────────────────────────────┘
    │
    │ 계속 감시 중
    ▼
[받는 쪽 - CouponIssueConsumer]
@KafkaListener(topics = "coupon-issued")
public void handleCouponIssued(CouponIssuedEvent event) {
    // 메시지 도착하면 자동 실행
}
```

`@KafkaListener`는 해당 토픽을 **계속 감시**하다가 메시지가 오면 **자동으로 메서드를 실행**한다.

## 부하 테스트 결과

### 테스트 환경

| 항목 | 값 |
|------|-----|
| **동시 사용자** | `500명` |
| **사용자당 요청** | `1회` |
| **쿠폰 수량** | `100개` |
| **DB** | `MySQL 8.0(InnoDB)` |
| **Redis** | `Redis 7.0` |
| **Kafka** | `Confluent Kafka` |

### 테스트 결과
```
// 테스트 결과 요약
- 총 요청: 500
- 성공: 100 (20%)
- 실패: 400 (80%)
- 평균 응답시간: 89.82ms
- 최대 응답시간: 166.68ms
- 총 소요시간: 0.6s
```

### 전체 비교: 낙관적 락 vs 비관적 락 vs Redis 락 vs Redis + Kafka

| 지표 | 낙관적 락 | 비관적 락 | Redis 락 | **Redis + Kafka** |
|:---|:---|:---|:---|:---|
| **성공률** | `2.6%(13)` | `20%(100)` | `20%(100)` | **`20%(100)`** |
| **발급된 쿠폰** | `13개` | `100개` | `100개` | **`100개`** |
| **평균 응답시간** | `9,040ms` | `7,310ms` | `4,160ms` | **`89.82ms`** |
| **최대 응답시간** | `13,610ms` | `9,590ms` | `7,040ms` | **`166.68ms`** |
| **총 소요시간** | `13.9s` | `10.3s` | `7.5s` | **`0.6s`** |

### 결과 분석
**Redis 락 대비 약 46배 성능 향상**
```
Redis 락:       평균 4,160ms
Redis + Kafka:  평균 89.82ms
```

**왜 빨라졌나?**
```
Redis 락 (동기):
요청 → Redis 락 → DB 저장 → 응답
                   ^^^^^^^
                   여기서 대기

Redis + Kafka (비동기):
요청 → Redis DECR → 응답 (즉시!)
           │
           └→ Kafka → DB 저장 (나중에)
```

## 정리: 락 방식별 비교

| 구분 | 낙관적 락 | 비관적 락 | Redis 분산 락 | Redis + Kafka |
| :--- | :--- | :--- | :--- | :--- |
| **정확성** | `Deadlock` 발생 | 정확함 | 정확함 | **정확함** |
| **성능** | `9초` | `7.3초` | `4.1초` | **`89ms`** |
| **DB 부하** | 중간 | 높음 | 낮음 | **매우 낮음** |
| **처리 방식** | 동기 | 동기 | 동기 | **비동기** |
| **적합 상황** | 충돌 적은 환경 | 단일 서버 | 대용량 트래픽 | **초대용량 트래픽** |

## 느낀점

### 이번 Phase에서 배운 것

**Redis DECR 원자적 연산**
- 락 없이도 동시성 보장 가능
- `DECR`은 읽기-수정-저장을 한 번에 처리
- `Redis Set`으로 중복 발급 방지

**Kafka 비동기 처리**
- 무거운 작업(DB 저장)을 응답에서 분리
- 메시지 큐에 쌓아두고 `Consumer`가 순차 처리
- 사용자 응답 속도 극대화

**실무 아키텍처**
- `Redis`(빠른 판정) + `Kafka`(후처리 분리) 조합이 대기업 표준
- 이벤트 드리븐 아키텍처의 기본 패턴

### 알게 된 한계점
`Redis`에서 발급 명단에 등록한 후 `Kafka` 발행 전에 서버가 죽으면, 해당 사용자는 발급 명단에만 등록되고 실제 쿠폰은 못 받는 상황이 발생할 수 있다. 실무에서는 `Lua` 스크립트로 원자적 처리하거나, 보상 트랜잭션으로 해결한다.