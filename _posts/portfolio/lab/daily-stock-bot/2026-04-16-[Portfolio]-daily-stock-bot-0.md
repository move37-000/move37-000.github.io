---
title: Daily Stock Bot 리팩토링 - 0. 프로젝트 분석 및 설계
date: 2026-04-09
categories: [Python, Project]
tags: [python, refactoring, architecture, port-adapter, domain-model, dataclass]
image:
---

## Daily Stock Bot 리팩토링 #0 — 프로젝트 분석 및 설계

### 동기
매일 아침 한국장 개장 전에 미국/한국 시황을 수집하고, `AI` 분석 리포트를 생성해서 `Slack/Discord`로 보내는 봇을 만들었다. `yfinance, pykrx`로 데이터를 긁어오고, `Gemini API`로 시황 브리핑을 생성하며, `Jinja2`로 인터랙티브 `HTML` 리포트를 만드는 구조다.

동작은 한다. `GitHub Actions`로 매일 오전 7시에 돌아가고, `Slack`에 리포트가 온다. 그러나 잘 사용하던 중 `KRX(한국거래소)`가 비인증 크롤링을 차단하면서 `pykrx`로 한국 지수를 가져올 수 없게 되었고, `yfinance`로 우회하니 오전 7시 반에 전일 한국 지수가 누락되는 문제가 발생했다.

수정하려고 프로젝트를 다시 열었는데, **소스를 들여다보는 내내 기분이 좋지 않았다.**
`Python` 이 처음이고 여러 라이브러리를 처음 사용한다 쳐도 너무나 빈약한 아키텍쳐와 도메인 모델링, `Testable` 하지 못한 설계,
에러 전략의 세분화 등... **Python 이 처음이라서 나온 문제가 아니라 설계 사고방식의 문제점이 너무나 컸다.**

결국, **작동은 하지만 왜 이렇게 설계?** 라는 질문이 오면 난 하나도 대답하지 못 했을 것이다.

이번 리팩토링의 목표는 명확하다. **다른 사람이 내 코드를 보거나 코드 리뷰를 해도 군더더기가 없을 정도의 설계 품질**을 달성하는 것이다.

### 현재 프로젝트 개요

| 구분 | 기술                          |
| :--- |:----------------------------|
| `Language` | `Python 3.11+`               | 
| 미국 주식 | `yfinance`                    |
| 한국 주식 | `pykrx(현재 시점으로 yfinance)`     |
| AI 분석 | `Google Gemini API`           |
| 템플릿 | `Jinja2 + LightweightCharts`  |
| DB | `SQLite`                      |
| 자동화 | `GitHub Actions`              |
| 알림 | `Slack, Discord Webhook`      |

### 현재 프로젝트 구조
```
daily-stock-bot/
├── src/
│   ├── config.py              # 설정값 중앙 관리
│   ├── main.py                # 오케스트레이션
│   ├── crawler/               # 데이터 수집
│   │   ├── us_stock.py
│   │   ├── kr_stock.py
│   │   └── index_crawler.py
│   ├── repository/            # DB 저장
│   │   └── stock_repository.py
│   ├── service/               # 비즈니스 로직
│   │   ├── stock_service.py
│   │   ├── transformer.py
│   │   ├── report_service.py
│   │   ├── notification_service.py
│   │   └── ai_service.py
│   └── utils/
│       └── date_utils.py
├── templates/
│   └── report.html            # Jinja2 HTML 템플릿
├── requirements.txt
└── run.py
```

파일 수도 적고 규모도 작은 프로젝트다. **하지만 규모가 작다고 설계가 불필요한 건 아니다.**

## 문제 분석
이 프로젝트를 **개발 동료 또는 테크팀 리더가 5년차 Java 개발자의 사이드 프로젝트를 리뷰한다**는 관점에서 분석했다.

### 문제 1: dict 무한참조 — 타입 안전성 부재
**가장 근본적인 문제다.** 전체 데이터 흐름이 `dict[str, Any]`로 되어 있다.

```python
# 크롤러가 반환하는 것
{'symbol': 'NVDA', 'close': 135.5, 'change': 2.3, 'change_pct': 1.73, ...}

# 트랜스포머가 반환하는 것
{'symbol': 'NVDA', 'name': 'NVIDIA Corp', 'price': '135.50', 'change_pct': '+1.73', ...}
```

두 `dict`가 같은 `symbol` 키를 쓰지만 **담고 있는 의미가 다르다.** 크롤러의 `close`는 `float`인데, 트랜스포머 이후의 `price`는 포맷팅된 `str`이다. **이 차이를 아무도 보장하지 않는다.**

`Java`로 비유하면, **모든 메서드가 `Map<String, Object>`를 주고받는 것**과 같다. 컴파일러가 아무것도 잡아주지 못하고, 키 이름 오타는 런타임에 `KeyError`로 터진다.

실제로 이 구조 때문에 버그가 발생했다. `transformer.py`에서 한국 종목 데이터를 변환할 때:
```python
def _transform_kr_stock(stock):
    return {
        "symbol": stock['name'],    # 종목명이 symbol에
        "name": stock['code'],      # 종목코드가 name에
    }
```

`symbol`에 종목명이, `name`에 종목코드가 들어가는 **필드 역전 버그**가 있다. 화면에서는 어차피 `stock.symbol`을 제목으로 쓰고 있어서 동작은 하지만, 시맨틱이 완전히 반대다. 타입 시스템이 있었다면 IDE가 바로 잡아줬을 버그다.

### 문제 2: 절차적 스크립트 구조
`main.py`를 보면:

```python
def main():
    init_db()
    us_results = fetch_us_stocks(US_TICKERS)
    kr_results = fetch_kr_stocks(KR_TICKERS)
    us_index = fetch_us_index()
    kr_index = fetch_kr_index()
    usd_krw = fetch_usd_krw()
    us_market_news = fetch_us_market_news()
    kr_market_news = fetch_kr_market_news()
    save_stocks(us_results, kr_results)
    us_market, us_stocks = transform_us_data(us_results, us_index)
    kr_market, kr_stocks = transform_kr_data(kr_results, kr_index)
    ai_comment = generate_market_comment(...)
    generate_report(...)
    send_slack_message(...)
    send_discord_message(...)
```

패키지를 `crawler`, `service`, `repository`로 분리했지만, 실질적으로는 **함수를 위에서 아래로 순서대로 호출하는 스크립트**다. 이건 패키지 분리이지 아키텍처가 아니다.

더 큰 문제는, 크롤러 결과의 `dict` 구조를 서비스 레이어가 직접 알고 있다는 것이다. `us_results[0]['symbol']`, `stock['history']` 같은 `dict key`에 모든 레이어가 의존하고 있다. **인터페이스 없이 구현체끼리 직접 결합된 상태**다.

### 문제 3: 에러 무시에 가까운 에러 핸들링
에러를 `catch`하고 있긴 하지만, 모든 곳에서 하는 일이 동일하다:

```python
except Exception as e:
    logger.error(f"에러 메시지: {e}")
    continue  # 또는 return
```

이건 핸들링이 아니라 **에러 무시**다. 몇 가지 문제가 있다:
- **에러 종류를 구분하지 않는다.** 네트워크 에러(재시도하면 해결 가능)와 파싱 에러(`API` 구조 변경, 재시도 무의미)를 같은 방식으로 처리한다.
- **전부 실패해도 파이프라인이 계속 진행된다.** 크롤링이 3개 중 3개 다 실패하면, 빈 리스트로 리포트 생성까지 간다. `notification_service.py`의 `_prepare_notification_data()`에서 빈 리스트에 `max()`를 호출하면 `ValueError`로 터진다.
- **Slack 전송 실패 시 알 방법이 없다.** 알림 채널이 `Slack`인데, `Slack` 전송 자체가 실패하면 그 실패를 어떻게 알 수 있는가?

### 문제 4: 테스트 불가능한 구조
`README`에 `pytest`를 언급하고 `requirements`에도 포함되어 있지만, **테스트 파일이 하나도 없다.** 문제는 테스트를 안 짠 게 아니라, **못 짜는 구조**라는 점이다.
- 크롤러가 `yfinance`, `pykrx`를 직접 호출한다. `Mock`을 주입할 인터페이스가 없다.
- `datetime.now()`가 하드코딩되어 있어서 시간 의존 로직을 테스트할 수 없다.
- `stock_repository.py`가 모듈 레벨 상수로 `DB` 경로를 잡아서 테스트용 `in-memory DB`를 끼울 수 없다.

### 문제 5: 데이터 소스 교체의 어려움 (리팩토링의 직접적 계기)
`GitHub Actions`에서 오전 7시 반에 실행하면, **yfinance가 전일 한국 지수를 반환하지 않는 문제**가 있다. `Yahoo Finance` 쪽에서 한국 지수 수집이 늦은 것으로 추정되며, 이틀 전 지수가 최신 데이터로 나온다.

기존에 쓰던 `pykrx`로 돌아가려 했으나, **KRX(한국거래소)가 비인증 크롤링을 차단**하면서 더 이상 사용할 수 없게 되었다. 대안을 검토한 결과:

| 선택지 | 장점 | 단점 |
| :--- | :--- | :--- |
| `KRX Open API` | 공식, 안정적, 법적 리스크 없음 | `API` 키 필요, 호출 제한 |
| 네이버 금융 크롤링 | 빠름, 한국어 | 비공식, 구조 변경 시 깨짐 |
| 세션/토큰 우회 | 학습 가치 | 약관 위반, 유지보수 지옥 |

**KRX Open API를 메인으로, 네이버 금융을 폴백으로** 선택했다. 세션 우회 방법이 학습적으로 좋을 것으로 예상되지만, `KRX` 에서 `API` 를 공식적으로 제공하는데 **편법으로 데이터를 가져와선 안된다고 판단했다.**

그런데 현재 구조에서는 데이터 소스를 교체하려면 크롤러를 수정하고, 서비스 레이어에서 `dict` 키가 바뀌었는지 확인하고, 트랜스포머를 수정해야 한다. **데이터 소스 하나 바꾸는 데 연쇄적으로 여러 파일을 건드려야 하는 구조**다. 이것이 이번 리팩토링의 직접적인 계기가 되었다.

### 기타 문제

| 문제 | 설명 |
| :--- | :--- |
| 보안 | `config.py`에 `LOGO_API_TOKEN`이 하드코딩 |
| 미사용 코드 | SQLite에 저장만 하고 읽는 곳이 없음. `ai_service.py`에 `from ftplib import print_line` 미사용 `import` |
| 의존성 관리 | `requirements.txt`에 버전 미고정. `CI` 빌드마다 다른 버전이 설치될 수 있음 |

## 리팩토링 방향성

### 원칙
1. **한 번에 다 바꾸지 않는다.** `Phase`별로 진행하며, 각 `Phase`가 끝날 때마다 기존 기능이 동작하는지 확인한다.
2. **왜 이렇게 하는지를 설명할 수 있어야 한다.** 내가 만들었는데 내가 설명을 못 한다면, **그게 무슨 의미가 있는가?**
3. **실무와의 차이를 인식한다.** 이 프로젝트는 사이드 프로젝트이므로, 실무에서 했을 결정과 다른 부분이 있다면 그 이유를 명시한다.

### 로드맵
```
Phase 0: 프로젝트 분석 및 리팩토링 설계 (현재 글)
    │
    ▼
Phase 1: Domain Model(dict)
    - dict[str, Any] → dataclass 기반 도메인 모델
    - 크롤러와 서비스 레이어 간의 '계약' 확립
    - symbol/name 버그 같은 문제를 타입으로 원천 차단
    │
    ▼
Phase 2: Port/Adapter — 테스터블 아키텍처
    - Protocol(인터페이스) 도입, 의존성 주입
    - KRX 데이터 소스 교체 문제를 구조적으로 해결
    - FallbackIndexFetcher: 복합 어댑터 패턴 적용
    │
    ▼
Phase 3: Error Strategy
    - 커스텀 예외 계층 (NetworkError, ParseError, ...)
    - 재시도 vs 스킵 vs 중단 전략 분류
    - retry 데코레이터 구현
    │
    ▼
Phase 4: Tests
    - Phase 1 ~ 3의 구조 덕분에 테스트가 자연스러워지는 과정
    - Mock 없이는 불가했던 구조 → Protocol 덕분에 가능
    - fixture 설계, 엣지 케이스 커버리지
    │
    ▼
Phase 5: Cleanup — 운영 품질 확보
    - SQLite 제거, 보안 정리, 의존성 버전 고정, CI 정비
```

> 각 Phase를 완료할 때마다 블로그 글로 정리할 예정이다.

## 목표 프로젝트 구조
```
daily-stock-bot/
├── src/
│   ├── domain/                    # 도메인 모델 (Phase 1)
│   │   ├── stock.py               # StockSnapshot, DailyPrice
│   │   ├── market.py              # IndexSnapshot, MarketOverview
│   │   ├── news.py                # NewsItem
│   │   └── errors.py              # 커스텀 예외 계층 (Phase 3)
│   ├── port/                      # 인터페이스 (Phase 2)
│   │   ├── stock_fetcher.py       # StockFetcher Protocol
│   │   ├── index_fetcher.py       # IndexFetcher Protocol
│   │   ├── notifier.py            # Notifier Protocol
│   │   └── market_analyzer.py     # MarketAnalyzer Protocol
│   ├── adapter/                   # 구현체 (Phase 2)
│   │   ├── yfinance_fetcher.py    # 미국 주식 크롤러
│   │   ├── pykrx_fetcher.py       # 한국 주식 크롤러
│   │   ├── krx_api_fetcher.py     # KRX Open API (메인)
│   │   ├── naver_finance_fetcher.py # 네이버 금융 (폴백)
│   │   ├── fallback_fetcher.py    # 폴백 체인 복합 어댑터
│   │   ├── slack_notifier.py
│   │   ├── discord_notifier.py
│   │   └── gemini_analyzer.py
│   ├── service/                   # 비즈니스 로직
│   │   ├── transformer.py
│   │   └── report_service.py
│   ├── common/                    # 공통 유틸
│   │   ├── retry.py               # 재시도 데코레이터 (Phase 3)
│   │   └── date_utils.py
│   ├── config.py
│   └── main.py                    # 오케스트레이터 + 조립
├── templates/
│   └── report.html
├── tests/                         # Phase 4
│   ├── conftest.py                # 공통 fixture
│   ├── domain/
│   ├── adapter/
│   ├── service/
│   └── utils/
├── requirements.txt               # 버전 고정 (Phase 5)
└── README.md
```

### Before/After 핵심 변화

| 항목 | Before                   | After |
| :--- |:-------------------------| :--- |
| 데이터 전달 | `dict[str, Any]`         | `dataclass` 도메인 모델 |
| 외부 의존성 | 함수가 직접 호출                | `Protocol` 인터페이스로 분리 |
| 데이터 소스 교체 | 여러 파일 연쇄 수정              | 어댑터 하나 추가 |
| 에러 처리 | `except Exception + log` | 예외 계층 + 재시도/스킵/중단 분류 |
| 테스트 | 불가능한 구조                  | DI 덕분에 Mock 주입 가능 |
| `DB` | `SQLite` (사용하지 않는 코드)      | 제거 |
| 설정 | 토큰 하드코딩                  | 환경변수로 통일 |

## 핵심 설계 결정

### 왜 dataclass인가 (Pydantic이 아닌 이유)
`Pydantic`은 런타임 `validation`이 강력하지만, 이 프로젝트에서는 과하다. 외부 `API` 응답을 파싱하는 것이 아니라, **이미 파싱된 데이터를 내부적으로 전달**하는 용도이므로 표준 라이브러리인 `dataclass`로 충분하다

### 왜 Port/Adapter인가
`Java`에서 5년간 `Spring DI`를 써왔지만, `Python`에서는 `DI`를 어떻게 적용하는지 몰랐다. `Python`에는 `Spring` 같은 `DI 컨테이너`가 없지만, `Protocol`(`Java`의 `interface`에 해당)을 사용하면 동일한 효과를 얻을 수 있다.

더 중요한 이유는 **데이터 소스 교체 문제**다. `KRX API`를 메인으로, 네이버 금융을 폴백으로 구성하려면, 같은 인터페이스를 구현하는 여러 어댑터를 교체 가능하게 만들어야 한다. `Port/Adapter` 패턴이 정확히 이 문제를 해결한다.

```python
# 폴백 체인 — Port/Adapter의 실전 활용
kr_index_fetcher = FallbackIndexFetcher([
    KrxApiFetcher(api_key=KRX_API_KEY),      # 1순위: 공식 API
    NaverFinanceFetcher(),                     # 2순위: 네이버 금융
    YFinanceKrIndexFetcher(),                  # 3순위: 기존 코드 재활용
])
```

### 왜 SQLite를 제거하는가
현재 `save_stock_price()`로 저장은 하지만, **저장한 데이터를 읽는 곳이 없다.** `get_stock_history()`가 정의되어 있지만, `__init__.py`에서 주석 처리되어 있고 호출하는 코드가 없다. 리포트 생성 시 히스토리 데이터는 크롤러에서 직접 가져온 것을 사용한다.

**사용하지 않는 코드를 남겨두는 건 기술 부채다.** 나중에 히스토리 기능이 필요하면 그때 `Repository Protocol`을 먼저 정의하고 시작하면 된다.

## 이전 프로젝트와의 연결
이전 프로젝트(`order-transaction-lab`)에서는 **분산 환경에서의 트랜잭션 정합성**을 다뤘다. `Transactional Outbox`, `SAGA` 패턴 등 `Spring/Java` 의 설계 패턴을 학습했다.

이번 프로젝트는 관점이 다르다. 특정 기술 패턴이 아니라, **프로덕션 수준의 코드 설계란 무엇인가**를 `Python`이라는 다른 언어에서 실천하는 과정이다.

| `order-transaction-lab` | `Daily Stock Bot` 리팩토링 |
| :--- | :--- |
| `Java/Spring` 생태계 | `Python` 생태계 |
| 분산 트랜잭션 정합성 | 코드 설계 및 아키텍처 |
| `Outbox, SAGA` 등 특정 패턴 | `Domain Model, Port/Adapter, Error Strategy` 등 범용 설계 |
| `Phase`별로 문제를 겪고 해결 | `Phase`별로 구조를 개선하고 검증 |

두 프로젝트의 공통점은 **문제를 직접 겪고, 왜 이 해결책이 필요한지를 체감하는 방식**으로 진행한다는 것이다.

## What's Next

**Phase 1: Domain Model — dict 리팩토링**

- `dict[str, Any]`를 `dataclass` 기반 도메인 모델로 전환
- `StockSnapshot`, `IndexSnapshot`, `MarketOverview`, `NewsItem` 등 핵심 모델 정의
- 크롤러가 `dict` 대신 도메인 모델을 반환하도록 변경
- `transformer.py`의 `symbol/name` 버그가 타입 시스템으로 원천 차단되는 것을 확인