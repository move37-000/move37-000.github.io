---
title: 동시성 제어 - 0. 프로젝트 설계
date: 2026-01-13 00:00:00 +09:00
categories: [Spring, Project]
tags: [spring-boot, jpa, architecture, project-setup]
image: 
---

## 동시성 제어 #0 - 프로젝트 설계

### 동기
공공기관 보안 내부망 업무 특성상 대용량 트래픽 처리를 하지 않는다.(**애초에 트래픽이 적다...**) 하지만 다른 기업들은 대용량 트래픽 처리가 일상이다. 쿠폰 선착순 발급, 티켓 예매, 한정판 구매 등.. 어떻게 구현하고 어떻게 동작하는지 매번 궁금했다. 나도 저런 문제를 **직접 경험하고 해결**해보고 싶었다.

### 목표
최근 쿠팡에서 이벤트로 진행한 **선착순 쿠폰** 을 경험해보고, 그것을 목표로 삼았다.

- **쿠폰 제한 수량은 100개 이며, 101명 에게 발급되면 안 된다. (추후 수치 조절)**
- **한 사람이 같은 쿠폰을 두 번 받을 수 없다.**
- **요청이 몰려도 시스템이 죽으면 안 된다.**

### 방향성
1. **동시성 제어 기법 직접 구현 및 비교**
   - 낙관적 락, 비관적 락, 분산 락 등을 단계별로 적용
   - 각 방식의 장단점을 실제 테스트로 체감

2. **실무에서 쓰이는 기술 스택 학습**
   - `JPA` 
   - `Spring Transactional` 관리
   - 전역 예외 처리
   - 계층형 아키텍처
> 대부분 처음 사용한다...

3. **포트폴리오용 문서화**
   - 단순 구현이 아닌, 왜 이렇게 했는지 과정을 기록
   - 문제 발생 → 원인 분석 → 해결 과정 정리

## 학습 로드맵 
프로젝트는 단계별로 진행할 예정이며 각 단계마다 하나의 동시성 제어 기법을 적용하고, **부하 테스트를 통해 문제점을 발견하고 개선해 나간다.**
```
Phase 0: 프로젝트 구성 및 설계 (현재 글)
    │
    ▼
Phase 1: 낙관적 락 (Optimistic Lock)
    - JPA @Version 활용
    - 재시도 로직 구현
    - 500명 동시 요청 테스트
    │
    ▼
Phase 2: 비관적 락 (Pessimistic Lock)
    - SELECT FOR UPDATE
    - 낙관적 락과 성능 비교
    │
    ▼
Phase 3: Redis 분산 락
    - Redisson 활용
    - DB 락에서 벗어나기
    │
    ▼
Phase 4: Redis + Kafka` 비동기 처리
    - 대규모 트래픽 대응
    - 최종 아키텍처
```
> 각 `Phase`를 완료할 때마다 블로그 글로 정리할 예정이다.

## 기술 스택

| 분류 | 기술 | 선택 이유 |
| :--- | :--- | :--- |
| **Language** | `Java 17` | `LTS` 버전 |
| **Framework** | `Spring Boot 4.0` | 실무 표준, 자동 설정 편리 |
| **ORM** | `Spring Data JPA` | 처음 배우는 `ORM`, 락 기능 내장 |
| **Database** | `MySQL 8.0` | `InnoDB`의 락 메커니즘 학습 |
| **Migration** | `Flyway` | 스키마 버전 관리 |
| **Connection Pool** | `HikariCP` | `Spring Boot` 기본, 고성능 |
| **Cache** | `Redis` | 분산 락, 캐싱 |
| **Message Queue** | `Kafka` | 비동기 처리 |

## 프로젝트 구조

### 패키지 구조 (계층형 아키텍처)
```
src/main/java/com/portfolio/hightrafficlab/
├── HighTrafficLabApplication.java
│
├── presentation/                    # 표현 계층
│   ├── coupon/
│   │   ├── controller/
│   │   │   └── CouponIssueController.java
│   │   └── request/
│   │       └── CouponIssueRequest.java
│   └── dataReset/
│       └── DatabaseCleanerController.java
│
├── application/                     # 응용 계층
│   └── coupon/
│       ├── service/
│       │   ├── CouponIssueService.java
│       │   └── CouponIssueTransactionalService.java
│       └── dto/
│           └── CouponIssueResponse.java
│
├── domain/                          # 도메인 계층
│   ├── coupon/
│   │   ├── entity/
│   │   │   ├── Coupon.java
│   │   │   ├── CouponIssue.java
│   │   │   ├── CouponStatus.java
│   │   │   └── IssueStatus.java
│   │   └── repository/
│   │       ├── CouponRepository.java
│   │       └── CouponIssueRepository.java
│   └── member/
│       ├── entity/
│       │   ├── Member.java
│       │   └── MemberStatus.java
│       └── repository/
│           └── MemberRepository.java
│
├── infrastructure/                  # 인프라 계층
│   ├── config/
│   │   └── JpaConfig.java
│   ├── exception/
│   │   └── GlobalExceptionHandler.java
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

### 계층별 역할

| 계층 | 패키지 | 역할 | 포함 요소 |
| :--- | :--- | :--- | :--- |
| **Presentation** | `presentation` | `HTTP` 요청/응답 처리 | `Controller, Request DTO` |
| **Application** | `application `| 비즈니스 로직 조율 | `Service, Response DTO` |
| **Domain** | `domain` | 핵심 비즈니스 규칙 | `Entity, Repository` |
| **Infrastructure** | `infrastructure` | 기술적 구현 | `Config, Exception Handler` |
| **Common** | `common` | 공통 유틸리티 | `ErrorCode, ApiResponse` |        

### 계층형 아키텍처 선택 이유
`JPA`를 처음 사용하기에 복잡한 아키텍처(헥사고날 등)보다는 **직관적이고 널리 쓰이는 계층형**을 선택했다.

**장점**:
- 각 계층의 책임이 명확함
- 코드 위치를 예측하기 쉬움

**단점**:
- 계층 간 의존성이 강함
- 도메인 로직이 서비스에 흩어질 수 있음

> **도메인 엔티티에 비즈니스 로직을 넣어** 빈약한 도메인 모델(`Anemic Domain Model`)을 피하려고 노력했다.

> 예: 재고 검증 로직(`issuedQuantity < totalQuantity`)은 `Coupon` 엔티티 내부에 `isIssuable()` 메서드로 구현

## DB 설계

### ERD
```
┌─────────────────┐       ┌─────────────────────┐
│     members     │       │       coupons       │
├─────────────────┤       ├─────────────────────┤
│ id (PK)         │       │ id (PK)             │
│ email (UK)      │       │ coupon_code (UK)    │
│ name            │       │ coupon_name         │
│ status          │       │ discount_amount     │
│ created_at      │       │ total_quantity      │
│ updated_at      │       │ issued_quantity     │
└────────┬────────┘       │ issue_start_at      │
         │                │ issue_end_at        │
         │                │ status              │
         │                │ version             │ ← 낙관적 락
         │                │ created_at          │
         │                │ updated_at          │
         │                └──────────┬──────────┘
         │                           │
         │    ┌──────────────────────┘
         │    │
         ▼    ▼
┌─────────────────────────────┐
│       coupon_issues         │
├─────────────────────────────┤
│ id (PK)                     │
│ coupon_id (FK)              │
│ member_id (FK)              │
│ issue_status                │
│ issued_at                   │
│ expire_at                   │
│ used_at                     │
│ created_at                  │
│ updated_at                  │
├─────────────────────────────┤
│ UK(coupon_id, member_id)    │ ← 중복 발급 방지
└─────────────────────────────┘
```
> `DDL`, 테스트 데이터는 `Flyway` 관련 `V...SQL` 파일 참고

### 설계 포인트
1. **중복 발급 방지**: `UK(coupon_id, member_id)`로 `DB` 레벨에서 강제
2. **재고 관리**: `issued_quantity`를 증가시키는 방식 (동시성 제어 필요)
3. **낙관적 락**: `version` 컬럼으로 동시 수정 충돌 감지
4. **인덱스 설계**: 자주 조회하는 컬럼에 인덱스 추가(`DDL` 참고)

## API 설계

### 쿠폰 발급 API
본 프로젝트의 핵심 기능으로, **동시성 제어 기법이 적용되는 지점이다.**
- **Endpoint**: `Post /api/v1/coupons/issue`
- **Payload**: `couponCode, memberId`
- **Status Code**: `200 OK`(발급 성공)
  - **409 Conflict**: 중복 발급, 재고 소진, 정책 위반
  - **500 Error**: 시스템 오류 및 재시도 최종실패

### 데이터 초기화 API
정확한 부하 테스트 측정을 위해 **테스트 시작 직후 특정 테이블 데이터를 초기화한다.**
- **Endpoint**: Post /api/test/reset
- **동작 원리(순서)**:
  1. `FK Checks` 일시 비활성화
  2. `coupon_issues` 테이블 `TRUNCATE` 실행
  3. `coupons` 테이블의 재고(`issued_quantity`) 및 낙관적 락 버전(`version`) 초기화
  4. 영속성 컨텍스트 초기화(`clear()`)를 통한 데이터 정합성 보장

## 예외 처리 설계

### 전역 예외 처리 적용 이유
각 `Controller` 마다 `try-catch` 를 작성하면 **중복 코드도 발생하고, 응답 포맷이 달라질 수 있다.**
`@RestControllerAdvice` 를 사용해 `GlobalExceptionHandler.class` **한 곳에서 모든 예외를 처리하도록** 설계했다.

| 클래스 | 역할 |
| :--- | :--- |
| `ErrorCode.class` | 에러 코드 `ENUM` |
| `BusinessException.class` | `ErrorCode.class` 를 담는 커스텀 예외 |
| `GlobalExceptionHandler.class` | `@ExceptionHandler` 로 예외 타입별 처리 |
| `ApiResponse.class` | 일관된 응답 포맷(`success, data, error, timestamp`) |

### 처리 흐름
```
Service 에서 throw new BusinessException(ErrorCode.COUPON_SOLD_OUT)
        │
        ▼
GlobalExceptionHandler가 @ExceptionHandler(BusinessException.class) 로 캐치
        │
        ▼
ErrorCode -> HTTP Status 매핑(COUPON_SOLD_OUT -> 409 Conflict)
        │
        ▼
APIResponse.failure(code, message) 형태로 응답
```

| 예외 | 처리 | HTTP Statuss |
| :--- | :--- | :--- |
| `BusinessException` | 비즈니스 에러 응답 | `ErrorCode` 에 따라 다름 |
| `MethodArgumentNotValidException` | `@Valid` 검증 실패 | `400` |
| `Exception` | 예상치 못한 에러 | `500` |

## 부하 테스트 환경
부하 테스트는 `k6` 을 사용한다. `Docker Compose` 로 `k6` 컨테이너를 실행하며, **모든 `Phase` 에서 동일한 테스트 환경을 사용해 각 동시성 제어 방식의 성능을 비교한다.**

| 설정 | 값 |
| :--- | :--- |
| **동시 사용자(`VUs`)** | `500 명` |
| **사용자당 요청** | `1 회` |
| **제한 시간** | `30 초` |

> 테스트 실행 전 `/api/test/reset API` 로 `DB` 를 초기화하고 각 `VU` 가 고유한 `memberId` 로 쿠폰 발급을 요청한다.

> 자세한 테스트 환경은 `/scripts/lock-test.js` 참고

## 환경 설정

| 파일 | 역할 |
| :--- | :--- |
| `application.yml` | 공통 설정(`Flyway, JPA`) |
| `application-local.yml` | 로컬 환경(`localhost DB, HikariCP` 설정) |
| `application-prod.yml` | 운영 환경 (운영 `DB`, 환경변수로 `credentials` 주입) |

> `Spring Profile` 로 `local, prod` 를 분리해서 환경별 설정을 관리한다.

## What's next
**Phase 1: 낙관적 락**:
- JPA `@Version`을 활용한 낙관적 락 구현
- 재시도 로직과 지수 백오프
- 500명 동시 접속 부하 테스트