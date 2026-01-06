---
title: (Docker) Spring 배포 환경 구축기 - 4. Docker Compose
date: 2026-01-02 00:00:00 +09:00
categories: [Docker, 개발환경]
tags: [Docker, Docker Compose, Spring Boot, MySQL, Redis, nginx]
description: Docker Compose를 사용한 Docker 컨테이너 관리
image: 
---

> 본 포스팅에서는 아래 내용에 대해 소개합니다.
> - `Docker Compose`의 개념과 필요성 이해
> - `docker-compose.yml` 파일을 이용한 멀티 컨테이너 정의
> - 애플리케이션과 데이터베이스 컨테이너 간 네트워크 연결
> - 단 한 줄의 명령어로 전체 서비스 기동하기

## 명령어 두 줄 입력하는 것도 귀찮은데...

지난 포스팅에서 `Spring Boot` 애플리케이션을 최적화된 이미지로 빌드하고 실행하는 데 성공했습니다. 하지만 실제 서비스는 애플리케이션 혼자 돌아가지 않습니다. `MySQL` 같은 `DB`가 필요하고, 때로는 `Redis` 같은 캐시 서버도 필요하죠.

![](/assets/img/2026-01-02/Docker_Setting(Spring)_4_img_1.webp)*[Docker Applications](https://medium.com/@ansgar.nell/set-up-a-complete-basic-ecosystem-with-angular-spring-boot-docker-google-cloud-git-and-jenkins-b2e062e684e8)*

지금까지의 방식대로라면 우리는 매번 다음과 같은 번거로운 과정을 반복해야 합니다.
1. `Network` 생성 (컨테이너끼리 통신하기 위해)
2. `MySQL` 컨테이너 실행 (환경변수, 포트 설정...)
3. `Spring` 컨테이너 실행 (DB 접속 정보 설정...)

> 이 번거로운 과정을 **파일 하나로 정의하고 관리**하게 해주는 도구가 바로 **Docker Compose**입니다.
{: .prompt-info }

## Docker Compose?

**Docker Compose**는 여러 개의 컨테이너를 정의하고 실행하기 위한 도구입니다. `YAML` 파일을 사용하여 애플리케이션의 서비스, 네트워크, 볼륨 설정을 한 번에 관리할 수 있습니다.

| Docker CLI(기존 방식) | Docker Compose |
| :--- | :--- |
| 각 컨테이너를 개별 명령어로 실행 | `docker-compose.yml`에 모두 정의 |
| 컨테이너 간 네트워크 수동 설정 | 서비스 이름으로 자동 `DNS` 실행 |
| 실행 순서 제어 어려움 | `depends_on`으로 실행 순서 보장 |

![](/assets/img/2026-01-02/Docker_Setting(Spring)_4_img_2.webp)*[Docker Compose](https://builder.aws.com/content/2qi9qQstGnCWguDzgLg1NgP8lBF/file-structure-of-docker-composeyml-file)*

## docker-compose.yml 작성하기

이왕 파일 작성하는 김에 **보안·안정성·확장성**을 고려한 설정을 적용하겠습니다. 프로젝트 루트 경로에 `docker-compose.yml` 파일을 생성하고 아래 내용을 작성합니다.

```yaml
services:
  # DB service(local DB)
  db-local:
    image: mysql:8.0                    # 'latest' 대신 특정 버전을 명시하여 어디서든 동일한 환경 구축 보장
    container_name: local-mysql-db      # 컨테이너를 식별하기 위한 고유 이름
    restart: always                     # 컨테이너가 예기치 않게 종료될 경우 자동으로 재시작하여 가용성 확보
    # 민감한 비밀번호는 .env 파일에서 변수로 읽어와 보안 강화
    environment:
      MYSQL_DATABASE: ${DB_LOCAL_NAME}
      MYSQL_ROOT_PASSWORD: ${DB_LOCAL_ROOT_PASSWORD}
      MYSQL_USER: ${DB_LOCAL_USER_1}
      MYSQL_PASSWORD: ${DB_LOCAL_PASSWORD_1}
    # 포트 포워딩  
    ports:
      - "3306:3306"
    # Named Volume                   
    volumes:
      - mysql_local_data:/var/lib/mysql 
    # 서비스 간 통신을 위한 격리된 네트워크 설정
    networks:
      - backend-network
    healthcheck:
      test: ["CMD", "mysqladmin" ,"ping", "-h", "localhost"] # mysqladmin 도구로 생존 신호 확인
      interval: 5s  # 5초마다 체크
      timeout: 5s   # 응답 대기 시간
      retries: 10   # 실패 시 재시도 횟수
    # Resource Limits
    # 특정 컨테이너가 서버의 CPU/메모리를 독점하여 전체 시스템이 느려지는 것 방지
    deploy:
      resources:
        limits:
          cpus: '0.5'   # CPU 사용량 50% 제한
          memory: 512M  # 메모리 512MB 제한

  # DB service(prod DB)
  db-prod:
    image: mysql:8.0
    container_name: production-mysql-db
    restart: always
    environment:
      MYSQL_DATABASE: ${DB_PROD_NAME}
      MYSQL_ROOT_PASSWORD: ${DB_PROD_ROOT_PASSWORD}
      MYSQL_USER: ${DB_PROD_USER_1}
      MYSQL_PASSWORD: ${DB_PROD_PASSWORD_1}
    # 운영 환경에서는 포트를 닫지만, 로컬 개발 환경에서 테스트를 위해 3307 포트로 개방
    ports:
      - "3307:3306"
    volumes:
      - mysql_prod_data:/var/lib/mysql
    networks:
      - backend-network
    healthcheck:
      test: [ "CMD", "mysqladmin" ,"ping", "-h", "localhost" ]
      interval: 5s
      timeout: 5s
      retries: 10
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M

  # Cache(redis) service
  redis:
    image: redis:latest
    container_name: redis-cache
    # 데이터 휘발 방지를 위한 스냅샷 설정 및 로그 레벨 조정
    command: redis-server --save 60 1 --loglevel warning
    ports:
      - "6379:6379"
    networks:
      - backend-network
    deploy:
      resources:
        limits:
          memory: 256M

  # Application(Spring Boot)
  app:
    # Multi-stage
    build: . 
    image: spring-basic
    container_name: spring-app
    environment:
      # Docker 내부에서 실행 시 prod 프로파일 강제 활성화
      SPRING_PROFILES_ACTIVE: prod
      # DB 서비스 이름인 'db-prod'를 호스트명으로 사용하여 통신
      SPRING_DATASOURCE_URL: jdbc:mysql://db-prod:3306/${DB_PROD_NAME}?useSSL=false&allowPublicKeyRetrieval=true
      SPRING_DATASOURCE_USERNAME: ${DB_PROD_USER_1}
      SPRING_DATASOURCE_PASSWORD: ${DB_PROD_PASSWORD_1}
      SPRING_DATA_REDIS_HOST: redis
    depends_on:
      db-prod:
        # 단순 실행이 아닌, DB의 Healthcheck가 통과될 때까지 대기
        condition: service_healthy 
      redis:
        condition: service_started
    # 호스트와 로그 디렉토리 공유하여 로그 보존    
    volumes:
      - ./logs:/app/logs    
    # 컨테이너 내부 포트만 노출 (Docker 네트워크 내부에서만 접근 가능)  
    expose:
      - "8080"              
    restart: always
    networks:
      - backend-network

  # Web Server(Nginx)
  # nginx 설정은 다음 포스팅에서 다룰 예정(default.conf)
  nginx:
    image: nginx:latest
    container_name: nginx-proxy
    # 외부 80 포트로 접속하면 Nginx가 받음
    ports:
      - "80:80"   
    # Nginx 설정 파일 마운트 (읽기 전용)    
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro  
    # 앱 서버가 실행된 후 Nginx 기동  
    depends_on: 
      - app         
    networks:
      - backend-network

# 네트워크 정의: 서비스 이름(예: db, redis)을 호스트명으로 사용하여 통신 가능
networks:
  # 컨테이너 간 독립적인 통신을 위한 기본 브리지 네트워크
  backend-network:
    driver: bridge 

# 사용한 볼륨들 정의
volumes:
  mysql_local_data:
  mysql_prod_data:
```

## 무엇이 왜 적용되었나?

작성된 코드는 단순한 실행을 넘어 프로젝트 진행 중 마주칠 문제들을 미리 대비하고 있습니다.

1. **환경 변수 분리 (`.env`)** 
- `DB` 비밀번호 같은 민감 정보를 코드에 직접 적지 않고 `${VARIABLE}` 형태로 작성 
- 이는 별도의 `.env` 파일에서 값을 읽어오도록 설정한 것으로, 소스 코드 유출 시 **보안** 유지 가능
> `.env` 파일은 `Dockerfile`, `docker-compose.yml` 의 경로와 같은 프로젝트 루트 경로에 위치
2. **로컬 개발과 운영 데이터의 분리 (`db-local`, `db-prod`)**
- 실제 애플리케이션(`app`)은 `db-prod`와 연결되어 동작하지만, 개발 단계(로컬)와 운영 단계의 프로세스를 분리하기 위해 개발 단계에선 `db-local`을 사용하도록 구성
- 두 `DB` 모두 컨테이너 내부에서는 `3306` 포트를 쓰지만, 외부 호스트로 노출할 때는 `3306(local)`과 `3307(prod)`로 분리하여 로컬에서 두 컨테이너에 동시 접속 가능
- **개발 중의 실수(예: DROP TABLE)가 운영 환경용 컨테이너 데이터에 영향을 주지 않도록 격리된 환경 구성**
3. **Healthcheck 와 의존성 제어** 
- 일반적인 `depends_on`은 컨테이너가 **'실행'**만 되면 다음 컨테이너 실행. 하지만 `DB`는 실행된 후 내부 엔진이 부팅되는 시간이 필요
- **healthcheck**: `mysqladmin ping`을 통해 `DB`가 진짜로 일할 준비가 되었는지 체크
- **condition(`service_healthy`)**: `DB`가 건강한 상태(`healthcheck` 를 통과할 경우)일 때만 `Spring App`가 실행되도록 순서 보장
4. **리소스 제한(`deploy.resources`)**
- 특정 컨테이너(`DB` 등)가 서버의 자원을 무한정 점유하지 못하도록 CPU 사용량은 50%, 메모리는 512MB 등으로 제한
5. **네트워크 격리 및 프록시 구성**
- `Nginx`: 외부 사용자는 80 포트(`Nginx`)로만 진입 가능
- `Expose`: `Spring App`은 외부로 포트를 직접 열지 않고(`expose: 8080`), 내부 네트워크(`backend-network`) <br>안에서 `Nginx`하고만 통신하도록 격리

![](/assets/img/2026-01-02/Docker_Setting(Spring)_4_img_3.webp)*[Docker Compose Healthcheck](https://medium.com/@saklani1408/configuring-healthcheck-in-docker-compose-3fa6439ee280)*

> 실제 실무에서는 `Kubernetes`나 `Cloud` 관리형 서비스를 사용하며, `GitHub Actions` 같은 도구로 배포를 자동화하므로 서버에서 직접 `Compose`를 만지는 일은 드뭅니다.

> 하지만 지금 작성한 설정은 실무 배포의 **'기본 틀'**이 됩니다. 여기서 정의한 네트워크 격리, 환경 변수 주입, 의존성 제어의 개념이 그대로 `CI/CD` 파이프라인의 테스트 환경과 클라우드 인프라 설정에 녹아들기 때문입니다. 즉, 이 설계도는 **실제 운영 환경을 구축하기 위한 가장 중요한 기초 공사**입니다.

> 따라서 개인 프로젝트임에도 환경 격리를 위한 `DB` 분리, `.env`를 활용한 보안 관리, `Healthcheck`를 통한 의존성 제어 등 실무적인 핵심 요소들을 최대한 반영하여 구성했습니다.

## 서비스 실행

이제 터미널에 딱 한 줄만 입력하면 됩니다.

```powershell
# 모든 서비스 빌드 및 백그라운드 실행
docker-compose up -d --build
# 잘 될까요...?
```

이 명령어 하나로 `Docker`는 다음 과정을 자동으로 수행합니다.

1. `db`, `redis` 이미지를 다운로드하고 설정된 리소스 제한에 맞춰 실행
2. `db-prod`가 완전히 준비(`Healthy`)될 때까지 대기
3. `app`의 `Dockerfile`을 읽어 `Multi-stage` 빌드 수행 후 실행
4. 최종적으로 `nginx`가 실행되어 외부 요청을 받을 준비 완료

## 하지만 아직 실행하면 안 됩니다!

지금까지 우리는 **보안·안정성·확장성**을 고려한 `docker-compose.yml`로 인프라 설계도를 완성했습니다.

하지만 **아직 실행하면 안 됩니다.** `docker-compose up`을 실행하면, 터미널에는 빨간색 에러 로그가 가득 찰 것입니다.

인프라(환경)는 준비했지만, 정작 그 안에서 실행되어야 할 `Spring Boot`(애플리케이션)에게는 아직 아무런 지침을 주지 않았기 때문입니다.

스프링은 여전히 `localhost`에서 `DB`를 찾고 있을 것이며(도커망에서는 `docker-compose.yml` 에서 선언된`db-prod`로 찾아야 합니다.), `.env`에서 넘겨준 환경 변수들을 스프링이 어떻게 받아야 하는지 모릅니다.

또한 우리가 설정한 `SPRING_PROFILES_ACTIVE: prod`가 구체적으로 어떤 설정인지, 브라우저에서 어떻게 `Spring` 으로 진입해야 하는지 모릅니다.

# What's next

엔진을 조립했으니, 이제 시동을 걸고 도로 위를 달릴 차례입니다.

- **`application.yml` 최적화**: 도커 네트워크 환경에 맞는 접속 설정
- **`Multi-Profile` 전략**: `local`과 `prod` 환경을 자유자재로 스위칭하는 법
- **`Error Debug`**: 컨테이너가 띄워지지 않을 때 로그를 확인하고 해결하는 실전 팁