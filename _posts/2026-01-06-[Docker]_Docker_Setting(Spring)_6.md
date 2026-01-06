---
title: (Docker) Spring 배포 환경 구축기 - 6. Nginx 리버스 프록시와 최종 연결
date: 2026-01-06 00:00:00 +09:00
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



