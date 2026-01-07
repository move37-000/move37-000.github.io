---
title: (Docker) Spring 배포 환경 구축기 - 5. application.yml 설정과 Multi-Profile
date: 2026-01-05 00:00:00 +09:00
categories: [Docker, 개발환경]
tags: [Docker, Spring Boot, application.yml, Multi-Profile]
description: 파일 분리를 통한 환경별 Spring Boot 설정 최적화
image: 
---

> 본 포스팅에서는 아래 내용에 대해 소개합니다.
> - `application-{profile}.yml` 구조를 이용한 설정 파일 분리
> - 컨테이너 환경(`Docker`)과 로컬 환경(`Local`)의 호스트 주소 관리 차이
> - `${VAR}` 문법을 사용해 `Docker Compose`의 변수를 스프링에 매핑하는 법
> - `HikariCP` 커넥션 풀 및 `JPA ddl-auto` 등 환경별 상세 옵션

## 다 한 거 같은데...?

지난 포스팅에서 우리는 `Docker Compose`를 통해 `MySQL`, `Redis`, `Spring Boot`, `Nginx`가 **한 팀으로 움직이는 설계도**를 그렸습니다. 하지만 이 상태로 `docker-compose up`을 실행하면 애플리케이션은 다음과 같은 에러를 내뱉으며 종료될 가능성이 높습니다.

> java.net.ConnectException: Connection refused (Connection refused)

이유는 간단합니다. **스프링은 아직 자신이 컨테이너라는 섬에 갇혀 있다는 사실을 모르기 때문**입니다. 스프링 입장에서는 평소처럼 `localhost:3306`에 `DB`가 있을 거라 생각하지만, 도커 네트워크 안에서 `DB`의 주소는 더 이상 `localhost`가 아닙니다. 따라서 우리는 `application.yml`을 통해 스프링에게 **현재 네가 처한 환경(Profile)**이 어디인지를 알려주고, 그 환경에 맞는 **이정표(IP, Port 등)**를 제공해주어야 합니다.

## 파일 분리 전략 (Local vs Prod)

### application.yml 이란?

`application.yml` 은 스프링 부트 애플리케이션이 실행될 때 참조하는 **'설정 지도'**입니다. **데이터베이스 연결 정보, 서버 포트, 외부 `API` 키 등** 애플리케이션의 동작을 제어하는 모든 환경 변수를 이곳에서 관리합니다.

스프링은 `application-{profile}.yml`이라는 명명 규칙을 통해 환경별로 설정 파일을 갈아끼울 수 있는 `Multi-Profile` 기능을 제공합니다. 이를 활용하면 **코드를 수정하지 않고도 실행 시점에 '로컬 환경' 혹은 '도커 운영 환경'**으로 설정할 수 있습니다.

설정 정보가 많아질수록 하나의 `application.yml`에 모든 것을 담으면 유지보수가 어려워집니다. 따라서 **공통 설정은 메인 파일에 두고, 환경별로 특화된 설정은 파일을 분리하여 관리하는 것이 깔끔**합니다.

| 파일명 | 역할 | 내용 |
| `application.yml` | **공통 설정** | `Jackson`, 파일 업로드 용량, 프로파일 활성화 전략 |
| `application-local.yml` | **로컬 개발용** | `localhost` 기반 `DB` 연결, `DDL Update`, 상세 로그 |
| `application-prod.yml` | **도커 배포용** | `db-prod` 서비스명 연결, 환경변수($) 사용, 보안 설정 |

> `application.yml` 또는 `application-{profile}.yml` 파일들은 프로젝트의 `/src/main/resources/` 경로에 위치

![](/assets/img/2026-01-05/Docker_Setting(Spring)_5_img_1.png)*application.yml*

 
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

  jpa:                                   # JPA
    hibernate:
      ddl-auto: validate                
    show-sql: true                      
    properties:
      hibernate:
        format_sql: true                
        highlight_sql: true             
        use_sql_comments: true          
```
> **`Flyway`와 `JPA`의 역할 분담**
> - `Flyway`: `DB` 스키마 변경 관리 (마이그레이션 파일 기반)
> - `JPA`: 변경된 스키마 검증 및 엔티티 매핑
> 이렇게 분리하면 운영 환경(도커 환경)에서 애플리케이션이 실수로 테이블 구조를 변경하는 것을 방지할 수 있습니다.

기본적으로 `application.yml`에 `active: local`이라고 적어두었기 때문에, 평소 로컬에서 실행할 때는 **아무 설정 없이도 `local` 환경이 적용**됩니다.

하지만 `docker-compose.yml`에서 `SPRING_PROFILES_ACTIVE: prod` 라는 환경 변수를 주입하는 순간, **스프링은 내부 설정보다 외부 명령을 우선**하게 됩니다.

> 결과적으로, 똑같은 코드를 실행하더라도 **어디서 실행하느냐**에 따라 스프링이 알맞은 `application` 설정을 연결합니다.
{: .prompt-info }

| 구분 | 로컬 개발 환경 (`IDE`) | 도커 배포 환경 (`Container`) |
| :--- | :--- | :--- |
| 실행 주체 | `IntelliJ, Eclipse, Gradle` 등 | `Docker Engine (Compose)` |
| 프로필 결정 | `application.yml` **내부 설정** | `docker-compose.yml` **환경 변수** |
| 활성 프로필 | `local (Default)` | `prod (Injected)` |
| 참조 파일 | `application-local.yml` | `application-prod.yml` |
| 인식 범위 | **내 PC의 localhost** | **도커 네트워크 내의 서비스명** |

### 2. application-local.yml

내 `PC`에서 `IntelliJ` 등으로 직접 실행할 때 사용하는 설정입니다.

```yaml
spring:
  datasource:
    url: ${SPRING_DATASOURCE_URL:jdbc:mysql://localhost:3306/${DB_LOCAL_NAME:db_local_name}?useSSL=false&allowPublicKeyRetrieval=true&characterEncoding=UTF-8&serverTimezone=UTC}
    username: ${SPRING_DATASOURCE_USERNAME:${DB_LOCAL_USER_1:db_local_user_1}}              
    password: ${SPRING_DATASOURCE_PASSWORD:${DB_LOCAL_PASSWORD_1:db_local_user_1_password}}
    driver-class-name: com.mysql.cj.jdbc.Driver

  data:
    redis:
      host: ${SPRING_DATA_REDIS_HOST:localhost}
      port: ${SPRING_DATA_REDIS_PORT:6379}     
```
> **변수 치환 우선순위**
> 1. `SPRING_DATASOURCE_URL` 환경변수가 있으면 그 값 사용
> 2. 없으면 `jdbc:mysql://localhost:3306/...` 기본값 사용
> 3. 기본값 내부의 `${DB_LOCAL_NAME}` 다시 확인
> 4. `DB_LOCAL_NAME` 환경변수 있으면 사용, 없으면 `db_local_name` 사용

> 예시:
> - 환경변수 없음: `jdbc:mysql://localhost:3306/db_local_name`
> - `DB_LOCAL_NAME=mydb` 설정 시: `jdbc:mysql://localhost:3306/mydb`

> **IntelliJ에서 로컬 개발 시**: `EnvFile` 플러그인을 설치하면 `.env` 파일의 환경변수를 자동으로 로드합니다.

> 플러그인이 없다면 **콜론(:) 뒤의 기본값**이 적용됩니다.

### 3. application-prod.yml

`Docker` 컨테이너에서 돌아갈 핵심 설정입니다. `Docker Compose`**에서 넘겨준 변수들을 매핑**하는 것이 포인트입니다.

```yaml
spring:
  datasource:
    url: jdbc:mysql://db-prod:3306/${DB_PROD_NAME:db_prod_name}?useSSL=false&characterEncoding=UTF-8&serverTimezone=UTC
    # 운영 환경의 보안을 위해 계정 정보는 기본값 없이 반드시 외부(환경변수/.env)에서 주입
    username: ${SPRING_DATASOURCE_USERNAME}
    password: ${SPRING_DATASOURCE_PASSWORD}
    
    # HikariCP 커넥션 풀 최적화
    hikari:
      maximum-pool-size: 20       
      minimum-idle: 10            
      idle-timeout: 30000         
      connection-timeout: 20000   

  data:
    redis:
      host: redis           # docker-compose.yml의 서비스명과 일치   
      port: 6379
      lettuce:
        pool:
          max-active: 10         

  jpa:
    hibernate:
      # 공통 설정의 'validate 무시하고 'none' 으로 덮어씌워, 앱이 DB 스키마를 절대 건드리지 못하게 변경
      ddl-auto: none            
```
> **보안 주의사항**
> - `username`, `password`에 기본값(`:` 뒤)이 **의도적으로 없습니다.**
> - 환경변수가 주입되지 않으면 애플리케이션이 시작 실패하도록 하여 보안 사고 방지
> - `.env` 파일은 반드시 `.gitignore`에 추가하여 Git에 커밋되지 않도록 관리
> - 실제 운영 환경에서는 `AWS Secrets Manager`, `HashiCorp Vault` 등 별도 Tool 을 사용합니다.

## Docker와 Spring의 연결 고리

분리한 이 파일들이 도커에선 어떻게 작동될까요?

1. **프로파일 선택**: `docker-compose.yml`에서 `SPRING_PROFILES_ACTIVE: prod`를 설정했기 때문에, 스프링은 실행 시 자동으로 `application-prod.yml`을 찾아 로드
2. **변수 치환**: `application-prod.yml`에 적힌 `${DB_PROD_NAME}` 등은 도커 컨테이너의 시스템 환경 변수에서 값 조회
3. **네트워크 호스트**: `url`에 적힌 `db-prod`는 도커의 내장 `DNS`가 `db-prod` 컨테이너의 내부 `IP`로 자동 변환

![](/assets/img/2026-01-05/Docker_Setting(Spring)_5_img_2.png)*[Docker Network](https://www.docker.com/blog/how-docker-desktop-networking-works-under-the-hood/)*

## 현재까지의 진행 상황

지금까지 우리는 다음을 완성했습니다:
- ✅ `Dockerfile` 을 통한 **Multi-stage 빌드 및 경량화된 런타임 이미지 구성**
- ✅ `docker-compose.yml` 을 통한 **MySQL, Redis, Spring Boot 통합 네트워크 구성**
- ✅ `Spring Boot` 환경별 설정 파일 (`application-local.yml`, `application-prod.yml`)

하지만 아직 `docker-compose up`을 실행하면 **Nginx 설정 파일이 없어** 컨테이너가 제대로 뜨지 않을 것입니다.
```powershell
# 현재 상태에서 실행하면?
docker-compose up
# Error: nginx: [emerg] open() "/etc/nginx/conf.d/default.conf" failed
```

## What's next

설정 파일까지 완벽하게 분리하여 애플리케이션이 도커 환경에 안착했습니다. 이제 마지막으로 `Nginx`를 설정하여 외부에서 도커 서비스에 접속할 수 있는 통로를 열어줄 차례입니다.

- **`Nginx` 리버스 프록시**: 외부 `80` 포트 요청을 스프링 `8080`으로 전달
- **`default.conf` 작성**: `Nginx`의 상세 설정과 로드 밸런싱 기초
- **최종 접속 테스트**: 브라우저에서 서비스 호출 확인