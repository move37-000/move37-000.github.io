---
title: (Docker) Spring 배포 환경 구축기 - 5. application.yml 설정과 Multi-Profile
date: 2026-01-05 00:00:00 +09:00
categories: [Docker, 개발환경]
tags: [Docker, Spring Boot, application.yml, Multi-Profile]
description: 파일 분리를 통한 환경별 Spring Boot 설정 최적화
image: 
---

> 본 포스팅에서는 아래 내용에 대해 소개합니다.
> - application-{profile}.yml 구조를 이용한 설정 파일 분리
> - Docker 네트워크 환경에 맞는 datasource 호스트 설정
> - Docker Compose의 환경 변수를 개별 설정 파일에서 수신하는 법
> - 각 환경에 최적화된 JPA 및 Redis 설정

## 다 한 거 같은데...?

지난 포스팅에서 우리는 `Docker Compose`를 통해 `MySQL`, `Redis`, `Spring Boot`, `Nginx`가 **한 팀으로 움직이는 설계도**를 그렸습니다. 하지만 이 상태로 `docker-compose up`을 실행하면 애플리케이션은 다음과 같은 에러를 내뱉으며 종료될 가능성이 높습니다.

> java.net.ConnectException: Connection refused (Connection refused)

이유는 간단합니다. **스프링은 아직 자신이 컨테이너라는 섬에 갇혀 있다는 사실을 모르기 때문**입니다. 스프링 입장에서는 평소처럼 `localhost:3306`에 `DB`가 있을 거라 생각하지만, 도커 네트워크 안에서 `DB`의 주소는 더 이상 `localhost`가 아닙니다.

## 파일 분리 전략 (Local vs Prod)

설정 정보가 많아질수록 하나의 `application.yml`에 모든 것을 담으면 가독성이 떨어집니다. 따라서 **공통 설정은 메인 파일에 두고, 환경별로 특화된 설정은 파일을 분리하여 관리하는 것이 깔끔**합니다.

| 파일명 | 역할 | 내용 |
| `application.yml` | **공통 설정** | `Jackson`, 파일 업로드 용량, 프로파일 활성화 전략 |
| `application-local.yml` | **로컬 개발용** | `localhost` 기반 `DB` 연결, `DDL Update`, 상세 로그 |
| `application-prod.yml` | **도커 배포용** | `db-prod` 서비스명 연결, 환경변수($) 사용, 보안 설정 |
 
### 1. application.yml

가장 먼저 읽히는 메인 파일입니다. 어떤 프로파일을 활성화할지 결정합니다.

```yaml
spring:
  profiles:
    active: local                       # 아무런 설정 없이 실행했을 때 적용될 기본 프로필

  flyway:
    enabled: true                       # Flyway
    baseline-on-migrate: true           
    validate-on-migrate: true           
    locations: "classpath:db/migration" 

  jpa:
    hibernate:
      ddl-auto: validate                
    show-sql: true                      
    properties:
      hibernate:
        format_sql: true                
        highlight_sql: true             
        use_sql_comments: true          
```

### 2. application-local.yml

내 `PC`에서 `IntelliJ` 등으로 직접 실행할 때 사용하는 설정입니다.

```yaml
spring:
  datasource:
    url: ${SPRING_DATASOURCE_URL:jdbc:mysql://localhost:3306/high_traffic_db_local?useSSL=false&allowPublicKeyRetrieval=true&characterEncoding=UTF-8&serverTimezone=UTC}
    username: ${SPRING_DATASOURCE_USERNAME:high_traffic_db_local_user_1}          
    password: ${SPRING_DATASOURCE_PASSWORD:high_traffic_db_local_user_1_password} 
    driver-class-name: com.mysql.cj.jdbc.Driver

  data:
    redis:
      host: ${SPRING_DATA_REDIS_HOST:localhost}
      port: ${SPRING_DATA_REDIS_PORT:6379}         
```

### 3. application-prod.yml

`Docker` 컨테이너 내부에서 돌아갈 핵심 설정입니다. `Docker Compose`**에서 넘겨준 변수들을 매핑**하는 것이 포인트입니다.

```yaml
spring:
  datasource:
    url: jdbc:mysql://db-prod:3306/high_traffic_db_prod?useSSL=false&characterEncoding=UTF-8&serverTimezone=UTC
    # 운영 환경의 보안을 위해 계정 정보는 기본값 없이 반드시 외부(환경변수/.env)에서 주입
    username: ${SPRING_DATASOURCE_USERNAME}
    password: ${SPRING_DATASOURCE_PASSWORD}
    
    # HikariCP 최적화
    hikari:
      maximum-pool-size: 20       
      minimum-idle: 10            
      idle-timeout: 30000         
      connection-timeout: 20000   

  data:
    redis:
      host: redis              
      port: 6379
      lettuce:
        pool:
          max-active: 10         

  jpa:
    hibernate:
      # 공통 설정의 'validate 무시하고 'none' 으로 덮어씌워, 앱이 DB 스키마를 절대 건드리지 못하게 변경
      ddl-auto: none            
```

## Docker와 Spring의 연결 고리

우리가 분리한 이 파일들이 도커에서 어떻게 작동하는지 원리를 이해하는 것이 중요합니다.

1. **프로파일 선택**: `docker-compose.yml`에서 `SPRING_PROFILES_ACTIVE: prod`를 설정했기 때문에, 스프링은 실행 시 자동으로 `application-prod.yml`을 찾아 로드합니다.
2. **변수 치환**: `application-prod.yml`에 적힌 `${DB_PROD_NAME}` 등은 도커 컨테이너의 시스템 환경 변수에서 값을 가져옵니다.
3. **네트워크 호스트**: `url`에 적힌 `db-prod`는 도커의 내장 `DNS`가 `local-mysql-db` 컨테이너의 내부 `IP`로 자동 변환해줍니다.

## 서비스 기동 및 로그 확인

이제 모든 준비가 끝났습니다. 터미널에서 서비스를 실행합니다.

```powershell
# 빌드 및 백그라운드 실행
docker-compose up -d --build

# 실시간 로그 확인 (성공적으로 떴는지 확인)
docker logs -f spring-app         
```

로그에 `The following profiles are active: prod`라는 문구와 함께 `DB` 연결 성공 메시지가 보인다면, 환경 구축의 9부 능선을 넘은 것입니다.

## What's next

설정 파일까지 완벽하게 분리하여 애플리케이션이 도커 환경에 안착했습니다. 이제 마지막으로 `Nginx`를 설정하여 외부에서 우리 서비스에 접속할 수 있는 통로를 열어줄 차례입니다.

- **`Nginx` 리버스 프록시**: 외부 `80` 포트 요청을 스프링 `8080`으로 전달
- **`default.conf` 작성**: `Nginx`의 상세 설정과 로드 밸런싱 기초
- **최종 접속 테스트**: 브라우저에서 서비스 호출 확인