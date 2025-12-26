---
title: (Docker) Spring 배포 환경 구축기 - 1. 도커의 필요성과 WSL2 설치
date: 2025-12-26 00:00:00 +09:00
categories: [Docker, 개발환경]
tags: [Docker, WSL2, 개발환경]
image: 
---

> 본 포스팅에서는 아래 내용에 대해 소개합니다.
> - 실무에서 왜 도커(Docker)를 필수적으로 사용하는지
> - 도커의 핵심 개념(이미지, 컨테이너)과 설치 방법
> - 도커 설치해보기

## 왜 도커(Docker)인가? 

개발을 하며 가장 난감한 상황이 있다. **"어? 내 컴퓨터에서는 잘 되는데, 왜 서버(운영 환경)에선 안 되지?"** 자바 버전 차이, 환경 변수 누락, DB 설정 오류 등 이런 고질적인 문제는 이런 고질적인 문제는 개발자의 생산성을 갉아먹는다. 

> 도커는 이 문제를 **박스(Container)** 하나로 해결한다.
{: .prompt-info }

내 컴퓨터의 개발 환경을 그대로 박스에 담아서 서버로 옮긴다고 상상해 보자. 서버가 어떤 상태든 상관없이 그 박스만 실행하면 내가 만든 프로그램이 똑같이 돌아간다. 매우 편리하지 않은가?

## 그래서 난 왜 도커를 적용하는가?

SI/SM(공공기관) 프로젝트를 수행하며 배포 때마다 수동으로 파일을 옮기고 설정하는 과정에서 Human Error가 빈번하게 발생했다. **"내 컴퓨터의 환경 자체를 박제해서 그대로 올릴 순 없을까?"** 라는 고민 끝에 도커를 시도하게 되었다.

## 도커의 핵심 개념: 붕어빵 틀과 붕어빵

도커 관련하여 블로그나 AI 등 매우 많은 정보를 찾아보았다. 그 중 가장 많은 비유로 '붕어빵 틀' 과 '붕어빵' 이다. 내가 생각해도 이 비유가 가장 적절한 것 같다. 무엇보다, 이해가 쉬웠다.

도커를 시작할 때 가장 헷갈리는 것이 **이미지(Image)**와 **컨테이너(Container)**의 차이이다.

1. **이미지 (Image): 붕어빵 틀 혹은 설계도**

서비스 운영에 필요한 프로그램, 라이브러리, 소스 코드를 모두 포함한 '상태'를 스냅샷 찍어놓은 것이다. 이미지는 한 번 만들어지면 절대 변하지 않으며(Immutable), 덕분에 우리는 언제 어디서든 동일한 환경을 복제할 수 있다.

2. **컨테이너 (Container): 붕어빵 혹은 실제 건물**

이미지를 실행시킨 '실체'. 각각의 컨테이너는 독립된 공간이다. 하나의 서버(또는 내 컴퓨터)에서 MySQL 컨테이너 2개를 띄워도 서로 간섭하지 않는다. 마치 내 컴퓨터 안에 작은 가상 컴퓨터가 여러 개 떠 있는 것과 비슷하다.

![](/assets/img/2025-12-26/Docker Setting(Spring) _1_img_1.png)*[Docker and Container](https://stackoverflow.com/questions/23735149/what-is-the-difference-between-a-docker-image-and-a-container)*

## 설치하기 전에 - WSL2 설치(Windows)

도커를 설치하기 전, Windows라면 반드시 거쳐야 할 관문이 있다. WSL2 설치이다.

- **WSL2?** : Windows Subsystem for Linux 2의 약자로, **Windows 안에서 리눅스 커널을 직접 실행**할 수 있게 해준다.
- **왜 설치해야 하는지?** : 도커 컨테이너는 **리눅스 커널의 격리 기술(namespaces, cgroups)**을 기반으로 동작한다. Windows는 리눅스와 구조가 완전히 다르기 때문에 도커가 돌아갈 수 없다. 그래서 Windows 위에 가상의 리눅스 환경(WSL2)을 만들고, 도커가 그 위에서 구동될 수 있게 만드는 것이다.

![](/assets/img/2025-12-26/Docker Setting(Spring) _1_img_2.png)*[Docker and WSL2](https://forums.docker.com/t/is-there-a-pictorial-diagram-of-how-wsl-2-docker-docker-desktop-are-related/100071)*

> 쉽게 말해, 도커라는 **앱**을 돌리기 위해 리눅스라는 **운영체제(OS)**를 Windows 안에 작게 하나 더 설치하는 과정이다.
{: .prompt-info }

1. **WSL2 설치**
<br>PowerShell을 **관리자 권한**으로 실행한 후 아래 명령어를 입력한다.
```powershell
wsl --install
# 설치가 완료되면 시스템 재부팅이 필요하다.
```

> **가상화를 사용할 수 없습니다** 오류 발생 시 BIOS 설정에서 Virtualization(가상화) 옵션이 Enabled로 되어 있는지 확인한다. 
{: .prompt-warning }

이 명령어 하나로 WSL2 활성화, 커널 업데이트, Ubuntu 설치까지 모두 자동으로 진행된다.

2. **설치 확인**
<br>터미널에서 최종 확인을 해본다.
```powershell
wsl -l -v
# 실행 결과
# NAME      STATE      VERSION
# Ubuntu    Running    2
```

> 만약 Ubuntu가 자동으로 설치되지 않았다면, `wsl --install -d Ubuntu` 명령어로 별도 설치한다.
{: .prompt-tip }

## Docker Desktop 설치 (WSL2 연동)
**[Docker 공식 홈페이지](https://www.docker.com/products/docker-desktop/){:target="_blank"}**에서 설치파일을 다운받아 실행한다.

1. 설치 과정 중 `Use the WSL 2 based engine (recommended)` 체크박스가 나오면 반드시 체크한다.
   (지금까지 설치한 WSL2 를 Docker 의 베이스 엔진으로 사용)

2. 설치 완료 후 `Settings` -> `General` 에서 해당 옵션이 켜져 있는지 확인한다.

3. `Resources` -> `WSL Integration` 메뉴에서 설치한 Ubuntu가 활성화되어 있는지 확인한다.

4. 최종적으로 터미널에서 확인해본다.
```powershell
docker --version
# 출력 예 : Docker version 29.1.2, build 890dcca
docker run hello-world
# Hello from Docker! .... 라는 메세지가 보인다면 성공!
```

# What's next
다음 포스팅에서는:
- MySQL을 도커 컨테이너로 실행하기
- Volume 설정으로 데이터 영속성 보장하기