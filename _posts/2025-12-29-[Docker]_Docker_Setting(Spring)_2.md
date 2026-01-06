---
title: (Docker) Spring 배포 환경 구축기 - 2. Docker로 MySQL 띄우기 (Volume 설정)
date: 2025-12-29 00:00:00 +09:00
categories: [Docker, 개발환경]
tags: [Docker, MySQL, Volume]
description: Docker를 이용한 MySQL 설치와 데이터 보존 방법
image: 
---

> 본 포스팅에서는 아래 내용에 대해 소개합니다.
> - `Docker`를 이용해 `MySQL` 서버 구축하기
> - **컨테이너가 삭제되어도 데이터가 사라지지 않게 하는 Volume(볼륨)** 설정
> - 데이터 영속성 테스트 (삭제 후 복구 확인)
> - `MySQL` 컨테이너 접속 및 테스트

## 왜 데이터베이스를 도커로 띄우는가?

지난 포스팅에서 도커의 핵심은 **개발환경의 일관성**이라고 말씀드렸습니다. `DB`를 내 로컬 환경에 직접 설치(`Native`)하면 지우기도 까다롭고, 여러 버전을 테스트하기도 어렵습니다. 하지만 도커를 사용하면 명령어 한 줄로 `DB`를 띄우고, 마음에 안 들면 명령어 한 줄로 지울 수 있습니다.

## MySQL 이미지 다운로드 및 컨테이너 실행

터미널(`PowerShell` 또는 `CMD`)을 열고 아래 명령어를 입력합니다.

```powershell
docker run -d `
>> --name spring-mysql `
>> -e MYSQL_ROOT_PASSWORD=1234 `
>> -e MYSQL_DATABASE=mydb ` # DB 이름 지정
>> -p 3306:3306 `
>> mysql:8.0                # 사용할 이미지명
```
- `-d`: 백그라운드에서 실행 (데몬 모드)
- `--name`: 컨테이너의 이름 설정
- `-e`: 환경 변수 설정 (루트 비밀번호 및 초기 DB 생성)
- `-p`: 호스트 포트 3306과 컨테이너 포트 3306을 연결 **(포트 포워딩)**

> **`3306` 포트가 이미 사용 중이라면(`Bind Address Error`)**
- 호스트(왼쪽) 포트 번호 변경(`-p 3307:3306`)
- 외부(`DBeaver` 등)에서는 `3307`로 접속하고, 컨테이너 내부 `MySQL`은 원래대로 `3306`으로 동작

![](/assets/img/2025-12-29/Docker_Setting(Spring)_2_img_1.webp)*[Docker HTTP Routing](https://docs.docker.com/guides/traefik/)*

> **포트 포워딩:** 외부(내 `PC`)에서 컨테이너 내부의 서비스에 접속할 수 있도록 **특정 포트끼리 연결해주는 '입구'**의 개념(자세한 네트워크 원리는 추후 `docker-compose.yml` 에서 다룰 예정)

## 그런데, 컨테이너를 삭제하면 데이터는?

여기서 중요한 문제가 발생합니다. 도커 컨테이너는 **휘발성**입니다. 컨테이너를 삭제(`docker rm`)하면 그 안에서 생성했던 데이터베이스와 테이블도 모두 함께 사라집니다. 실제 운영 환경에서 이런 일이 발생한다면 재앙이겠죠?

![](/assets/img/2025-12-29/Docker_Setting(Spring)_2_img_2.webp)*[Docker Container and layers](https://docs.docker.com/engine/storage/drivers/)*

> 그래서 필요한 것이 바로 **Volume(볼륨)** 설정입니다.
{: .prompt-info }

도커 볼륨은 컨테이너 내부의 데이터 저장 경로를 내 `PC`(호스트)의 특정 폴더와 연결합니다. 이렇게 하면 컨테이너가 삭제되어도 데이터는 내 `PC`에 안전하게 남아있게 됩니다.

## Named Volume vs Bind Mount

도커에서 데이터를 저장하는 방식은 크게 두 가지가 있습니다.

### 1. Named Volume
- `mysql_data`: `/var/lib/mysql` 처럼 이름을 붙여서 관리
- 도커가 내 PC 안의 특정 관리 영역(보통 `/var/lib/docker/volumes/`)에 자동으로 저장 공간을 만듭니다. 사용자는 실제 경로가 어디인지 신경 쓸 필요가 없으며, 도커가 관리하기 때문에 **가장 안전하고 권장되는 방식**입니다.

### 2. Bind Mount
- `C:\Users\Project\db_data:/var/lib/mysql` 처럼 내 PC의 **실제 특정 폴더 경로**를 직접 연결
- 내 눈에 보이는 폴더와 바로 동기화되므로 설정 파일을 실시간으로 수정하고 반영할 때 편리합니다. 하지만 OS마다 경로 형식이 다르고, 실수로 로컬 폴더를 지우면 데이터도 사라질 위험이 있습니다.

![](/assets/img/2025-12-29/Docker_Setting(Spring)_2_img_3.png)*[Docker Use bind mounts](https://docker-docs.uclv.cu/storage/bind-mounts/)*

> 데이터 관리의 주도권을 **도커**에게 맡기고 싶다면 **Named Volume**, 내 로컬 폴더와 직접 동기화하여 자유롭게 파일을 다루고 싶다면 **Bind Mount**
{: .prompt-info }

## Named Volume 방식을 적용하여 다시 실행하기

기존 컨테이너를 멈추고 삭제한 뒤 볼륨 옵션(`-v`)을 추가하여 다시 실행해 보겠습니다.

```powershell
# 1. 기존 컨테이너 중지 및 삭제
docker stop spring-mysql
docker rm spring-mysql  

# 2. 볼륨을 설정하여 재실행
docker run -d `
>> --name spring-mysql `
>> -e MYSQL_ROOT_PASSWORD=1234 `
>> -e MYSQL_DATABASE=mydb `
>> -p 3306:3306 `
>> -v mysql_data:/var/lib/mysql `
>> mysql:8.0
```

- `-v mysql_data:/var/lib/mysql`: `mysql_data`라는 이름의 도커 볼륨을 `MySQL`의 실제 데이터 저장 경로인 `/var/lib/mysql`에 마운트합니다. 이제 컨테이너를 지웠다 다시 깔아도 데이터는 그대로 유지됩니다.

> `docker rm`은 **컨테이너만** 삭제하는 명령어 입니다. 데이터는 볼륨에 저장되어 있으며, 볼륨은 직접 삭제 명령을 내리기 전까지는 영구적으로 보존됩니다.

## 생성된 볼륨 확인하기

볼륨이 실제로 도커 시스템에 생성되었는지 확인해보겠습니다.

```powershell
# 생성된 모든 볼륨 목록 보기
docker volume ls

# 특정 볼륨의 상세 정보(저장 경로 등) 확인
docker volume inspect mysql_data
```

`inspect` 결과 중 `Mountpoint`를 보면 내 PC 의 어느 물리적 위치에 데이터가 저장되는지 알 수 있습니다.

## 진짜 데이터가 안 지워질까?

컨테이너를 삭제해도 데이터가 남는지 테스트를 해보겠습니다.

### 1. 테스트 테이블 생성
```powershell
# 컨테이너 접속
docker exec -it spring-mysql mysql -u root -p

# GUI 툴(DBeaver, MySQL Workbench 등) 으로 사용해도 무방
use mydb;
CREATE TABLE persistence_test (id INT, name VARCHAR(20));
INSERT INTO persistence_test VALUES (1, 'Docker-Volume-Test');
SELECT * FROM persistence_test;
exit;
```

### 2. 컨테이너 삭제 후 재생성
```powershell
# 컨테이너 삭제
docker rm -f spring-mysql

# 아까와 동일한 볼륨(-v mysql_data:...) 옵션으로 다시 실행
docker run -d `
>> --name spring-mysql `
>> -e MYSQL_ROOT_PASSWORD=1234 `
>> -e MYSQL_DATABASE=mydb `
>> -p 3306:3306 `
>> -v mysql_data:/var/lib/mysql `
>> mysql:8.0
```

### 3. 데이터 확인
```powershell
# GUI 툴(DBeaver, MySQL Workbench 등) 으로 사용해도 무방
docker exec -it spring-mysql mysql -u root -p -e "SELECT * FROM mydb.persistence_test;"

# Docker-Volume-Test 의 row data 가 조회된다면 성공!
```

## What's next
DB 환경이 준비되었으니, 이제 프로젝트의 주인공을 올릴 차례입니다.
- `Spring Boot` 프로젝트 `Dockerfile` 작성하기
- `Spring` 애플리케이션 이미지 빌드 및 실행