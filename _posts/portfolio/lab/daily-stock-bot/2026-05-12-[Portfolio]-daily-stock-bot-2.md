---
title: Daily Stock Bot 리팩토링 - 2. 
date: 2026-05-12
categories: [Python, Project]
tags: [python, refactoring, hexagonal-architecture, port-adapter, protocol, dependency-injection]
image:
---

## Daily Stock Bot 리팩토링 #2-a

### 이번 Phase의 목표
`Phase 1`에서 정의한 도메인 모델을 **외부 의존성과 분리**한다. `yfinance`, `Gemini API`, `Slack/Discord webhook` 같은 외부 시스템을 직접 호출하는 코드 대신, `Port`(`Protocol`)에 의존하도록 전환한다.

`Phase 2`는 분량이 커서 세 편으로 나눈다.
- **2-a (이 글)**: `Port` 6개 + `DailyReport` 도메인 신설
- **2-b**: `Fetcher` 어댑터 4개 + 공통 헬퍼
- **2-c**: `Notifier`/`Analyzer` 어댑터 + `main.py` 조립 + 도메인 보정

## 시작하기 전에
`Phase 1`을 마치고 보니 발견된 것들을 정리한다.

### 1. `Phase 0` 로드맵의 한국 주식 어댑터 계획 폐기
원래 `Phase 2` 범위에 한국 주식 어댑터(`PykrxFetcher`, `KrxApiFetcher`, `NaverFinanceFetcher`, `FallbackIndexFetcher`)가 있었다. 하지만
- `pykrx`는 미사용 상태. 사용하지 않는 라이브러리를 위한 어댑터는 **존재할 필요가 없다.**
- `KRX Open API`는 아직 테스트하지 않았다. 내용물을 모르는데 포장지를 만드는건 **말이 안 된다.**

→ `Phase 2`는 **미국 파이프라인 전체 완성**으로 한정. 한국 어댑터는 `Phase 6`(KRX API) → `Phase 7`(KR 어댑터 추가)로 분리.

### 2. `Port` 개수가 4개에서 6개로 증가
`Phase 0` 로드맵은 `StockFetcher`, `IndexFetcher`, `Notifier`, `MarketAnalyzer` 4개를 계획했다. 도메인을 보니 환율(`ExchangeRate`)과 시장 뉴스가 `IndexFetcher`/`StockFetcher`와는 다른 별도 개념이었다. `ExchangeRateFetcher`, `MarketNewsFetcher`를 추가해 6개.

### **3. 도메인 인용은 `Phase 1` 기준**
`DailyPrice`는 `Phase 2` 어댑터 구현 중 `StockDaily`/`PricePoint`로 분리됐다. 이번 글은 `Port` 설계 시점이므로 도메인은 `Phase 1` 기준으로 작성, 보정 과정은 `2-b`에서 다룬다.

## Port / Adapter
원본은 서비스 레이어가 `yfinance`, `pykrx`, `requests.post()`, `genai.Client()`를 직접 호출했다.

```python
# 원본 us_stock.py
def fetch_us_stocks(tickers: list[str]) -> list[dict]:
    for symbol in tickers:
        ticker = yf.Ticker(symbol)              # yfinance 직접 의존
        history = ticker.history(period="5d")
        ...
```

문제 두 가지를 발견했다.
1. `yfinance` `mock`하려면 모듈 패치 필요. 네트워크 없이는 **테스트 자체가 불가능하다.**
2. 라이브러리를 바꾸면(또는 수정) **호출하는 모든 곳을 수정해야한다.**

해법은 의존성을 인터페이스로 격리하는 것이다.
```
[Service]  →  [Port: StockFetcher (Protocol)]  →  [Adapter: YFinanceFetcher]
                                               ↘  [Adapter: KrxApiFetcher (Phase 7)]
```

서비스는 `Port`만 안다. 어댑터 교체로 외부 소스 변경 가능.
> `Java/Spring`의 `Repository` 인터페이스 + `JpaRepository` 구현체 분리와 동일. 단, `Java`는 `implements` 명시 상속 필요, `Python`은 `Protocol`로 **구조적 서브타이핑**(duck typing) 사용.

## Protocol — 구조적 인터페이스
`Python 3.8+`의 `typing.Protocol`이 `Port`의 도구다.

```python
from typing import Protocol

class StockFetcher(Protocol):
    def fetch(self, tickers: dict[str, str]) -> list[StockSnapshot]:
        ...
```

```python
# 명시적 상속 없이도 StockFetcher 타입으로 인정
class YFinanceFetcher:
    def fetch(self, tickers: dict[str, str]) -> list[StockSnapshot]:
        ...
```

다만 이 프로젝트의 어댑터는 명시적으로 Port를 상속한다.

```python
class YFinanceFetcher(StockFetcher):    # 명시적 상속
    def fetch(self, tickers: dict[str, str]) -> list[StockSnapshot]:
        ...
```

- `Port` 시그니처를 어겼을 때 **에디터가 즉시 잡아준다**. 명시적으로 작성하지 않으면 런타임까지 발견이 미뤄진다.
- "이 클래스가 어떤 `Port`를 구현하는지" 한눈에 보인다.

`Protocol`의 구조적 특성은 **mock 작성 시 효과적이다**. 테스트에서 `class FakeStockFetcher:` 만들고 `fetch` 메서드만 정의하면 끝.
명시 상속 없이도 타입 체커가 허용한다.

## Port 6개

| Port | 시그니처 | 실패 전략 |
| :--- | :--- | :--- |
| `StockFetcher` | `fetch(tickers: dict[str, str]) -> list[StockSnapshot]` | 종목 단위 격리. 뉴스 실패는 `news=[]` |
| `IndexFetcher` | `fetch(symbol: str, name: str) -> IndexSnapshot` | 1개 단위 → 실패 시 예외 |
| `ExchangeRateFetcher` | `fetch() -> ExchangeRate` | 실패 시 예외 |
| `MarketNewsFetcher` | `fetch() -> list[NewsItem]` | 실패 시 `[]` 반환 (보조 정보) |
| `Notifier` | `send(report: DailyReport, report_url: str \| None) -> None` | 실패 시 예외 |
| `MarketAnalyzer` | `analyze(report: DailyReport) -> str` | 실패 시 예외 |

### `StockFetcher` — 뉴스 격리
원본은 종목 조회 도중 뉴스 `API` 실패 시 종목 자체가 실패로 끝났다. `Port` 규약에 "뉴스 실패는 `news=[]`로 격리"를 명시. 주식 정보는 살아있는데 뉴스 하나 때문에 주식 정보 전체가 빠지는 건 말이 안 된다고 생각했다.

입력 타입도 정리. 원본은 `list[str]`(심볼) + 별도 `US_STOCK_NAMES dict` 였지만, `dict[str, str]`(심볼 → 표시 이름)로 통합.

### `IndexFetcher` — 1개 단위
원본 `fetch_us_index()`는 SP500/NASDAQ 둘을 한 번에 반환. KOSPI 성공·KOSDAQ만 실패한 경우 묶음 단위로는 폴백 처리가 어색. `Port`를 1개 단위로 두면 `FallbackIndexFetcher`(`Phase 7`)가 지수별 독립 폴백 가능.

처음엔 `fetch(symbol: str)` 단일 인자로 설계했다. 하지만 `2-b` 어댑터 구현 단계에서 `IndexSnapshot`은 `name` 필드(예: `"S&P 500"`)를 요구하는데, 어댑터가 받는 건 심볼(`"^GSPC"`)뿐. 이 표시 이름을 어디서 얻어야 하는가?

| 안 | 표시 이름의 출처 |
|:--| :--- |
| A | 어댑터 내부에 `{"^GSPC": "S&P 500", ...}` 매핑 보유 |
| B | `IndexSnapshot.name` 필드 제거 |
| C | 호출측이 `(symbol, name)` 둘 다 전달 |

B는 고민하지도 않고 제외. A는 매핑이 어댑터마다 중복. C안 인`fetch(symbol: str, name: str)`으로 시그니처 수정.

`StockFetcher.fetch(tickers: dict[str, str])`가 심볼-이름 매핑을 받는 것과 같은 패턴. 

### `ExchangeRateFetcher` — `IndexFetcher`와 별도 분리
원본 `fetch_usd_krw()`는 내부적으로 `_fetch_single_index()`를 호출(지수와 동일 함수 재사용). `yfinance API` 입장에서 환율과 지수는 같은 엔드포인트지만 **도메인 레벨에선 별개 개념**. `IndexSnapshot`과 `ExchangeRate`가 별개 타입이라면 `Port`도 별개로 두는 게 맞다.

### `MarketNewsFetcher`
이 `Port` docstring은 처음엔 실패 전략 명시가 없었다. `2-c`에서 `YFinanceMarketNewsFetcher` 구현 중 "여기 실패는 어떻게 처리하지?"라는 질문이 생겨 docstring 보강. 시장 뉴스는 리포트 본체에 비해 보조 정보 → 실패 시 `[]` 반환이 자연스러움.

## DailyReport — 공용 입력 도메인 신설
`Notifier`와 `MarketAnalyzer`가 받는 `DailyReport`는 `Phase 1`에 없던 새 도메인.

```python
from dataclasses import dataclass
from datetime import date

from src.domain.market import ExchangeRate, MarketOverview
from src.domain.news import NewsItem
from src.domain.stock import StockSnapshot


@dataclass(frozen=True)
class DailyReport:
    """일일 주식 리포트 (알림·AI 분석·HTML 리포트 공통 입력)"""
    date: date
    us_stocks: list[StockSnapshot]
    us_market: MarketOverview
    exchange_rate: ExchangeRate
    us_news: list[NewsItem]
    analysis: str | None = None

    @property
    def us_up_count(self) -> int:
        return sum(1 for s in self.us_stocks if s.is_up)

    @property
    def us_down_count(self) -> int:
        return len(self.us_stocks) - self.us_up_count

    @property
    def top_gainer(self) -> StockSnapshot:
        return max(self.us_stocks, key=lambda s: s.change_pct)

    @property
    def top_loser(self) -> StockSnapshot:
        return min(self.us_stocks, key=lambda s: s.change_pct)
```

**"공용 번들" 성격**

`DailyReport`는 AI 분석 입력만이 아니라 **그날 수집된 시장 정보 전체 번들**. 사용처에 따라 일부 필드만 쓰는 게 정상.

| 사용처 | 활용 필드 |
| :--- | :--- |
| `GeminiAnalyzer` | `us_stocks`, `us_market`, `exchange_rate` (현재 `us_news` 미사용) |
| `SlackNotifier`/`DiscordNotifier` | `us_market`, `exchange_rate`, 집계 property |
| HTML 리포트 (별도 작업) | 전체 |

**시그니처 안정화**

원본 `send_slack_message(webhook_url, us_results, kr_results, us_market, kr_market, usd_krw, report_url)` — 파라미터 7개. 새 인자가 늘 때마다 모든 호출처 수정. `DailyReport` 단일 입력으로 통합하면 시그니처 안정.

**집계 property**

원본은 `notification_service.py`에서 `_prepare_notification_data()`가 상승/하락 카운트, top gainer/loser를 매번 계산. 어댑터별 중복. 도메인 property로 한 번 두면 `report.us_up_count` 한 줄로 접근.

**`top_gainer`의 빈 리스트 위험**

`us_stocks=[]`일 때 `max()`가 `ValueError`로 터진다. `StockFetcher`가 "모두 실패 시 예외"라 빈 리스트 도달 일은 정상 흐름에선 없지만, 도메인이 강제하지는 않음. `Phase 3`(`Error Strategy`)에서 검증 추가 검토.

## 디렉토리 구조

```
src/
├── domain/
│   ├── stock.py       # Market, DailyPrice, StockSnapshot
│   ├── news.py        # NewsItem
│   ├── market.py      # IndexSnapshot, MarketOverview, ExchangeRate
│   └── report.py      # DailyReport  ← Phase 2 신설
└── port/              # ← Phase 2 신설
    ├── stock_fetcher.py
    ├── index_fetcher.py
    ├── exchange_rate_fetcher.py
    ├── market_news_fetcher.py
    ├── notifier.py
    └── market_analyzer.py
```

`adapter/`는 다음 글(`2-b`)에서 추가.

## 결과 분석

| 항목 | Before | After |
| :--- | :--- | :--- |
| 외부 라이브러리 의존 | 서비스가 `yfinance` 직접 호출 | `Port`에만 의존 |
| 테스트 | 네트워크 필수 | mock 주입 가능 |
| 교체 비용 | 호출하는 모든 곳 수정 | 어댑터 교체로 끝 |
| 시그니처 안정성 | 인자 7~8개 누적 | `DailyReport` 단일 입력 |
| 집계 로직 위치 | 어댑터마다 반복 | 도메인 property |

## 이번 글에서 배운 것

1. **`Port` 설계는 처음부터 완벽할 수 없다**. `IndexFetcher.fetch` 시그니처 변경, `MarketNewsFetcher` docstring 보강. `Port`는 어댑터 구현과 함께 다듬어진다.
2. **`Port` 개수는 도메인이 결정한다**. `Phase 0`에서 4개로 추산했지만 도메인 검토 후 6개. `Phase 1`의 가치가 드러난 지점.
3. **`Protocol`은 명시적 상속과 구조적 서브타이핑을 모두 허용**. 어댑터는 명시적(에디터 지원), 테스트 mock은 구조적(작성 부담 적음).
4. **실패 전략은 `Port`별로 다르다**. 모두 "예외 전파"가 아님. 보조 정보 `Port`(`MarketNewsFetcher`, 뉴스 격리된 `StockFetcher`)는 격리. `Port` docstring에 명시.
5. **로드맵은 폐기될 수 있다**. `Phase 0`의 한국 어댑터 4개 계획을 `Phase 6/7`로 분리. "원본에 있었으니 옮긴다"는 논리가 자동 적용되지 않는다.

## What's Next

**`Phase 2-b`: Fetcher 어댑터 4개 + 공통 헬퍼**

- `YFinance` 계열 어댑터 4개 구현
- `_yfinance_common.py` 공통 헬퍼 추출
- 도메인 보정(`DailyPrice` → `StockDaily` 분리 + `PricePoint` 신설) — `Phase 1` 도메인 설계의 한계가 어댑터 구현 중 드러난 과정