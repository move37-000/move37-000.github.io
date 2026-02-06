---
title: (Docker) Spring 배포 환경 구축기 - 3. Spring Boot 애플리케이션 이미지 빌드 및 실행
date: 2025-12-30
categories: [Docker, 개발환경]
tags: [Docker, Spring Boot, Dockerfile, 배포]
description: Spring Boot 프로젝트를 Dockerfile로 이미지화하고 컨테이너로 실행하기
image: 
---

> 본 포스팅에서는 아래 내용에 대해 소개합니다.
> - `Spring Boot` 프로젝트를 실행 가능한 `JAR` 파일로 빌드하기
> - `Dockerfile`을 작성하여 `Spring` 애플리케이션 이미지 만들기
> - 생성한 이미지를 컨테이너로 실행하기
> - `Multi-stage Build`를 활용한 이미지 최적화 설정

## 도커 배포의 핵심: Dockerfile

지난 포스팅에서 `MySQL` 컨테이너를 띄워보았습니다. 이제 `Spring Boot`애플리케이션을 도커 위로 올릴 차례입니다. 이를 위해선 **'어떤 환경에서, 어떤 파일을, 어떻게 실행해라'** 라는 명세서가 필요한데, 이것이 바로 `Dockerfile`입니다.

![](/assets/img/devops/docker/docker-setting-3/Docker_Setting(Spring)_3_img_1.png)*[Docker Layers](https://docs.docker.com/build/cache/)*

### 1. Spring Boot 프로젝트 빌드 (JAR 생성)

먼저 도커 이미지에 넣을 실행 파일(`.jar`)을 만들어야 합니다. `Spring boot` 프로젝트 루트 경로에서 아래 명령어를 입력합니다. (`Gradle` 기준)

```powershell
# 빌드 수행 (테스트는 제외하고 빌드 속도를 높임)
./gradlew clean build -x test
```

빌드가 완료되면 `build/libs/` 폴더 안에 `-SNAPSHOT.jar` 파일이 생성된 것을 확인할 수 있습니다.

### 2. Dockerfile 작성하기

프로젝트의 최상단 경로(`build.gradle`이 있는 위치)에 확장자 없이 `Dockerfile`이라는 이름의 파일을 만들고 아래 내용을 입력합니다.

```Dockerfile
# 기본 실행 환경 설정
FROM eclipse-temurin:17-jdk

# 빌드된 JAR 파일을 컨테이너로 복사
ARG JAR_FILE=build/libs/*.jar
COPY ${JAR_FILE} app.jar

# 실행
ENTRYPOINT ["java", "-jar", "/app.jar"]
```

### 3. 이미지 빌드 및 실행

만들어진 `.jar` 파일과 `Dockerfile` 을 토대로 컨테이너를 실행합니다.

```powershell
# 이미지 빌드
docker build -t spring-basic .

# 컨테이너 실행
docker run -d -p 8080:8080 --name spring-app spring-basic

# 브라우저 주소창에 localhost:8080 으로 접속이 되면 성공!
```

자, 이제 Spring 을 이미지로 만들어, 컨테이너로 등록 후 실행까지 완료했습니다. 이제 Spring 의 소스가 수정될 때 마다 

1. `./gradlew clean build -x test` 로 수정된 소스를 `build` 하고
2. `build`가 완료되면 `docker build -t spring-basic .` 를 통해 이미지를 만든 다음
3. `docker run -d -p 8080:8080 --name spring-app spring-basic` 를 실행해 컨테이너를 실행하면 됩니다.

## 이 순서를 코드가 수정될 때 마다 실행해야 한다고...?

방금 과정을 따라오면서 느끼셨겠지만, 이 방식은 사용하기에 여러 불편함이 있습니다.

1. **반복되는 수동 작업**: 코드를 수정할 때마다 매번 로컬에서 빌드하고, 다시 도커를 빌드해야 합니다.
2. **거대한 이미지 용량**: 빌드 도구가 포함된 `JDK`를 통째로 실행 환경에 쓰기 때문에 이미지가 무겁습니다.
3. **보안 취약점**: 컨테이너가 기본적으로 `Root` 권한으로 실행되어 보안에 취약합니다.
4. **캐싱 미활용**: 코드 한 줄만 바꿔도 매번 무거운 `JAR` 파일을 통째로 다시 복사해야 합니다.

![](/assets/img/devops/docker/docker-setting-3/Docker_Setting(Spring)_3_img_2.png)*[Docker Layers Cache](https://docs.docker.com/build/cache/)*

> 이 모든걸 감내할 수 있다면, 그냥 사용하셔도 무방합니다. 하지만 `build` **속도** 때문에 답답할 겁니다.

## Dockerfile 개선하기 (Multi-stage Build)

이러한 비효율성은 `Multi-stage Build`를 통해 해결할 수 있습니다. `Dockerfile`을 개선해보겠습니다.

```powershell
# 1: Build Stage (애플리케이션 빌드)
# 빌드 도구가 포함된 무거운 이미지를 빌드 전용으로 사용
FROM eclipse-temurin:17-jdk-alpine AS build-stage

# 컨테이너 내 작업 디렉토리 설정
WORKDIR /build

# 레이어 캐싱 활용: 의존성 파일을 먼저 복사하여 소스 코드 변경 시 의존성 재다운로드 방지
COPY gradlew .
COPY gradle gradle
COPY build.gradle settings.gradle ./

# 실행 권한 부여 및 의존성 미리 다운로드(소스 코드 변경 시에도 이 단계는 캐싱됨)
RUN chmod +x ./gradlew
RUN ./gradlew dependencies --no-daemon

# 실제 소스 코드를 복사하고 JAR 파일 빌드
COPY src src
RUN ./gradlew clean build -x test --no-daemon

# 2: Run Stage (애플리케이션 실행)
# 실행 시에는 JDK가 아닌 가볍고 보안이 강화된 JRE 이미지만 사용
FROM eclipse-temurin:17-jre-alpine

# 실행 중 발생할 로그를 저장할 경로 설정
ENV LOG_DIR=/app/logs

# 보안을 위해 'appuser' 라는 일반 사용자 계정을 생성하여 실행(Root 권한 방지)
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

# 로그 디렉토리 생성
RUN mkdir -p ${LOG_DIR} && chown -R appuser:appgroup /app

# 빌드 단계(build-stage)에서 생성된 JAR 파일만 복사
# 빌드에 필요했던 불필요한 도구들을 제거하여 용량 최적화
# /app 폴더 전체(로그 폴더 포함)의 소유권을 appuser에게 부여
# 이 과정이 없으면 USER appuser 전환 후 로그 폴더에 파일을 쓸 수 없어 에러 발생
COPY --from=build-stage --chown=appuser:appgroup /build/build/libs/*-SNAPSHOT.jar /app/app.jar

# 일반 사용자 계정으로 전환
USER appuser

# 컨테이너 외부로 노출할 포트 명시
EXPOSE 8080

# 컨테이너 시작 시 실행될 명령어
# JVM 메모리 및 성능 최적화 옵션 적용
# 로그 경로를 시스템 프로퍼티로 전달하여 Spring Boot가 인식하게 설정
# "-Xmx512m": 최대 힙 메모리 512MB 제한
# "-XX:+UseContainerSupport": 컨테이너 환경 리소스 인식(Java 10 부터는 기본 활성화)
# "-jar": JAR 파일 실행 모드
# "-Dlogging.file.path=${LOG_DIR}": 로그 파일 저장 경로 지정
# "/app/app.jar": 실행할 JAR 파일 경로
ENTRYPOINT ["java", "-Xmx512m", "-XX:+UseContainerSupport", "-Dlogging.file.path=${LOG_DIR}", "-jar", "/app/app.jar"]
```

1. ✅ **`Multi-stage build`**: 빌드(`JDK`)와 실행(`JRE`) 단계를 나누어 최종 이미지 용량 최적화
2. ✅ **`Layer Caching`**: `build.gradle` 등을 소스코드보다 먼저 복사하여 라이브러리가 변하지 않았다면 빌드 시간이 수 초 이내로 단축
3. ✅ **보안(`Non-root User`)**: `appuser`를 생성해 실행함으로써 보안 피해 방지
4. ✅ **로그 디렉토리 및 권한 관리**: 
 - `ENV LOG_DIR=/app/logs`로 경로 변수화
 - `chown -R appuser:appgroup /app`을 통해 새로 만든 일반 사용자 계정이 이 폴더에 로그 파일을 쓸 수 있도록 소유권 부여
 > 이 설정이 없으면 `USER appuser`로 전환된 후 로그를 쓰려 할 때 `Permission Denied` 에러가 발생하며 서버가 띄워지지 않습니다.

 ![](/assets/img/devops/docker/docker-setting-3/Docker_Setting(Spring)_3_img_3.webp)*[Docker Multi-stage Build](https://labs.iximiuz.com/tutorials/docker-multi-stage-builds)*

> 이 `Dockerfile` 을 통해 이제 명령어 두 가지만 실행하면 됩니다!
 - **`docker build -t spring-basic .`**: 소스 빌드와 이미지 생성을 한 단계로 통합
 - **`docker run -d -p 8080:8080 --name spring-app spring-basic`**: 도커 실행
{: .prompt-info }

이제 우리의 **개발환경의 일관성**이 완성되었습니다. 기존 방식은 "내 PC에서는 빌드되는데, 도커 이미지는 왜 안 되지?" 같은 상황이 발생할 수 있었습니다.(내 PC의 `java` 버전과 도커의 `java` 버전이 다를 때 등).

하지만 개선된 방식은 **빌드 환경 자체도 도커 컨테이너 내부(`builder`)**로 고정되어 있기 때문에, 어느 PC에서 빌드하든 항상 동일한 결과물이 나옵니다. 

| 구분 | **Single-stage**(기존 방식) | **Multi-stage**(개선 방식) |
| --- | --- | --- |
| **필수 환경** | 내 PC에 `Java`, `Gradle` 설치 필수 | `Docker`만 설치되어 있으면 됨 |
| **빌드 과정** | `./gradlew build → docker build` | `docker build`(내부 자동 빌드) |
| **이미지 용량** | 상대적으로 무거움(JDK 포함) | **매우 가벼움(실행 전용 JRE 사용)** |
| **보안성** | Root 권한 실행(위험) | **일반 사용자 계정 사용(안전)** |
| **속도(캐싱)** | 매번 JAR 전체 복사 | **변경된 소스만 빌드(Layer 캐싱)** |

# What's next
지금까지 `Spring Boot` 애플리케이션을 `Docker` 컨테이너로 실행하는 방법을 구성해봤습니다. 하지만 이대로 서비스를 진행할수록 고민이 생깁니다.

- 데이터베이스(`MySQL`)는 애플리케이션과 어떻게 연결하죠?
- `Redis`캐시 서버도 필요한데(또는 다른 서버) 컨테이너를 또 띄워야 하나요?
- 명령어 두 줄 입력하는 것도 귀찮아졌어요.

이 모든 고민을 **파일 단 하나**로 끝낼 수 있습니다.