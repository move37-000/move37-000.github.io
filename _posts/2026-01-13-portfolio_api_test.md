---
title: 대용량 트래픽 제어 포트폴리오 - 1(api test)
date: 2026-01-13 00:00:00 +09:00
categories: [Spring, JPA, MySQL]
tags: [Spring, JPA, MySQL]
description: 포트폴리오
image: 
published: false
---

# ============================================
# 쿠폰 발급 시스템 API 테스트 가이드
# ============================================

## 🎯 테스트 방법

### 방법 1: 테스트 페이지 (가장 쉬움 👍)

프로젝트 루트에 있는 `test-page.html` 파일을 브라우저로 열어서 테스트

#### 실행 방법
```bash
# 1. 서버 실행
./gradlew bootRun

# 2. test-page.html 파일을 브라우저로 열기
open test-page.html  (Mac)
start test-page.html (Windows)
# 또는 브라우저에서 직접 파일 열기
```

#### 테스트 데이터
- **쿠폰 코드**: WELCOME2024, FLASH100, VIP2024
- **회원 ID**: 1 ~ 5 (data.sql 참고)

#### 화면 기능
- ✅ 쿠폰 코드, 회원 ID 입력
- ✅ 발급하기 버튼 클릭
- ✅ 성공/실패 결과 색상으로 표시
- ✅ 응답 JSON 전체 확인 가능
- ✅ Enter 키로 빠른 발급

---

### 방법 2: cURL 명령어

## 1. 쿠폰 발급 API

### 1-1. 정상 발급
curl -X POST http://localhost:8080/api/v1/coupons/issue \
  -H "Content-Type: application/json" \
  -d '{
    "couponCode": "WELCOME2024",
    "memberId": 1
  }'

### 예상 응답 (성공)
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

### 1-2. 중복 발급 시도
curl -X POST http://localhost:8080/api/v1/coupons/issue \
  -H "Content-Type: application/json" \
  -d '{
    "couponCode": "WELCOME2024",
    "memberId": 1
  }'

### 예상 응답 (실패 - 중복 발급)
{
  "success": false,
  "data": null,
  "error": {
    "code": "COUPON-004",
    "message": "이미 발급받은 쿠폰입니다."
  },
  "timestamp": "2024-01-09T10:31:00"
}

### 1-3. 존재하지 않는 쿠폰
curl -X POST http://localhost:8080/api/v1/coupons/issue \
  -H "Content-Type: application/json" \
  -d '{
    "couponCode": "INVALID_CODE",
    "memberId": 1
  }'

### 예상 응답 (실패 - 쿠폰 없음)
{
  "success": false,
  "data": null,
  "error": {
    "code": "COUPON-001",
    "message": "쿠폰을 찾을 수 없습니다."
  },
  "timestamp": "2024-01-09T10:32:00"
}

### 1-4. 존재하지 않는 회원
curl -X POST http://localhost:8080/api/v1/coupons/issue \
  -H "Content-Type: application/json" \
  -d '{
    "couponCode": "WELCOME2024",
    "memberId": 999
  }'

### 예상 응답 (실패 - 회원 없음)
{
  "success": false,
  "data": null,
  "error": {
    "code": "MEMBER-001",
    "message": "회원을 찾을 수 없습니다."
  },
  "timestamp": "2024-01-09T10:33:00"
}

## 2. 대용량 트래픽 시뮬레이션 (Apache Bench)

### 2-1. 동시 100명, 총 1000건 요청
ab -n 1000 -c 100 -p request.json -T "application/json" \
  http://localhost:8080/api/v1/coupons/issue

### request.json 파일 내용:
{
  "couponCode": "FLASH100",
  "memberId": 1
}

### 2-2. 동시 200명, 총 10000건 요청 (부하 테스트)
ab -n 10000 -c 200 -p request.json -T "application/json" \
  http://localhost:8080/api/v1/coupons/issue

## 3. 데이터베이스 확인 쿼리

### 3-1. 쿠폰 발급 현황 조회
SELECT 
    c.coupon_code,
    c.coupon_name,
    c.total_quantity,
    c.issued_quantity,
    (c.total_quantity - c.issued_quantity) AS available_quantity,
    ROUND((c.issued_quantity / c.total_quantity) * 100, 2) AS issue_rate
FROM coupons c
WHERE c.status = 'ACTIVE';

### 3-2. 회원별 쿠폰 발급 이력
SELECT 
    m.email,
    c.coupon_code,
    c.coupon_name,
    ci.issue_status,
    ci.issued_at,
    ci.expire_at
FROM coupon_issues ci
INNER JOIN members m ON ci.member_id = m.id
INNER JOIN coupons c ON ci.coupon_id = c.id
WHERE m.id = 1
ORDER BY ci.issued_at DESC;

### 3-3. 낙관적 락 버전 확인
SELECT 
    id,
    coupon_code,
    issued_quantity,
    version
FROM coupons
WHERE coupon_code = 'FLASH100';

## 4. 성능 모니터링

### 4-1. 응답 시간 측정
time curl -X POST http://localhost:8080/api/v1/coupons/issue \
  -H "Content-Type: application/json" \
  -d '{
    "couponCode": "WELCOME2024",
    "memberId": 2
  }'

### 4-2. JMeter 테스트 시나리오
- Thread Group: 1000 users
- Ramp-up Period: 10 seconds
- Loop Count: 1
- HTTP Request: POST /api/v1/coupons/issue

---

## 🧪 추천 테스트 시나리오

### 시나리오 1: 정상 발급 (테스트 페이지)
1. test-page.html 열기
2. 쿠폰코드: WELCOME2024, 회원ID: 1 입력
3. "쿠폰 발급하기" 클릭
4. ✅ 성공 메시지와 쿠폰 정보 확인

### 시나리오 2: 중복 발급 방지 (테스트 페이지)
1. 같은 쿠폰으로 다시 발급 시도
2. ❌ "이미 발급받은 쿠폰입니다" 에러 확인

### 시나리오 3: 품절 테스트 (cURL 반복)
```bash
# FLASH100 쿠폰 (100개 한정)을 101번 발급 시도
for i in {1..101}; do
  curl -X POST http://localhost:8080/api/v1/coupons/issue \
    -H "Content-Type: application/json" \
    -d "{\"couponCode\":\"FLASH100\",\"memberId\":$i}"
  echo ""
done

# 100번째까지 성공, 101번째는 품절 에러
```

### 시나리오 4: 동시성 테스트 (Apache Bench)
```bash
# 동시 100명이 같은 쿠폰 발급 시도
ab -n 100 -c 100 -p request.json -T "application/json" \
  http://localhost:8080/api/v1/coupons/issue

# request.json:
# {"couponCode":"FLASH100","memberId":1}

# 결과: 1명만 성공, 99명은 중복 발급 에러
```

### 시나리오 5: 잘못된 입력 (테스트 페이지)
1. 쿠폰코드 빈 값으로 발급 시도 → 입력값 검증 에러
2. 존재하지 않는 회원 ID (999) → "회원을 찾을 수 없습니다"
3. 잘못된 쿠폰 코드 → "쿠폰을 찾을 수 없습니다"

---

## 📊 예상 결과

### 성공 케이스
- HTTP Status: 200 OK
- success: true
- data에 쿠폰 정보 포함
- 테스트 페이지: 초록색 성공 메시지

### 실패 케이스
- HTTP Status: 404 (NOT_FOUND) / 409 (CONFLICT)
- success: false
- error.code: COUPON-XXX 또는 MEMBER-XXX
- error.message: 상세 에러 메시지
- 테스트 페이지: 빨간색 에러 메시지