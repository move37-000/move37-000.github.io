---
title: 동시성 제어 - 6. DLQ를 활용한 실패 메시지 관리
date: 2026-01-29
categories: [Spring, Project]
tags: [kafka, dlq, retry, spring-retry, dead-letter-queue]
image: 
---

## 동시성 제어 #6 - DLQ를 활용한 실패 메시지 관리

### 이전 Phase의 한계

`Phase 5`에서 `Lua Script`와 `Kafka` 안정성을 확보했지만, `Consumer` **실패 시 처리**가 부족했다.

```
1. Redis 재고 차감 성공 
2. Kafka 발행 성공 
3. Consumer DB 저장 실패 → 무한 재시도? 메시지 유실?

결과:
- Redis: 발급됨
- DB: 발급 안 됨
- 데이터 불일치!
```

`Consumer`가 계속 실패하면 어떻게 해야 할까?

## DLQ (Dead Letter Queue)

**'처리 실패한 메시지를 보관하는 별도의 큐'**다.

```
┌─────────────────┐     실패        ┌────────────────────┐
│  Main Topic     │ ──────────────► │  DLQ Topic         │
│  coupon-issued  │ (3회 재시도 후)  │  coupon-issued.DLQ │
└─────────────────┘                 └────────────────────┘
```

### 왜 필요한가?

| 방식 | 문제점 |
| :--- | :--- |
| **무한 재시도** | 장애 원인이 해결 안 되면 영원히 반복 |
| **메시지 버림** | 데이터 유실 |
| **DLQ** | 실패 메시지 보관 → 나중에 별도 처리 |

## 전체 아키텍처

```
┌─────────────────────────────────────────────────────────────────┐
│                     Main Consumer                               │
│                   (coupon-issued 토픽)                          │
│                                                                 │
│  실패 시 → 3회 재시도 (1초 → 2초 → 4초)                          │
│         → 실패 → coupon-issued.DLQ로 이동                       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     DLQ Consumer                                │
│                   (coupon-issued.DLQ 토픽)                      │
│                                                                 │
│  @Retryable (3회, 백오프 1초 → 2초 → 4초)                        │
│     └─ 성공 → 정상 처리 완료                                     │
│     └─ 실패 → @Recover로 이동                                   │
│                                                                 │
│  @Recover (최종 실패 처리)                                       │
│     ├─ Redis 롤백 (재고 복구 + 발급 명단 제거)                   │
│     └─ failed_coupon_issues 테이블에 저장                       │
└─────────────────────────────────────────────────────────────────┘
```

**총 6회 재시도** (`Main 3회 + DLQ 3회`) 후에도 실패하면 → 보상 트랜잭션 + 실패 기록 저장

## 구현

### DLQ 설정 (KafkaConfig)
```java
@Slf4j
@EnableKafka
@Configuration
public class KafkaConfig {

    ...

    // ==================== DLQ Producer ====================

    @Bean
    public ProducerFactory<String, Object> dlqProducerFactory() {
        Map<String, Object> props = new HashMap<>();
        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);

        Serializer<Object> valueSerializer = (topic, data) -> {
            try {
                return objectMapper.writeValueAsBytes(data);
            } catch (Exception e) {
                throw new RuntimeException("Serialization error", e);
            }
        };

        return new DefaultKafkaProducerFactory<>(
                props,
                new StringSerializer(),
                valueSerializer
        );
    }

    @Bean
    public KafkaTemplate<String, Object> dlqKafkaTemplate() {
        return new KafkaTemplate<>(dlqProducerFactory());
    }

    // ==================== DLQ Consumer ====================

    @Bean
    public ConsumerFactory<String, CouponIssuedEvent> dlqConsumerFactory() {
        Map<String, Object> props = new HashMap<>();
        props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ConsumerConfig.GROUP_ID_CONFIG, "coupon-dlq-service");  // 별도 그룹
        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");

        Deserializer<CouponIssuedEvent> valueDeserializer = (topic, data) -> {
            try {
                return objectMapper.readValue(data, CouponIssuedEvent.class);
            } catch (Exception e) {
                throw new RuntimeException("Deserialization error", e);
            }
        };

        return new DefaultKafkaConsumerFactory<>(
                props,
                new StringDeserializer(),
                valueDeserializer
        );
    }

    @Bean
    public ConcurrentKafkaListenerContainerFactory<String, CouponIssuedEvent> dlqKafkaListenerContainerFactory() {
        ConcurrentKafkaListenerContainerFactory<String, CouponIssuedEvent> factory =
                new ConcurrentKafkaListenerContainerFactory<>();
        factory.setConsumerFactory(dlqConsumerFactory());
        // ErrorHandler 없음! → DLQ Consumer 실패해도 또 다른 DLQ로 안 감
        return factory;
    }

    ...

}
```

**핵심 포인트:**
- **Main Consumer**: `ErrorHandler` 있음 → 실패 시 `DLQ`로 이동
- **DLQ Consumer**: `ErrorHandler` 없음 → 무한 `DLQ` 방지

### DLQ Consumer
```java
@Slf4j
@Service
@RequiredArgsConstructor
public class CouponIssueDlqConsumer {

    private final CouponIssueDlqProcessor processor;

    @KafkaListener(
            topics = "coupon-issued.DLQ"
            , groupId = "coupon-dlq-service"
            , containerFactory = "dlqKafkaListenerContainerFactory"
    )
    public void handleDlq(CouponIssuedEvent event) {
        processor.processIssue(event);
    }
}
```

`Consumer`는 단순히 **메시지 수신** → `Processor` **위임**만 한다.

### DLQ Processor (@Retryable 적용)
```java
@Slf4j
@Service
@RequiredArgsConstructor
public class CouponIssueDlqProcessor {

    private final CouponRepository couponRepository;
    private final CouponIssueRepository couponIssueRepository;
    private final FailedCouponIssueRepository failedCouponIssueRepository;
    private final CouponStockService stockService;

    private static final int COUPON_EXPIRE_DAYS = 30;

    @Retryable(
            retryFor = Exception.class
            , maxAttempts = 3
            , backoff = @Backoff(delay = 1000, multiplier = 2)
    )
    @Transactional
    public void processIssue(CouponIssuedEvent event) {
        Coupon coupon = couponRepository.findByCouponCode(event.getCouponCode())
                .orElseThrow(() -> new IllegalArgumentException(
                        "쿠폰을 찾을 수 없음: " + event.getCouponCode()));

        // 멱등성 체크
        if (couponIssueRepository.existsByCouponIdAndMemberId(
                coupon.getId(), event.getMemberId())) {
            log.info("이미 발급된 건, 스킵 - couponCode: {}, memberId: {}",
                    event.getCouponCode(), event.getMemberId());
            return;
        }

        // DB 저장
        CouponIssue couponIssue = CouponIssue.builder()
                .couponId(coupon.getId())
                .memberId(event.getMemberId())
                .expireDays(COUPON_EXPIRE_DAYS)
                .build();

        couponIssueRepository.save(couponIssue);
    }

    @Recover
    public void recover(Exception e, CouponIssuedEvent event) {
        log.error("[CRITICAL] DLQ 최종 실패 - couponCode: {}, memberId: {}, error: {}",
                event.getCouponCode(), event.getMemberId(), e.getMessage());

        // 1. Redis 롤백
        rollbackRedis(event);

        // 2. 실패 기록 저장
        saveFailedRecord(event, e);
    }

    private void rollbackRedis(CouponIssuedEvent event) {
        try {
            stockService.rollbackStock(event.getCouponCode(), event.getMemberId());
        } catch (Exception ex) {
            log.error("Redis 롤백 실패 - couponCode: {}, memberId: {}, error: {}",
                    event.getCouponCode(), event.getMemberId(), ex.getMessage());
        }
    }

    private void saveFailedRecord(CouponIssuedEvent event, Exception e) {
        try {
            FailedCouponIssue failedIssue = FailedCouponIssue.builder()
                    .couponCode(event.getCouponCode())
                    .memberId(event.getMemberId())
                    .reason("DLQ 최종 실패: " + e.getMessage())
                    .build();

            failedCouponIssueRepository.save(failedIssue);
        } catch (Exception ex) {
            log.error("실패 기록 저장 실패 - couponCode: {}, memberId: {}, error: {}",
                    event.getCouponCode(), event.getMemberId(), ex.getMessage());
        }
    }
}
```

> **트랜잭션 롤백 마킹** 방지 위하여 Processor 클래스 분리 후 @Retryable 적용

### @Retryable 활성화
```java
@EnableRetry  // 추가
@SpringBootApplication
public class HighTrafficLabApplication {
    public static void main(String[] args) {
        SpringApplication.run(HighTrafficLabApplication.class, args);
    }
}
```

### 실패 기록 Entity
```java
@Entity
@Table(
        name = "failed_coupon_issues"
        , indexes = {
            @Index(name = "idx_failed_status", columnList = "status")
            , @Index(name = "idx_failed_coupon_member", columnList = "coupon_code, member_id")
        }
)
@Getter
@NoArgsConstructor(access = AccessLevel.PROTECTED)
public class FailedCouponIssue {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "coupon_code", nullable = false, length = 50)
    private String couponCode;

    @Column(name = "member_id", nullable = false)
    private Long memberId;

    @Column(name = "failed_at", nullable = false)
    private LocalDateTime failedAt;

    @Column(name = "reason", nullable = false, length = 500)
    private String reason;

    @Enumerated(EnumType.STRING)
    @Column(name = "status", nullable = false, length = 20)
    private FailedStatus status;

    @Column(name = "resolved_at")
    private LocalDateTime resolvedAt;

    @Column(name = "resolved_by", length = 100)
    private String resolvedBy;

    @Builder
    public FailedCouponIssue(String couponCode, Long memberId, String reason) {
        this.couponCode = couponCode;
        this.memberId = memberId;
        this.failedAt = LocalDateTime.now();
        this.reason = reason;
        this.status = FailedStatus.PENDING;
    }
}
```

```java
public enum FailedStatus {
    PENDING         // 처리 대기
    , RESOLVED      // 수동 복구 완료
    , IGNORED       // 무시 처리 (중복 등)
}
```

## 테스트

### 강제 에러 코드 추가
```java
// Main Consumer에 추가
@KafkaListener(topics = "coupon-issued", groupId = "coupon-service")
@Transactional
public void handleCouponIssued(CouponIssuedEvent event) {
    // 테스트용: memberId 10 강제 에러
    if (event.getMemberId() == 10) {
        throw new RuntimeException("DLQ 테스트용 강제 에러!");
    }
    // ... 정상 로직
}
```

### 테스트 시나리오
1. `memberId = 10`로 쿠폰 발급 요청
2. `Main Consumer` → 3회 재시도 실패 → `DLQ` 이동
3. `DLQ Consumer` → 3회 재시도 → 성공 or `@Recover`

### 실행 결과
**Main Consumer 재시도, DLQ 등록*
![](/assets/img/portfolio/lab/concurrency-control/concurrency-control-6/Portfolio-concurrency-control-6-1.png)

- `memberId: 111` 저장 후 `memberId: 10` 이 강제 예외 처리로 재시도 로직 진입
- 재시도 4회 완료 후 `DLQ` 등록
- `DLQ` 메시지 수신부터 `Main Consumer`**와 다른 스레드로 동작 확인**

**DLQ 처리 시도**
![](/assets/img/portfolio/lab/concurrency-control/concurrency-control-6/Portfolio-concurrency-control-6-2.png)

- `DLQ Consumer`와 `Main Consumer`의 동시 동작 확인

**DLQ 최종 실패**
![](/assets/img/portfolio/lab/concurrency-control/concurrency-control-6/Portfolio-concurrency-control-6-3.png)

- `DLQ Consumer` 에서도 강제 예외 처리로 인하여 최종 실패 발생
- 최종 실패 후 `Redis` **재고 원복과 발급 이력 롤백**

**DLQ 최종 실패 이력 저장**
![](/assets/img/portfolio/lab/concurrency-control/concurrency-control-6/Portfolio-concurrency-control-6-4.png)
![](/assets/img/portfolio/lab/concurrency-control/concurrency-control-6/Portfolio-concurrency-control-6-5.png)

- `DLQ Consumer` 최종 실패 이력 저장

## 실행 흐름 정리
```
요청: memberId = 10

┌─────────────────────────────────────────────────────────────┐
│  Main Consumer                                              │
│  ─────────────────────────────────────────────────────────  │
│  1회 시도 → RuntimeException → 1초 대기                      │
│  2회 재시도 → RuntimeException → 2초 대기                    │
│  3회 재시도 → RuntimeException → DLQ로 이동                  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  DLQ Consumer → Processor                                   │
│  ─────────────────────────────────────────────────────────  │
│  1회 시도 → 성공 시 종료 / 실패 시 1초 대기                    │
│  2회 재시도 → 성공 시 종료 / 실패 시 2초 대기                  │
│  3회 재시도 → 성공 시 종료 / 실패 시 @Recover                  │
└─────────────────────────────────────────────────────────────┘
                              │
                         (최종 실패 시)
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  @Recover                                                   │
│  ─────────────────────────────────────────────────────────  │
│  1. Redis 롤백 (INCR + SREM)                                 │
│  2. failed_coupon_issues 테이블 저장                         │
│  3. [CRITICAL] 로그 출력                                     │
└─────────────────────────────────────────────────────────────┘
```

## 정리
이번 `Phase`에서 `DLQ` 기반 실패 처리 체계를 구축했다.

| 계층 | 구현 내용 | 역할 |
| :--- | :--- | :--- |
| `Main Consumer` | ErrorHandler + DLQ 라우팅 | **3회 재시도 후 DLQ 이동** |
| `DLQ Consumer` | @Retryable (3회) | **추가 재시도** |
| `@Recover` | 보상 트랜잭션 + 실패 저장 | **최종 실패 처리** |

### 달성한 것
- 무한 재시도 방지 (총 `6회`로 제한)
- 실패 메시지 보존 (`DLQ`)
- 보상 트랜잭션 (`Redis` 롤백)
- 실패 기록 관리 (`DB` 테이블)

### 아직 남은 것
- `Redis ↔ DB` 정합성 검증 (`Reconciliation Batch`)
- **비동기 전환**

다음 포스팅에서 `Reconciliation Batch`를 통한 정합성 검증을 다룬다.