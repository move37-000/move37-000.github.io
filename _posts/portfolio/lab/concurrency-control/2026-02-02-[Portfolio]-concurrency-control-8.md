---
title: 동시성 제어 - 8. Kafka 파티션 확장 - Consumer 병렬 처리
date: 2026-02-02
categories: [Spring, Project]
tags: [kafka, partition, consumer, concurrency]
image: 
---

## 동시성 제어 #8 - Kafka 파티션 확장

### 기존 구조의 한계

Phase 7까지 구현한 구조에서 Kafka는 **파티션 1개, Consumer 1개**로 동작했다.

```
Producer → Partition 0 → Consumer 1 → DB
              (1개)         (1개)
```

`100건`의 메시지가 들어오면 **1개의** `Consumer`**가 순차 처리**한다. 트래픽이 늘어나면 `Consumer`가 병목이 된다.

## 파티션 확장

### 목표
```
Producer → Partition 0 → Consumer 1 → DB
         → Partition 1 → Consumer 2 → DB
         → Partition 2 → Consumer 3 → DB
```

**3개의** `Consumer`**가 병렬 처리**하여 처리량을 늘린다.

| 항목 | Before | After |
| :--- | :--- | :--- |
| 파티션 수 | 1개 | 3개 |
| Consumer concurrency | 1 | 3 |
| 메시지 분산 방식 | - | `RoundRobin` |

## 구현

### KafkaConfig
```java
// 추가
// KafkaAdmin Bean
@Bean
public KafkaAdmin kafkaAdmin() {
    Map<String, Object> configs = new HashMap<>();
    configs.put(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
    return new KafkaAdmin(configs);
    
...

// 추가
// 자동 토픽 생성 비활성화
@Bean
public ConsumerFactory<String, CouponIssuedEvent> consumerFactory() {
    Map<String, Object> props = new HashMap<>();
    props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
    props.put(ConsumerConfig.GROUP_ID_CONFIG, "coupon-service");
    props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
    props.put(ConsumerConfig.ALLOW_AUTO_CREATE_TOPICS_CONFIG, false);  // 자동 생성 비활성화

... 

// 추가
// Consumer concurrency
@Bean
public ConcurrentKafkaListenerContainerFactory<String, CouponIssuedEvent> kafkaListenerContainerFactory(
        DefaultErrorHandler errorHandler) {
    ConcurrentKafkaListenerContainerFactory<String, CouponIssuedEvent> factory =
            new ConcurrentKafkaListenerContainerFactory<>();
    factory.setConsumerFactory(consumerFactory());
    factory.setCommonErrorHandler(errorHandler);
    factory.setConcurrency(3);  // Consumer 3개
    return factory;
}

... 

// 추가
// 토픽 생성 Bean
@Bean
public NewTopic couponIssuedTopic() {
return TopicBuilder.name("coupon-issued")
        .partitions(3)  // 파티션 3개
        .replicas(1)    // 로컬 환경
        .build();
```

`Partition` **수와** `Consumer` **수가 일치해야 노는** `Consumer` **가 없다.**

### 자동 생성 비활성화가 필요한 이유
`Consumer`가 먼저 연결하면 **파티션 1개로 토픽이 자동 생성**된다. `NewTopic Bean`보다 `Consumer` 연결이 먼저 발생하기 때문이다.

```
자동 생성 활성화:
Consumer 연결 → 토픽 자동 생성 (파티션 1개) → NewTopic Bean 무시

자동 생성 비활성화:
Consumer 연결 → 토픽 없음 → NewTopic Bean 실행 (파티션 3개) → Consumer 연결
```

### KafkaAdmin이 필요한 이유
```java
@Bean
public KafkaAdmin kafkaAdmin() { ... }
```

- **NewTopic Bean**: 토픽 설정만 정의
- **KafkaAdmin**: 실제로 Kafka 브로커에 토픽 생성 요청

`KafkaAdmin` 없이 `NewTopic`만 있으면 토픽이 생성되지 않는다.

> 자동차 몸체 없이 자동차 바퀴만 만드려고 하는 셈 이다.

## 파티션 할당 확인

애플리케이션 시작 시 로그:

```
partitions assigned: [coupon-issued-0]  // Consumer 1
partitions assigned: [coupon-issued-1]  // Consumer 2
partitions assigned: [coupon-issued-2]  // Consumer 3
```

![파티션 할당 로그](/assets/img/portfolio/lab/concurrency-control/concurrency-control-8/Portfolio-concurrency-control-8-1.png)

`3개`의 `Consumer`가 각각 다른 파티션을 담당한다.

## 부하 테스트

### 테스트 환경
```javascript
// k6 테스트 시나리오
// 로컬 PC 환경 한계로 1000명 피크까지만 테스트
export const options = {
    scenarios: {
        coupon_issue_scenario: {
            executor: 'ramping-vus',
            startVUs: 0,
            stages: [
                { duration: '2s', target: 500 },
                { duration: '3s', target: 1000 },   // 피크 1000명
                { duration: '5s', target: 200 },
                { duration: '2s', target: 0 },
            ],
        },
    },
};
```

### 테스트 결과가 동일
```
요청 → Redis Lua → Kafka 발행 (비동기) → 응답 반환
                         ↓
              Consumer가 DB 저장 (백그라운드)
```

사용자가 받는 응답은 `Redis` **처리 후 즉시 반환**된다. 파티션을 늘려도 `API` 응답 시간에는 영향이 없다.

`k6`로 측정하는 건 `요청 → 응답` 시간이기 때문에 **파티션 개수와 무관하게 결과가 동일**하다.

### 파티션 확장의 실제 효과

| 항목 | 효과 |
| :--- | :--- |
| API 응답 시간 | 변화 없음 |
| `Consumer` **처리량** | 증가 |
| `DB` **저장 속도** | 증가 |
| **백그라운드 병목** | 해소 |

파티션 확장은 `Consumer` **단의 병렬 처리**를 위한 것이다.

## Sticky Partitioner vs RoundRobin
테스트 중 메시지가 한 파티션에만 몰리는 현상이 발생했다.

```bash
$ kafka-run-class kafka.tools.GetOffsetShell --broker-list localhost:9092 --topic coupon-issued
coupon-issued:0:100 # 전부 파티션 0으로 몰림
coupon-issued:1:0
coupon-issued:2:0  
```

![Sticky Partitioner](/assets/img/portfolio/lab/concurrency-control/concurrency-control-8/Portfolio-concurrency-control-8-2.png)

### 원인: Sticky Partitioner (기본값)

`Kafka 2.4` 부터 기본 `Partitioner`가 `Sticky Partitioner`다.

```
Sticky Partitioner:
- 배치가 찰 때까지 같은 파티션으로 보냄
- 네트워크 효율 좋음
- 메시지가 적으면 한 파티션에 몰림
```

### KafkaConfig - RoundRobin 적용
```java
...

@Bean
    public ProducerFactory<String, CouponIssuedEvent> producerFactory() {
        Map<String, Object> props = new HashMap<>();
        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ProducerConfig.PARTITIONER_CLASS_CONFIG, "org.apache.kafka.clients.producer.RoundRobinPartitioner");

        ...
    }

...

```

`RoundRobin` 방식 적용 시 **메시지 순서 보장이 안 된다.**

> 하지만 `Redis` 에서 이미 순번을 처리하므로 상관없다.

![RoundRobin Partitioner](/assets/img/portfolio/lab/concurrency-control/concurrency-control-8/Portfolio-concurrency-control-8-3.png)

### Partitioner 비교

| Partitioner | 동작 방식 | 특징 |
| :--- | :--- | :--- |
| `Sticky` **(기본값)** | 배치가 찰 때까지 같은 파티션 | 성능 좋음, 분산 불균형 가능 |
| `RoundRobin` | 메시지마다 파티션 순환 | 균등 분산, 성능 약간 하락 |

> 파티션별로 균등하게 처리할 수 있지만 로컬 환경상 트래픽이 많지 않아 최종적으로 `Sticky` 를 적용했다.

## 파티션 수 결정 기준

| 환경 | 파티션 수 | 이유 |
| :--- | :--- | :--- |
| 로컬 | `3개` | `CPU` 코어 수 고려 |
| 스테이징 | `6 ~ 12개` | 성능 테스트 |
| 운영 | `12 ~ 50개+` | 실제 트래픽 대응 |

**파티션 수 ≥ Consumer 수**여야 모든 `Consumer`가 일을 할 수 있다.

## 실시간 리밸런싱(Real-time Rebalancing)
실제 운영 환경에서는 서비스 중단 없이 가용성을 유지해야 하므로, 현 방식처럼 서버를 내리고 토픽을 삭제하는 방식 대신 **실시간 리밸런싱**을 사용한다.

- **동작 원리**: 서비스 운영 중에 `Kafka CLI`로 파티션 수를 늘리면, `Kafka` 브로커가 이를 감지하고 현재 연결된 `Consumer`들에게 파티션 소유권을 즉시 재배분(`Rebalancing`) 한다.
- **장점**: 트래픽이 몰리는 상황에서도 서버 중단 없이 처리량을 유연하게 확장(`Scale-out`)할 수 있으며, `Kubernetes` 같은 환경에서 `Consumer Replica`를 늘리는 것만으로도 즉각적인 병렬 처리가 가능해진다.
- **고민할 점**: 리밸런싱이 일어나는 아주 짧은 순간 동안 `Consumer`의 읽기가 일시 정지(`Stop-the-world`)되거나 메시지가 중복 처리될 위험이 있다. 따라서 실무에서는 `DB` 멱등성 설계와 `Consumer Lag` 모니터링을 병행하여 정합성을 유지한다

> 이 프로젝트는 로컬 개발 환경에서 파티션 구조의 변화에 따른 동시성 제어 메커니즘을 명확히 확인하는 데 목적이 있으므로, 데이터 초기화 후 재구성하는 방식을 택했다.

### 로컬에서 사용한 토픽 삭제, 확인
```powershell
# 1. 기존 토픽 삭제 (데이터 초기화)
docker exec -it kafka kafka-topics --bootstrap-server localhost:9092 --delete --topic coupon-issued

# 2. 앱 재시작 후 테스트 진행 (KafkaConfig의 NewTopic 빈이 파티션 3개로 자동 생성)

# 3. 파티션별 오프셋(데이터 쌓인 양) 확인
docker exec -it kafka kafka-run-class kafka.tools.GetOffsetShell --broker-list localhost:9092 --topic coupon-issued
```

### 주의사항
- 파티션 수는 **늘릴 수 있지만 줄일 수는 없다**
- 줄이려면 토픽 삭제 후 재생성 필요
- `NewTopic Bean`은 **기존 토픽이 있으면 파티션을 늘려주지 않는다**

## 정리
이번 `Phase`에서 `Kafka` 파티션을 확장하여 `Consumer` 병렬 처리를 구현했다.

### 변경 사항

| 항목 | 내용 |
| :--- | :--- |
| 파티션 | `1개 → 3개` |
| Consumer | `1개 → 3개` |
| 토픽 생성 | `KafkaAdmin + NewTopic Bean` |

### 배운 점
- `NewTopic Bean`만으로는 부족하고 `KafkaAdmin`이 필요하다
- `Consumer` 자동 토픽 생성을 **비활성화**해야 원하는 파티션 수로 생성된다
- 파티션 확장은 `API` **응답이 아닌** `Consumer` **처리량**에 영향을 준다
- 파티션 수는 늘릴 수 있지만 **줄일 수는 없다** (삭제 후 재생성 필요)
- 기본 `Partitioner`는 `Sticky`라서 소량 메시지는 한 파티션에 몰릴 수 있다

### 최종 아키텍처
```
┌─────────────────────────────────────────────────────────────────┐
│  API Layer                                                      │
│  - 요청 → Redis Lua (원자적 처리) → 즉시 응답                     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ Kafka 비동기 발행
┌─────────────────────────────────────────────────────────────────┐
│  Kafka (파티션 3개)                                              │
│  - Sticky Partitioner (기본값)                                   │
│  - 대용량 트래픽에서 자연스럽게 분산                               │
└─────────────────────────────────────────────────────────────────┘
          │                   │                   │
          ▼                   ▼                   ▼
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ Consumer 1  │     │ Consumer 2  │     │ Consumer 3  │
│ Partition 0 │     │ Partition 1 │     │ Partition 2 │
└─────────────┘     └─────────────┘     └─────────────┘
          │                   │                   │
          └───────────────────┴───────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  DB Layer                                                       │
│  - 병렬로 INSERT 처리                                           │
│  - DLQ + @Retryable로 실패 복구                                 │
│  - Reconciliation Batch로 정합성 검증                           │
└─────────────────────────────────────────────────────────────────┘
```

다음 포스팅에서 그동안의 프로젝트 정리를 한다.