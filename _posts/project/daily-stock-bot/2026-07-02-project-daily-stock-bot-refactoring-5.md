---
title: "[Python Project Refactoring] 5. 리포트 출력과 마무리"
date: 2026-07-02
categories: [Project, Daily Stock Bot Refactoring]
tags: [python, refactoring, hexagonal-architecture, github-actions, jinja2, fail-fast]
---

## Daily Stock Bot 리팩토링 #5

### 이번 Phase의 목표
`Phase 4`까지 미국 파이프라인의 수집/조립/분석/알림은 갖춰졌지만, 출력물인 HTML 리포트가 없었다. 이번 `Phase`는 그 마지막 조각을 붙여 파이프라인을 마무리짓는다.

수집 → 조립 → 분석 → **HTML 생성** → 알림이 GitHub Actions 위에서 매일 무인으로 돈다. 리포트는 다른 어댑터와 달리 **Port 없이 모듈 함수로 두었고, 실패 정책도 알림과 반대로 잡았다.** 

### 시작하기 전에
`Phase 4`까지 미국 파이프라인은 완성됐고, 다음은 한국 시장(KRX) 어댑터를 붙여 Port/Adapter의 교체 가능성을 두 번째 데이터 소스로 검증할 차례였다. 그런데 토스증권 API가 등장하면서 계획이 바뀌었다. KR 데이터는 토스 API 기반의 별도 프로젝트로 분리하기로 하고, 이 프로젝트의 KRX 경로 자체를 폐기했다. 이 프로젝트는 데이터 소스가 `yfinance` 하나뿐인 채로 마무리 지으려고 한다.

애초에 `Phase 5`는 죽은 코드를 걷어내는 'Cleanup' 단계였다. 그러나 프로젝트를 애초에 신규 레포(`daily-stock-bot-lab`)로 처음부터 다시 만들어서, 걷어낼 cruft 자체가 존재하지 않았다. 그래서 `Phase 5`를 '리포트 출력 + 프로덕션 완성'으로 변경한다. 원본에 있던 HTML 리포트 출력과 GitHub Actions로 E2E 배포를 붙이고, 의존성 버전을 고정해 무인 배치의 재현성을 구현한다.

## Phase 4 → Phase 5 변경점
```
Phase 4: 수집 → 조립 → 분석 → 알림
Phase 5: 수집 → 조립 → 분석 → HTML 생성 → 알림
```

| 파일 | 변경                                          |
|:---|:--------------------------------------------|
| `adapter/html_report_generator.py` | 신설 — `build_view_model` + `generate_report` |
| `adapter/_yfinance_common.py` | `parse_price_history` 공통 사용                 |
| `adapter/yfinance_exchange_rate_fetcher.py` | `history` 복원                                |
| `adapter/yfinance_index_fetcher.py` | `parse_price_history` 사용                    |
| `domain/market.py` | `ExchangeRate.history` 추가                   |
| `config.py` | `^SOX` 제거, HTML 렌더용 상수 유지                   |
| `main.py` | HTML 생성 (알림 앞)                              |
| `requirements.txt` / `requirements-dev.txt` | `==` 정확 고정 + runtime/dev 분리                 |

##  HTML 리포트 어댑터

### 뷰모델 dict
`build_view_model(report: DailyReport) -> dict`은 도메인 객체를 템플릿이 원하는 dict 형태로 변환한다.

dict를 다시 쓰면 원본의 `dict[str, Any]` 지옥으로 돌아가는 것처럼 보이지만 원본의 문제는 dict 자체가 아니라, `yfinance`가 뱉은 dict가 크롤러/서비스/트랜스포머/알림까지 **전 계층을 그대로 흐른** 것이었다. 이 뷰모델 dict는 `build_view_model` 밖으로 나가지 않는다. 어댑터 경계 안에서만 존재한다.

> 도메인 필드명이 바뀌어도 템플릿(HTML)까지 전파되지 않는다.

변환은 타입별 헬퍼로 쪼갰다. `_stock_view`·`_index_view`·`_exchange_view`·`_market_view`가 각자의 도메인 타입을 담당하고, `build_view_model`은 이들을 조립해 템플릿 형태(`us_market`/`us_stocks`/`us_market_news`/`usd_krw`/`ai_comment`)에 1:1로 맞춘다.

헬퍼에서 실제로 하는 일은 두 종류다. 
1. 타입 형태를 템플릿이 읽는 모양으로 정규화한다. 지수/환율의 `history`는 `PricePoint`라 이미 `{date, price}` 구조지만, 종목의 `history`는 `StockDaily`(OHLCV)라 그대로는 차트 JS(`d.price`)가 못 읽는다.
```python
"history": [{"date": d.date, "price": d.close} for d in stock.history],
```
2. 도메인 어휘를 템플릿 어휘로 옮긴다. 도메인의 `MarketOverview`는 지수를 `primary`/`secondary`로 부르지만 템플릿은 구체적인 `sp500`/`nasdaq`을 필요로 한다.
```python
"sp500": _index_view(market.primary),
"nasdaq": _index_view(market.secondary),
```

`logo`처럼 도메인에 아예 없는 값도 여기서 조립한다. 도메인은 종목의 `symbol`만 알고, 로고 URL은 `US_STOCK_DOMAINS` 매핑과 logo.dev 토큰으로 어댑터가 만든다. 표현에만 필요한 데이터를 도메인에 넣을 필요는 없다.

## 설계에서 달라진 점

### 리포트는 Port를 두지 않았다
`Notifier`와 `MarketAnalyzer`는 Port를 두고 어댑터를 뒤에 세웠다. 그런데 HTML 리포트 생성은 Port 없이 `adapter/html_report_generator.py`의 모듈 함수 `generate_report(report: DailyReport) -> str`로 구현했다.

**일부러 만든 비대칭이다.**  HTML 렌더러는 구현이 하나뿐이고, KR을 사용하지 않음으로써 교체 가능성도 사라졌다. 출력 대상 역시 로컬 파일 하나뿐이다.  `Java`로 치면 구현 클래스가 하나뿐인데 `interface`부터 뽑아두는 것과 같다.

> 이 부분을 설계하면서 고민을 많이 했다. 그 고민의 과정과 결과를 다음 블로그 포스팅에 작성하기로 했다.

### HTML은 all-or-nothing, 알림은 best-effort
다른 어댑터는 외부 예외를 `NetworkError`/`ParseError`/`ApiResponseError`로 번역해 호출측에 넘긴다. `generate_report`는 그러지 않는다. 예외를 `AdapterError`로 감싸지 않고 그대로 전파한다.

리포트 생성이 실패하는 경우는 대부분 코드 자체의 버그다. 뷰모델과 템플릿의 키가 어긋났거나(`TemplateError`), 변환 로직이 틀렸거나 하는 종류다. 재시도한다고 풀리지 않고 어제 되던 게 오늘 네트워크 때문에 깨지는 실패도 아니다. 이러한 에러는 안 잡고 트레이스백째 죽는 게 맞고, 이 예외는 `main.py`의 `except AdapterError`를 그대로 통과해 프로세스를 비정상 종료(exit != 0)시킨다.

> 이런 버그를 `AdapterError`로 감싸면 코드 버그가 인프라 장애로 위장돼 디버깅이 더 어려워진다.

배치 순서도 같은 판단의 연장이다. 파이프라인은 수집 → 조립 → 분석 → **HTML 생성** → 알림 순서다. HTML을 알림 뒤에 두면 리포트가 깨져도 알림이 먼저 나가 링크가 깨진 리포트를 가리킨다. 

결과적으로 두 출력의 실패 정책이 대비를 이룬다. 알림은 채널별 best-effort로, Slack이 죽어도 Discord는 나간다. HTML은 all-or-nothing으로, 깨지면 전체가 멈춘다. 

> '무엇이 필수(리포트)이고 무엇이 부분 허용(알림 채널)인가' 의 중요한 판단이다.

### `ExchangeRate.history` 복원과 `parse_price_history` 공통 사용
원본의 `_fetch_single_index`는 지수와 환율에 공용으로 쓰이던 함수라, 환율에도 스파크라인용 종가 시계열(`history`)이 딸려 있었다. 리팩토링 과정에서 이 `history`가 `IndexSnapshot`에는 남고 `ExchangeRate`에서는 누락됐다. AI 프롬프트 작성 중 이 부분을 발견했고 `Phase 5`에서 `ExchangeRate`에 `history: list[PricePoint]`를 다시 추가했다.

복원하면서 지수 어댑터의 private `_parse_history`(DataFrame → `list[PricePoint]`)를 `_yfinance_common.parse_price_history`로 변경했다. 비록 두 번 밖에 사용되지 않지만 KR 미사용 확정으로 다음 사용 부분까지 기다리는건 무의미하며 `calculate_change`와 같은 수준의 순수 파싱 헬퍼라 되돌리기 비용도 없다. 

> 되돌리기 비용이 큰 구조적 추상인 Port에서는 공통 사용으로 변경하지 않았을 것이다.

> 이 작업으로 `ExchangeRate`의 구조가 `IndexSnapshot`과 거의 같아졌지만 지수와 환율은 의미가 다르므로 통합하지 않는다. 

## 결과
GitHub Actions이 매일 오전 7시(KST)에 파이프라인을 자동 실행한다. 수집부터 알림까지 순서대로 돌고, `reports/report_{date}.html`을 생성해 커밋한 뒤 최신본을 `docs/index.html`로 복사해 GitHub Pages로 배포한다.

### 실제 실행 로그


## What's Next
다음 편은 시리즈의 마지막, 회고다.

이 프로젝트는 데이터 소스가 `yfinance` 하나뿐인 채로 끝났다. 원래 Port/Adapter의 교체 가능성은 두 번째 데이터 소스(KRX)로 검증할 계획이었으나 그 계획이 폐기되면서, Port/Adapter 교체 가능성은 검증되지 못했다. 

출력에서도 알림은 Slack/Discord 두 구현으로 교체 가능성을 보였지만, 리포트는 오히려 'Port를 두지 않는 게 맞다'는 반대 결과도 발생했다.

그렇다면 교체 가능성이 (반드시)존재하지 않을 때, hexagonal architecture는 좋은 구조인가? 이 구조가 준 것과 그 대가는 무엇이었는가?
