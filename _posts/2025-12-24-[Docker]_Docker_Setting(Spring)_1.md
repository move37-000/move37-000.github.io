---
title: (Docker) Spring 배포 환경 구축기 - 1. 도커의 필요성과 WSL2 설치
date: 2025-12-26 00:00:00 +09:00
categories: [Docker, 개발환경]
tags: [Docker, WSL2, 개발환경]
description: Docker 와 개발환경
image: 
---

> 본 포스팅에서는 아래 내용에 대해 소개합니다.
> - 실무에서 도커가 '선택'이 아닌 '필수'가 된 이유
> - 도커의 핵심 개념(이미지, 컨테이너)과 설치 방법
> - (Windows) WSL2 & Docker Desktop 설치 가이드

## 어? 내 컴퓨터에선 잘 되는데?

개발자라면 무조건 겪는 끔찍한 순간이 있습니다. 내 **로컬(`PC`)** 에선 완벽하게 돌아가던 코드가 **서버**에만 올리면 `java` 버전이 다르다거나, 환경 변수가 꼬여서 에러가 나는 상황 말이죠. 이런 환경 불일치 문제는 개발자의 생산성을 저해하는 치명적인 원인이 됩니다.

> **도커(Docker)**는 이 문제를 '박스(`Container`)' 하나로 깔끔하게 해결해 줍니다.
{: .prompt-info }

**'애플리케이션과 실행에 필요한 모든 환경을 하나의 박스로 묶는다'**고 상상해 보세요. 서버의 `OS`가 무엇이든, 어떤 설정이 되어 있든 상관없습니다. 그 박스만 실행하면 내가 만든 프로그램이 어디서든 똑같이 돌아가니까요!

## 내가 도커를 적용하기로 결심한 이유

환경 제약이 까다로운 **SI/SM 프로젝트에서는 수동 배포 과정 중 발생하는 휴먼 에러(`Human Error`)**가 서비스 장애로 직결되기도 합니다. **"개발환경과 운영환경을 동일하게 만들 순 없을까?"**라는 고민이 자연스럽게 도커로 저를 이끌었습니다.

> 무엇보다, **"제발 한 번에 돌아가게 해주세요"** 라고 제 개인 프로젝트에까지 바라고 싶지 않았습니다......

## 붕어빵 틀(이미지)과 붕어빵(컨테이너)

도커를 처음 접하면 **이미지(`Image`)**와 **컨테이너(`Container`)**라는 용어가 가장 헷갈립니다. 여러 비유가 있지만, 역시 **붕어빵**만큼 한번에 와닿는 게 없었습니다.

### 1. 이미지(`Image`) = 붕어빵 틀
- 소스 코드, 라이브러리, 설정값 등 실행에 필요한 모든 것을 담은 **불변의 파일**입니다. 한 번 잘 만들어두면 절대 변하지 않기 때문에, 어디서든 동일한 환경을 복제할 수 있게 됩니다.

### 2. 컨테이너(`Container`) = 붕어빵
- 이미지라는 틀을 사용해 실제로 구워낸 **'실행체'**입니다. 독립된 공간이라서, 내 컴퓨터 안에 여러 개의 붕어빵(컨테이너)을 만들어도 서로 간섭하지 않습니다.

![](/assets/img/2025-12-26/Docker_Setting(Spring)_1_img_1.png)*[Docker and Container](https://stackoverflow.com/questions/23735149/what-is-the-difference-between-a-docker-image-and-a-container)*

## 설치하기 전에 - WSL2 설치(`Windows`)

도커를 설치하기 전, `Windows`라면 반드시 거쳐야 할 관문이 있습니다. **`WSL2`** 설치입니다.

- **`WSL2`?** : `Windows Subsystem for Linux 2`, **`Windows` 안에서 `Linux Kernel`을 직접 실행**할 수 있게 해줍니다.
- **왜 설치해야 하는지?** : 도커 컨테이너는 **`Linux Kernel`의 격리 기술(`namespaces`, `cgroups`)**을 기반으로 동작합니다. `Windows`는 `Linux`와 구조가 완전히 다르기 때문에 도커가 돌아갈 수 없습니다. `Windows` 위에 가상의 `Linux` 환경(`WSL2`)을 만들고, 도커가 그 위에서 구동될 수 있게 만드는 것입니다.

![](/assets/img/2025-12-26/Docker_Setting(Spring)_1_img_2.png)*[Docker and WSL2](https://forums.docker.com/t/is-there-a-pictorial-diagram-of-how-wsl-2-docker-docker-desktop-are-related/100071)*

> 윈도우라는 땅 위에 리눅스라는 **특수 포장도로(`WSL2`)**를 깔아, 그 길 위에서만 달리는 전용차인 **도커**가 움직일 수 있게 만드는 과정입니다.
{: .prompt-info }

### 1. `WSL2` 설치
`PowerShell`을 **관리자 권한**으로 실행한 후 아래 명령어를 입력합니다.
```powershell
wsl --install
# 설치가 완료되면 시스템 재부팅이 필요합니다.
```

> **가상화를 사용할 수 없습니다:** `BIOS` 설정에서 `Virtualization`(가상화) 옵션이 `Enabled`로 되어 있는지 확인 

이 명령어 하나로 `WSL2` 활성화, `Kernel` 업데이트, `Ubuntu` 설치까지 모두 자동으로 진행됩니다.

### 2. 설치 확인
터미널에서 최종 확인합니다.
```powershell
wsl -l -v
# 실행 결과
# NAME      STATE      VERSION
# Ubuntu    Running    2
```

> 만약 `Ubuntu`가 자동으로 설치되지 않았다면 `wsl --install -d Ubuntu` 명령어로 별도 설치

## Docker Desktop 설치 (`WSL2` 연동)

**[Docker 공식 홈페이지](https://www.docker.com/products/docker-desktop/){:target="_blank"}**에서 설치파일을 다운받아 실행합니다.

1. 설치 과정 중 `Use WSL2 instead of Hyper-V (recommended)` 체크박스가 나오면 반드시 ✅합니다.
   (지금까지 설치한 `WSL2` 를 `Docker` 의 베이스 엔진으로 사용)
2. 설치 완료 후 `Settings` → `General` 에서 해당 옵션이 켜져 있는지 확인합니다.
3. `Resources` → `WSL Integration` 메뉴에서 설치한 `Ubuntu`가 활성화되어 있는지 확인합니다.
4. 최종적으로 터미널에서 확인합니다.
```powershell
docker --version
# 출력 예 : Docker version 29.1.2, build 890dcca
docker run hello-world
# Hello from Docker! .... 라는 메세지가 보인다면 성공!
```

## What's next
- MySQL을 도커 컨테이너로 실행하기
- Volume 설정으로 데이터 영속성 보장하기(Volume)