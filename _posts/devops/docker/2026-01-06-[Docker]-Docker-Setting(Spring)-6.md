---
title: (Docker) Spring 배포 환경 구축기 - 6. Nginx 리버스 프록시와 최종 연결
date: 2026-01-06
categories: [Docker, 개발환경]
tags: [Docker, Nginx, Reverse Proxy, Load Balancing]
description: Nginx를 이용한 외부 통로 개방 및 Docker 배포 환경 완성
image: 
---

> 본 포스팅에서는 아래 내용에 대해 소개합니다.
> - **Nginx 리버스 프록시(`Reverse Proxy`)**의 개념과 도입 이유
> - `default.conf` 작성을 통한 `Nginx`와 스프링 컨테이너 연결 설정
> - `Docker Compose` 최종 구성 및 서비스 간 의존성(`depends_on`) 관리
> - **80 포트(HTTP)**를 통한 최종 접속 테스트 및 환경 구축 마무리

## 이제 밖으로 나갈 문을 만들 차례

지난 포스팅에서 우리는 `application-{profile}.yml` 설정을 통해 **스프링 부트가 도커 내부에서 다른 컨테이너와 통신할 수 있도록 이정표**를 세워주었습니다.

하지만 **현재 상태로는 브라우저에서 도커 스프링 서비스에 접속할 수 없습니다.** 스프링 컨테이너는 도커 내부 네트워크의 `8080` 포트에 숨어있기 때문입니다. 이제 이 앞단에 `Nginx`를 세워, 외부의 `80(HTTP)` 요청을 안전하게 스프링으로 전달하는 **리버스 프록시(`Reverse Proxy`)** 환경을 구성하겠습니다.

![](/assets/img/devops/docker/docker-setting-6/Docker_Setting(Spring)_6_img_1.png)*Nginx*

## Nginx 리버스 프록시?

**'내장 톰캣(`Embedded Tomcat`)이 있는데 왜 굳이 비슷한 `Nginx`를 앞에 또 두지?'** 라는 의문이 생기기 마련입니다. 결론부터 말씀드리면, `Nginx`는 톰캣과 하는 역할이 비슷해 보이지만, **서버의 앞단에서 훨씬 더 상세하고 전문적인 제어가 가능합니다.**

| 구분 | `Nginx (Web Server)` | `Tomcat (WAS)` |
| :--- | :--- | :--- |
| 주 역할 | 정적 콘텐츠 처리, 요청 전달(`Proxy`) | 동적 로직 실행 (`Java/Spring` 코드) |
| 강점 | **수만 개의 동시 접속을 가볍게 처리** | **복잡한 비즈니스 로직과 `DB` 연산 처리** |

### 요청 전달의 흐름(Step-by-Step)
1. 사용자가 브라우저에 `http://my-service.com`을 입력합니다. (기본 `80`번 포트로 요청이 전달됩니다.)
2. 도커 환경의 맨 앞에 서 있는 `Nginx`가 이 요청을 제일 먼저 받습니다. 이때 `Nginx`는 **'이 요청은 내가 직접 처리할 정적 파일(이미지, HTML)인가, 아니면 스프링한테 물어봐야 하는 로직인가?'**를 판단합니다.
3. 스프링의 도움이 필요하다고 판단되면, `Nginx`는 `proxy_pass` 설정에 따라 도커 내부 네트워크에 있는 **톰캣(`Spring`)**에게 요청을 던져줍니다.**(`Reverse Proxy`)**
4. 톰캣은 `Nginx`가 전달해 준 요청을 받아 `DB`를 조회하거나 비즈니스 로직을 수행한 뒤, 결과물을 다시 `Nginx`에게 돌려줍니다.
5. `Nginx`는 받은 결과물을 최종적으로 사용자에게 전달합니다.

![](/assets/img/devops/docker/docker-setting-6/Docker_Setting(Spring)_6_img_2.png)*[Nginx connection](https://hostingcanada.org/nginx-vs-apache-explained/)*

### 왜 이렇게 번거롭게(?) 전달하나요?

**그냥 톰캣을 바로 밖으로 노출(80 포트 직접 연결)해도 돌아는 갑니다.** 하지만 `Nginx`라는 완충 지대를 두면 다음과 같은 **강력한 이점**이 생깁니다.

- **무중단 배포의 핵심**: 스프링 컨테이너를 새로 띄울 때, `Nginx`가 **잠시 요청을 붙잡아두거나 새로 뜬 컨테이너로 스위치를 살짝 돌려줄 수 있습니다.** 사용자는 서버가 점검 중인지도 모르게 배포가 가능해지죠.
- **공격 방어**: 톰캣은 상대적으로 보안 공격에 취약할 수 있습니다. `Nginx`가 앞에서 이상한 요청(`DDoS`, 악성 스크립트 등)을 **1차적으로 걸러내는 방패 역할**을 합니다.
- **자원 절약**: 단순한 이미지나 `CSS` 파일은 톰캣까지 갈 필요도 없이 `Nginx`가 직접 빠르게 응답해 버립니다. **톰캣은 오직 '중요한 비즈니스 계산'에만 집중할 수 있게 됩니다.**

> `Nginx`는 마치 은행의 번호표 시스템처럼 **고객(요청)을 순서대로 빈 창구(스프링/톰캣)로 안내**합니다.
{: .prompt-info }

## Nginx 설정 파일(default.conf) 작성하기

이제 `Nginx`의 설정 파일을 작성해보겠습니다. 이 설정은 **외부에서 들어온 요청을 도커 네트워크 안의 스프링(`app`)으로 어떻게 전달할지**, 그리고 **전달할 때 어떤 정보를 함께 넘겨줄지**를 정의합니다.

프로젝트 루트 또는 설정된 경로에 `nginx/default.conf` 파일을 생성하고 아래 내용을 작성합니다.

```conf
server {
    listen 80;
    server_name localhost;

    client_max_body_size 10M;

    # API 및 동적 요청 처리 (Spring Boot 연결)
    location / {
        proxy_pass http://app:8080;

        # 클라이언트 실제 정보 전달
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # 타임아웃 설정
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    # 헬스체크 (모니터링용)
    location /health {
        access_log off;       
        return 200 'OK';      
    }

    # 에러 페이지 처리
    error_page 500 502 503 504 /50x.html;
    location = /50x.html {
        root /usr/share/nginx/html;
    }
}          
```

- **`proxy_pass http://app:8080;`**: 가장 중요한 부분입니다. `Nginx`는 도커 엔진 덕분에 **`app`이라는 이름만으로도 스프링 컨테이너의 `IP`를 찾아갈 수 있습니다.** 포트 역시 도커 내부망 포트인 `8080`을 사용합니다.
- **`client_max_body_size 10M;`**: **`Nginx`는 기본적으로 아주 작은 용량(`1M`)의 파일 업로드만 허용합니다.** 이미지 업로드 기능 등이 있다면 이 값을 적절히 늘려주어야 `413 Request Entity Too Large` 에러를 피할 수 있습니다.
- **`proxy_set_header`**: **리버스 프록시를 거치면 스프링 서버의 로그에는 모든 접속자가 `Nginx`의 `IP`(예: `172.19.0.X`)로 찍히게 됩니다.** 이를 방지하고 사용자의 실제 `IP`와 접속 환경을 전달하기 위해 반드시 설정해야 하는 옵션들입니다.
- **`proxy_read_timeout`**: 스프링에서 복잡한 쿼리를 수행하거나 외부 `API`를 호출하느라 응답이 늦어질 경우, **`Nginx`가 연결을 끊어버리지 않도록 넉넉하게(`60초`)** 잡아주었습니다.

## 실행 및 최종 테스트

드디어 명령어를 입력할 시간입니다.

```powershell
# 컨테이너 실행 (백그라운드 모드)
docker-compose up -d
```

![](/assets/img/devops/docker/docker-setting-6/Docker_Setting(Spring)_6_img_3.png)*docker-compose up -d*

```powershell
# 실행 상태 확인
docker ps
```

![](/assets/img/devops/docker/docker-setting-6/Docker_Setting(Spring)_6_img_4.png)*docker ps*

모든 컨테이너가 `UP` 상태라면, 브라우저를 열고 `http://localhost`에 접속해 봅니다.
> `Nginx`가 기본 포트인 80번 포트를 사용하므로 포트번호를 명시해줄 필요가 없습니다.

![](/assets/img/devops/docker/docker-setting-6/Docker_Setting(Spring)_6_img_5.png)*http://localhost*
> 이렇게 반가운 에러페이지는 처음입니다.

## 완료!

**지금까지 총 6개의 포스팅을 통해 다음을 달성했습니다.**

1. ✅ **Dockerfile & Multi-stage Build**
- 빌드 환경(`JDK`)과 실행 환경(`JRE`)을 분리하여 **컨테이너 크기를 최소화**하고, 보안에 불필요한 소스 코드를 배제하여 **효율적인 이미지 생성**
2. ✅ **Docker Compose & 인프라 제어**
- `depends_on`을 통해 **서비스 간의 실행 순서를 보장**하고, 단일 명령어로 `DB·Redis·App`을 하나의 가상 네트워크로 묶어 **유기적인 데이터 통신 환경 구성**
3. ✅ **.env & Multi-Profile**
- **민감 정보는 `.env`로 관리**하고, 스프링의 `profile` 기능을 통해 **코드 수정 없이도 유연한 로컬(`Local`)과 운영(`Prod`) 환경 변환**
4. ✅ **Nginx를 통한 리버스 프록시**
- **정적 파일의 캐싱 및 직접 처리를 전담**하여 톰캣의 부하를 줄이고, **보안 계층(`Reverse Proxy`)을 추가하여 시스템 전체의 응답 성능과 안정성 향상**

![](/assets/img/2026-01-06/Docker_Setting(Spring)_6_img_6.webp)*[Docker architecture](https://sudheer-baraker.medium.com/container-magic-understanding-docker-and-its-basic-concepts-3f90433cdea1)*

일련의 과정을 통해 단순히 **'서버를 띄웠다'**는 사실보다 더 중요한 것은, 이제 우리의 애플리케이션이 **'개발환경의 일관성'**를 갖게 되었다는 점입니다.

- **"어? 내 컴퓨터에선 잘 되는데?"**: **이제 이런 순간은 없습니다.**
- **유연한 스케일링**: 서비스 부하가 늘어나면 `docker-compose up --scale app=3` 같은 명령어로 서버를 손쉽게 늘릴 수 있는 토대를 마련했습니다.
- **로컬 환경의 깔끔함**: 내 컴퓨터에 직접 `MySQL`이나 `Redis`를 설치하고 지울 필요 없이, 오직 `docker-compose.yml` 하나로 프로젝트 환경을 구성할 수 있습니다.

## 마무리하며: 삽질하며 얻은 것들이 진짜 실력이다.

이 시리즈는 제가 처음 도커를 접하며 겪었던 **수많은 시행착오와 에러**들을 하나씩 수정하고 해결해 나가며 정리한 기록입니다.

사실 현업의 실제 운영 환경에서는 `GitHub Actions`이나 `Jenkins` 같은 자동화 툴이 **이 과정의 상당 부분을 대신해주고,** 대규모 서비스라면 `Kubernetes` 같은 더 복잡한 오케스트레이션 툴이 관리해 줍니다. **"실제로는 이렇게까지 일일이 수동으로 설정 안 해도 되는데?"라고 생각하실지도 모릅니다.**

하지만 저는 이런 **'불편한 기초 지식'**이야말로 개발자의 진짜 무기라고 생각합니다. 설정 파일의 줄 하나가 어떤 의미를 갖는지, 컨테이너들이 서로 어떻게 대화하는지를 직접 처음부터 구성해 본 경험이 있어야만, **나중에 자동화 툴을 쓰더라도 문제가 생겼을 때 당황하지 않고 원인을 찾아낼 수 있기 때문입니다.**

직접 환경을 구축해 보니 복잡하고 까다로운 부분도 많았지만, **그만큼 도커를 깊게 배울 수 있었고** 무엇보다 **제 로컬 개발 환경이 이전과는 비교할 수 없을 정도로 깔끔하고 편리**해졌습니다.

여러분도 이 과정을 통해 단순히 **'서버를 띄우는 법'**을 넘어, 나만의 **인프라를 설계하는 즐거움**을 느끼셨길 바랍니다.