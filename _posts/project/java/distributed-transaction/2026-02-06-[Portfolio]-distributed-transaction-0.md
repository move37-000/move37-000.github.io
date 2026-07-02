---
title: 분산 트랜잭션 - 0. 프로젝트 설계
date: 2026-02-06
categories: [Spring, Project]
tags: [spring-boot, jpa, saga, outbox, distributed-transaction, project-setup]
image: 
---

## 분산 트랜잭션 #0 - 프로젝트 설계

### 동기
이전 프로젝트(선착순 쿠폰 발급 시스템)에서 **대규모 트래픽 환경에서의 동시성 제어**를 경험했다. `Redis Lua` 스크립트로 락 없는 동시성 제어를 구현하고, `Kafka` 비동기 처리로 성능을 개선했다.

하지만 그 프로젝트에서는 **외부 서비스 연동이 없었다.** 실제 서비스에서는 주문 → 재고 차감 → 결제 → 배송 요청처럼 **여러 서비스가 협력**하는 구조가 일반적이다. 이 과정에서 결제가 실패하면? 이미 차감한 재고는 어떻게 롤백하지?

이런 **분산 환경에서의 트랜잭션 정합성** 문제를 직접 경험하고 해결해보고 싶었다.

### 목표
**한정 수량 상품 주문 시스템**을 구현한다. 예를 들어 콜라보 이벤트 상품 판매 등 을 가정한다.

- **상품 재고는 100개이며, 101명에게 판매되면 안 된다.**
- **한 사람이 같은 상품을 중복 주문할 수 없다.**
- **결제 실패 시 재고가 정확히 롤백되어야 한다.**
- **일부 서비스 장애에도 데이터 정합성이 유지되어야 한다.**

### 이전 프로젝트와의 차이점

| 쿠폰 프로젝트 | 주문 프로젝트 |
| :--- | :--- | :--- |
| **핵심 문제** | 단일 리소스 동시성 | **분산 트랜잭션 정합성** |
| **외부 연동** | 없음 | **결제** `API (Mock)` |
| **실패 복구** | `DLQ + Batch` | `SAGA` **보상 트랜잭션** |
| **Outbox 패턴** | 불필요 | 필수 |
| **서비스 구조** | 단일 서비스 | **모놀리식** **→** `MSA` **전환** |

### 방향성
1. **모놀리식에서 시작해 점진적으로 분리**
   - `Phase 1 ~ 2`: 모놀리식으로 문제 상황 경험
   - `Phase 3 ~ 4`: 서비스 분리 + `Outbox/SAGA` 도입

2. **외부 서비스 실패 시뮬레이션**
   - `Mock` 결제 서버로 다양한 실패 상황 재현
   - 타임아웃, 부분 실패, 네트워크 오류 등

3. **운영 환경까지 고려**
   - 다중 `WAS + Nginx` 로드밸런싱
   - `Prometheus + Grafana` 모니터링
   - 클라우드 부하 테스트

## 학습 로드맵
프로젝트는 단계별로 진행하며, 각 단계마다 **문제를 직접 겪고 해결하는 방식**으로 진행한다.

```
Phase 0: 프로젝트 구성 및 설계 (현재 글)
    │
    ▼
Phase 1: 모놀리식 주문 시스템
    - 주문 → 재고 차감 → DB 저장
    - 단일 트랜잭션으로 처리
    - 1000명 동시 주문 테스트
    │
    ▼
Phase 2: 외부 결제 API 연동
    - Mock 결제 서버 구축
    - 결제 실패 시 문제 발생 확인
    - 트랜잭션 경계의 한계 체감
    │
    ▼
Phase 3: Transactional Outbox 패턴 도입
    - DB + 메시지 발행의 원자성 보장
    - Polling Publisher 구현
    │
    ▼
Phase 4: SAGA 패턴 (보상 트랜잭션)
    - Choreography 방식 구현
    - 결제 실패 → 재고 롤백 자동화
    │
    ▼
Phase 5: 다중 WAS + Nginx 로드밸런싱
    - 서버 2대 이상 구성
    - 세션 클러스터링 또는 Stateless 설계
    │
    ▼
Phase 6: Prometheus + Grafana 모니터링
    - 주문 처리량, 실패율, Consumer Lag 대시보드
    - 알림 설정
    │
    ▼
Phase 7: 클라우드 부하 테스트 + 장애 시뮬레이션
    - AWS/GCP 환경에서 대규모 트래픽 테스트
    - Chaos Engineering (서비스 강제 종료 등)
```

> 각 `Phase`를 완료할 때마다 블로그 글로 정리할 예정이다.

## 기술 스택

| 분류 | 기술 | 선택 이유 |
| :--- | :--- | :--- |
| **Language** | `Java 17` | `LTS` 버전, 이전 프로젝트와 일관성 |
| **Framework** | `Spring Boot 4.0` | 실무 표준, 자동 설정 편리 |
| **ORM** | `Spring Data JPA` | 트랜잭션 관리, 락 기능 내장 |
| **Database** | `MySQL 8.0` | `InnoDB` 트랜잭션, 이전 프로젝트와 일관성 |
| **Migration** | `Flyway` | 스키마 버전 관리 |
| **Connection Pool** | `HikariCP` | `Spring Boot` 기본, 고성능 |
| **Cache** | `Redis` | 재고 캐싱, 분산 락 (필요시) |
| **Message Queue** | `Kafka` | `Outbox` 이벤트 발행, `SAGA` 오케스트레이션 |
| **Load Balancer** | `Nginx` | 다중 `WAS` 로드밸런싱 |
| **Monitoring** | `Prometheus + Grafana` | 메트릭 수집 및 시각화 |
| **Load Testing** | `k6` | 부하 테스트 |
| **Container** | `Docker Compose` | 로컬 개발 환경 구성 |

## 프로젝트 구조

### 패키지 구조 (계층형 아키텍처)
`Phase 1 ~ 2`는 모놀리식으로 시작한다. `Phase 3` 이후 서비스 분리 시 패키지 구조가 변경될 수 있다.

```
src/main/java/com/portfolio/ordertransactionlab/
├── OrderTransactionLabApplication.java
│
├── presentation/                    # 표현 계층
│   ├── order/
│   │   ├── controller/
│   │   │   └── OrderController.java
│   │   └── request/
│   │       └── OrderRequest.java
│   ├── payment/
│   │   └── controller/
│   │       └── PaymentController.java
│   └── test/
│       └── TestDataResetController.java
│
├── application/                     # 응용 계층
│   ├── order/
│   │   ├── service/
│   │   │   └── OrderService.java
│   │   └── dto/
│   │       └── OrderResponse.java
│   ├── payment/
│   │   └── service/
│   │       └── PaymentService.java
│   └── stock/
│       └── service/
│           └── StockService.java
│
├── domain/                          # 도메인 계층
│   ├── order/
│   │   ├── entity/
│   │   │   ├── Order.java
│   │   │   └── OrderStatus.java
│   │   └── repository/
│   │       └── OrderRepository.java
│   ├── product/
│   │   ├── entity/
│   │   │   └── Product.java
│   │   └── repository/
│   │       └── ProductRepository.java
│   ├── stock/
│   │   ├── entity/
│   │   │   └── Stock.java
│   │   └── repository/
│   │       └── StockRepository.java
│   ├── payment/
│   │   ├── entity/
│   │   │   ├── Payment.java
│   │   │   └── PaymentStatus.java
│   │   └── repository/
│   │       └── PaymentRepository.java
│   └── member/
│       ├── entity/
│       │   └── Member.java
│       └── repository/
│           └── MemberRepository.java
│
├── infrastructure/                  # 인프라 계층
│   ├── config/
│   │   ├── JpaConfig.java
│   │   └── KafkaConfig.java
│   ├── exception/
│   │   └── GlobalExceptionHandler.java
│   ├── external/
│   │   └── payment/
│   │       └── MockPaymentClient.java
│   └── support/
│       └── DatabaseCleaner.java
│
└── common/                          # 공통 모듈
    ├── exception/
    │   ├── ErrorCode.java
    │   └── BusinessException.java
    └── response/
        └── ApiResponse.java
```

> 각 `Phase` 진행 시 마다 변경점 발생 가능 

### 계층별 역할

| 계층 | 패키지 | 역할 | 포함 요소 |
| :--- | :--- | :--- | :--- |
| **Presentation** | `presentation` | `HTTP` 요청/응답 처리 | `Controller, Request DTO` |
| **Application** | `application` | 비즈니스 로직 조율 | `Service, Response DTO` |
| **Domain** | `domain` | 핵심 비즈니스 규칙 | `Entity, Repository` |
| **Infrastructure** | `infrastructure` | 기술적 구현 | `Config, External Client` |
| **Common** | `common` | 공통 유틸리티 | `ErrorCode, ApiResponse` |

### 계층형 아키텍처 유지 이유
이전 프로젝트와 동일한 아키텍처를 사용해 **학습 곡선을 낮추고 일관성을 유지**한다. `Phase 3` 이후 서비스 분리 시에도 각 서비스 내부는 계층형 구조를 유지할 예정이다.

## DB 설계

### ERD
```
┌─────────────────┐       ┌─────────────────────┐
│     members     │       │      products       │
├─────────────────┤       ├─────────────────────┤
│ id (PK)         │       │ id (PK)             │
│ email (UK)      │       │ product_code (UK)   │
│ name            │       │ product_name        │
│ created_at      │       │ price               │
│ updated_at      │       │ created_at          │
└────────┬────────┘       │ updated_at          │
         │                └──────────┬──────────┘
         │                           │
         │                           │ 1:1
         │                           ▼
         │                ┌─────────────────────┐
         │                │       stocks        │
         │                ├─────────────────────┤
         │                │ id (PK)             │
         │                │ product_id (FK, UK) │
         │                │ total_quantity      │
         │                │ sold_quantity       │
         │                │ version             │ ← 낙관적 락
         │                │ created_at          │
         │                │ updated_at          │
         │                └──────────┬──────────┘
         │                           │
         │    ┌──────────────────────┘
         │    │
         ▼    ▼
┌─────────────────────────────────────┐
│              orders                 │
├─────────────────────────────────────┤
│ id (PK)                             │
│ order_code (UK)                     │
│ member_id (FK)                      │
│ product_id (FK)                     │
│ quantity                            │
│ total_price                         │
│ status                              │ ← PENDING, PAID, CANCELLED, FAILED
│ created_at                          │
│ updated_at                          │
├─────────────────────────────────────┤
│ UK(member_id, product_id)           │ ← 중복 주문 방지 (한정판의 경우)
└─────────────────────────────────────┘
         │
         │ 1:1
         ▼
┌─────────────────────────────────────┐
│             payments                │
├─────────────────────────────────────┤
│ id (PK)                             │
│ payment_code (UK)                   │
│ order_id (FK, UK)                   │
│ amount                              │
│ status                              │ ← PENDING, SUCCESS, FAILED, REFUNDED
│ pg_transaction_id                   │ ← 외부 PG 거래 ID
│ failed_reason                       │
│ paid_at                             │
│ created_at                          │
│ updated_at                          │
└─────────────────────────────────────┘
```

> `Phase 3`에서 `Outbox` 패턴 도입 시 `outbox_events` 테이블이 추가될 예정이다.

### 설계 포인트
1. **재고 분리**: `products`와 `stocks`를 분리해 재고 업데이트 시 상품 테이블 락 방지
2. **중복 주문 방지**: `UK(member_id, product_id)`로 `DB` 레벨에서 강제
3. **낙관적 락**: `stocks.version` 컬럼으로 동시 수정 충돌 감지
4. **주문 상태 관리**: `OrderStatus`로 주문 생명주기 추적
5. **결제 실패 추적**: `failed_reason`으로 실패 원인 기록

### 주문 상태 흐름
```
PENDING (주문 생성)
    │
    ├─── 결제 성공 ───→ PAID (결제 완료)
    │
    ├─── 결제 실패 ───→ FAILED (주문 실패) → 재고 롤백
    │
    └─── 사용자 취소 ──→ CANCELLED (주문 취소) → 재고 롤백
```

## API 설계

### 주문 생성 API
본 프로젝트의 핵심 기능으로, **분산 트랜잭션이 적용되는 지점이다.**
- **Endpoint**: `POST /api/v1/orders`
- **Payload**: `productCode, memberId, quantity`
- **Status Code**: 
  - `200 OK`: 주문 성공
  - `409 Conflict`: 재고 부족, 중복 주문
  - `500 Error`: 시스템 오류

### 결제 처리 API (Mock)
`Mock` 결제 서버에서 제공하는 `API`이다.
- **Endpoint**: `POST /api/v1/payments/process`
- **Payload**: `orderId, amount`
- **동작**: 설정에 따라 성공/실패/지연 응답

### 데이터 초기화 API
부하 테스트 전 데이터 초기화용이다.
- **Endpoint**: `POST /api/test/reset`
- **동작**: 
  1. FK Checks 일시 비활성화
  2. `orders`, `payments` 테이블 TRUNCATE
  3. `stocks` 테이블 재고 초기화
  4. 영속성 컨텍스트 초기화

## Mock 결제 서버 설계

### 목적
실제 결재 서비스 연동 없이 **다양한 결제 실패 상황을 시뮬레이션**한다.

### 실패 시나리오

| 시나리오 | 설정 방법 | 용도 |
| :--- | :--- | :--- |
| **랜덤 실패** | `70%` 성공, `30%` 실패 | 일반적인 실패 복구 테스트 |
| **타임아웃** | 응답 지연 `5초` | 타임아웃 핸들링 테스트 |
| **특정 금액 실패** | `10만원` 이상 무조건 실패 | 조건부 실패 테스트 |
| **연속 실패** | `N번째` 요청까지 실패 | 재시도 로직 테스트 |

### 구현 방식
```java
@RestController
public class MockPaymentController {
    
    @PostMapping("/api/v1/payments/process")
    public PaymentResponse process(@RequestBody PaymentRequest request) {
        // 설정에 따라 성공/실패 응답
        if (shouldFail(request)) {
            return PaymentResponse.fail("INSUFFICIENT_BALANCE");
        }
        return PaymentResponse.success(generateTransactionId());
    }
}
```

> `Mock` 서버는 별도 모듈 또는 별도 프로파일로 실행할 예정이다.

## 예외 처리 설계

### 전역 예외 처리
이전 프로젝트와 동일한 구조를 사용한다.

| 클래스 | 역할 |
| :--- | :--- |
| `ErrorCode.class` | 에러 코드 `ENUM` |
| `BusinessException.class` | `ErrorCode`를 담는 커스텀 예외 |
| `GlobalExceptionHandler.class` | `@ExceptionHandler`로 예외 타입별 처리 |
| `ApiResponse.class` | 일관된 응답 포맷 |

### 주문 관련 에러 코드

| ErrorCode | HTTP Status | 설명 |
| :--- | :--- | :--- |
| `PRODUCT_NOT_FOUND` | `404` | 상품 없음 |
| `STOCK_NOT_ENOUGH` | `409` | 재고 부족 |
| `ORDER_ALREADY_EXISTS` | `409` | 중복 주문 |
| `PAYMENT_FAILED` | `500` | 결제 실패 |
| `PAYMENT_TIMEOUT` | `504` | 결제 타임아웃 |

## 부하 테스트 환경
이전 프로젝트와 동일하게 `k6`를 사용한다.

| 설정 | 값 |
| :--- | :--- |
| **동시 사용자(VUs)** | `1,000명` |
| **사용자당 요청** | `1회` |
| **상품 재고** | `100개` |
| **제한 시간** | `30초` |

### 테스트 시나리오
1. **정상 주문 테스트**: `1,000명` 동시 주문 → `100명`만 성공해야 함
2. **결제 실패 테스트**: `30%` 결제 실패 설정 → 재고 롤백 확인
3. **타임아웃 테스트**: 결제 지연 시 주문 상태 확인

### 검증 항목
- 재고 정합성: `sold_quantity` == 실제 성공 주문 수
- 주문 상태 정합성: 결제 실패 주문은 `FAILED` 상태
- 중복 주문 방지: 같은 회원의 중복 주문 없음

## 환경 설정

| 파일 | 역할 |
| :--- | :--- |
| `application.yml` | 공통 설정 (`Flyway, JPA`) |
| `application-local.yml` | 로컬 환경 (`localhost DB, HikariCP`) |
| `application-mock.yml` | `Mock` 결제 서버 설정 |
| `application-prod.yml` | 운영 환경 (환경변수로 `credentials` 주입) |

> `Spring Profile`로 `local`, `mock`, `prod`를 분리해서 환경별 설정을 관리한다.

## What's Next

`Phase 1`: **모놀리식 주문 시스템**
- 주문 → 재고 차감 → 결제 → `DB` 저장을 단일 트랜잭션으로 구현
- `1,000명` 동시 주문 부하 테스트
- 단일 트랜잭션의 한계 확인 (결제 `API` 호출이 트랜잭션 안에 있을 때의 문제)