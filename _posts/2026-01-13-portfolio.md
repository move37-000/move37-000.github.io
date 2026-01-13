---
title: 대용량 트래픽 제어 포트폴리오 - 1
date: 2026-01-13 00:00:00 +09:00
categories: [Spring, JPA, MySQL]
tags: [Spring, JPA, MySQL]
description: 포트폴리오
image: 
published: false
---

# 대용량 트래픽 제어 포트폴리오 - 쿠폰 발급 시스템

## 📋 프로젝트 개요

대용량 트래픽 환경에서 안정적인 쿠폰 발급 시스템 구축을 목표로 하는 백엔드 포트폴리오 프로젝트입니다.

### 핵심 목표
- **동시성 제어**: 낙관적 락을 활용한 대용량 트래픽 처리
- **확장성**: 단계별 기능 확장이 가능한 아키텍처 설계
- **엔터프라이즈급 코드 품질**: 대기업 IT 표준에 부합하는 코드 작성

> 💡 **테스트 페이지 제공**: 쉬운 동작 확인을 위한 HTML 테스트 페이지 포함 (test-page.html)

---

## 🎯 1단계: 최소 기능 구현

### 구현 범위
✅ 쿠폰 발급 API (`POST /api/v1/coupons/issue`)  
✅ Entity 및 데이터베이스 설계  
✅ 낙관적 락을 통한 동시성 제어  
✅ 중복 발급 방지  
✅ 재고 관리 및 품절 처리  

### 기술 스택
- **Language**: Java 17
- **Framework**: Spring Boot 3.2.1
- **ORM**: Spring Data JPA
- **Database**: MySQL 8.0
- **Build Tool**: Gradle

---

## 🏗️ 아키텍처 설계

### 레이어드 아키텍처
```
Presentation Layer (Controller)
         ↓
Application Layer (Service)
         ↓
Domain Layer (Entity, Repository)
         ↓
Infrastructure Layer (Config, Exception)
```

### 패키지 구조
```
com.project.coupon
├── domain                    # 도메인 계층
│   ├── coupon
│   │   ├── entity           # 쿠폰, 쿠폰발급 엔티티
│   │   └── repository       # JPA Repository
│   └── member
│       ├── entity           # 회원 엔티티
│       └── repository       # JPA Repository
├── application              # 애플리케이션 계층
│   └── coupon
│       ├── service          # 비즈니스 로직
│       └── dto              # DTO
├── presentation             # 프레젠테이션 계층
│   └── coupon
│       ├── controller       # REST API
│       └── request          # 요청 DTO
├── infrastructure           # 인프라 계층
│   ├── config              # 설정
│   └── exception           # 예외 처리
└── common                   # 공통 모듈
    ├── response            # 공통 응답
    └── exception           # 공통 예외
```

---

## 🗄️ 데이터베이스 설계

### ERD
```
members (회원)
  ├── id (PK)
  ├── email (UK)
  ├── name
  ├── status
  └── created_at, updated_at

coupons (쿠폰)
  ├── id (PK)
  ├── coupon_code (UK)
  ├── coupon_name
  ├── discount_amount
  ├── total_quantity
  ├── issued_quantity
  ├── issue_start_at, issue_end_at
  ├── status
  ├── version (낙관적 락)
  └── created_at, updated_at

coupon_issues (쿠폰 발급 이력)
  ├── id (PK)
  ├── coupon_id (FK) ─┐
  ├── member_id (FK) ─┼─ UK (중복 발급 방지)
  ├── issue_status    │
  ├── issued_at       │
  ├── expire_at       │
  ├── used_at         │
  └── created_at, updated_at
```

### 인덱싱 전략
- `coupons.coupon_code`: 쿠폰 조회 최적화
- `coupons.issue_start_at, issue_end_at`: 발급 기간 조회
- `coupon_issues.coupon_id, member_id`: 중복 발급 체크 (UK)
- `coupon_issues.expire_at`: 만료 쿠폰 배치 처리

---

## 🔒 동시성 제어 전략

### 낙관적 락 (Optimistic Lock) 적용
```java
@Entity
@Table(name = "coupons")
public class Coupon {
    
    @Version
    private Long version;  // JPA 낙관적 락
    
    private Integer issuedQuantity;
    
    public void increaseIssuedQuantity() {
        this.issuedQuantity++;
    }
}
```

### 재시도 메커니즘
- **최대 재시도 횟수**: 3회
- **재시도 전략**: 지수 백오프 (Exponential Backoff)
- **충돌 시 동작**: 대기 후 재시도

```java
@Service
public class CouponIssueService {
    private static final int MAX_RETRY_COUNT = 3;
    
    public CouponIssueResponse issueCoupon(String couponCode, Long memberId) {
        int retryCount = 0;
        while (retryCount < MAX_RETRY_COUNT) {
            try {
                return issueCouponWithTransaction(couponCode, memberId);
            } catch (ObjectOptimisticLockingFailureException e) {
                retryCount++;
                Thread.sleep((long) Math.pow(2, retryCount) * 10);
            }
        }
    }
}
```

### 왜 낙관적 락인가?
1. **높은 처리량**: 비관적 락 대비 데드락 위험 감소
2. **읽기 성능**: 조회 시 락을 걸지 않아 성능 우수
3. **확장성**: 대용량 트래픽 환경에 적합

---

## 🚀 API 명세

### POST /api/v1/coupons/issue
쿠폰 발급 요청

#### Request
```json
{
  "couponCode": "WELCOME2024",
  "memberId": 1
}
```

#### Response (성공)
```json
{
  "success": true,
  "data": {
    "issueId": 1,
    "couponId": 1,
    "couponCode": "WELCOME2024",
    "couponName": "신규회원 환영 쿠폰",
    "discountAmount": 10000,
    "issuedAt": "2024-01-09T10:30:00",
    "expireAt": "2024-02-08T10:30:00"
  },
  "error": null,
  "timestamp": "2024-01-09T10:30:00"
}
```

#### Response (실패 - 품절)
```json
{
  "success": false,
  "data": null,
  "error": {
    "code": "COUPON-003",
    "message": "쿠폰이 모두 소진되었습니다."
  },
  "timestamp": "2024-01-09T10:31:00"
}
```

---

## 🔄 비즈니스 로직 플로우

### 쿠폰 발급 프로세스
```
1. 요청 검증
   ├── Request DTO Validation (@Valid)
   └── 필수값 체크
   
2. 회원 검증
   ├── 회원 존재 여부 확인
   └── 회원 상태 확인 (ACTIVE)
   
3. 쿠폰 조회 (낙관적 락)
   └── @Lock(LockModeType.OPTIMISTIC)
   
4. 발급 가능 여부 검증
   ├── 중복 발급 체크 (UK 제약)
   ├── 발급 기간 체크
   ├── 재고 수량 체크
   └── 쿠폰 상태 체크
   
5. 쿠폰 발급
   ├── 발급 수량 증가 (version++)
   └── 발급 이력 생성
   
6. 응답 반환
```

---

## ⚙️ 실행 방법

### 1. 데이터베이스 설정
```sql
CREATE DATABASE coupon_db;
USE coupon_db;

-- schema.sql 실행
-- data.sql 실행 (테스트 데이터)
```

### 2. 애플리케이션 실행
```bash
# Gradle 빌드 및 실행
./gradlew clean build
./gradlew bootRun

# 또는 IDE에서 CouponSystemApplication 실행
```

### 3. 테스트 방법

#### 방법 1: 테스트 페이지 사용 (추천 👍)
```bash
# 프로젝트 루트의 test-page.html 파일을 브라우저로 열기
open test-page.html  (Mac)
start test-page.html (Windows)

# 또는 브라우저에서 직접 파일 열기
```

테스트 페이지 기능:
- 쿠폰 코드, 회원 ID 입력
- 버튼 클릭으로 쿠폰 발급
- 성공/실패 결과 실시간 표시
- 상세 응답 데이터 확인

#### 방법 2: cURL 테스트
```bash
curl -X POST http://localhost:8080/api/v1/coupons/issue \
  -H "Content-Type: application/json" \
  -d '{
    "couponCode": "WELCOME2024",
    "memberId": 1
  }'
```

자세한 API 테스트 방법은 [API_TEST_GUIDE.md](./API_TEST_GUIDE.md) 참고

---

## 📊 성능 고려사항

### 현재 구현
- **동시 처리**: 낙관적 락 + 재시도 메커니즘
- **인덱싱**: 쿠폰 코드, 회원 ID, 발급 기간
- **커넥션 풀**: HikariCP (최대 20개)

### 향후 최적화 예정 (2단계 이후)
- Redis 캐싱 도입
- 비동기 처리 (Kafka/RabbitMQ)
- 분산 락 (Redisson)
- 데이터베이스 샤딩

---

## 🎓 배운 점 & 기술적 고민

### 낙관적 락 vs 비관적 락
- **낙관적 락 선택 이유**: 읽기가 많은 환경, 충돌 확률 낮음
- **트레이드오프**: 재시도 로직 필요, 최종 일관성

### 엔티티 설계
- **버전 관리**: `@Version`을 통한 동시성 제어
- **제약 조건**: 중복 발급 방지를 위한 UK 설정
- **인덱스 전략**: 쿼리 패턴 분석 후 선택적 인덱싱

### 코드 품질
- **불변성**: Lombok `@Builder`, `@Getter` 활용
- **명확한 책임 분리**: 레이어드 아키텍처 준수
- **예외 처리**: 전역 예외 핸들러로 일관된 응답

---

## 📝 다음 단계 계획

### 2단계: 성능 최적화
- [ ] Redis 캐싱 적용
- [ ] 조회수 카운팅 최적화
- [ ] N+1 문제 해결

### 3단계: 대용량 트래픽 대응
- [ ] 메시지 큐 도입 (비동기 처리)
- [ ] 분산 락 적용
- [ ] API Rate Limiting

### 4단계: 모니터링 & 관리
- [ ] Prometheus + Grafana
- [ ] 로깅 시스템 (ELK)
- [ ] 관리자 페이지

---

## 📞 Contact
- 프로젝트 관련 문의: [GitHub Issues]
- 포트폴리오: [LinkedIn/Portfolio]