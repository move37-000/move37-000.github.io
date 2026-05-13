---
title: Daily Stock Bot 리팩토링 - 2-b. Fetcher 어댑터
date: 2026-05-13
categories: [Python, Project]
tags: [python, refactoring, hexagonal-architecture, adapter, yfinance, pandas, rule-of-three]
image:
---

## Daily Stock Bot 리팩토링 #2-b

### 이번 Phase의 목표
`Phase 2-a`에서 정의한 6개 `Port` 중 **4개 `Fetcher`의 어댑터를 구현**한다.

- `YFinanceFetcher` — 미국 종목 시세 + 종목 뉴스
- `YFinanceIndexFetcher` — 미국 지수 (`S&P 500`, `NASDAQ`)
- `YFinanceExchangeRateFetcher` — USD/KRW 환율
- `YFinanceMarketNewsFetcher` — 미국 시장 뉴스

모두 `yfinance` 라이브러리 기반. 어댑터 4개를 만드는 과정에서 추가된 두 파일도 같이 다룬다.
- **공통 헬퍼** `_yfinance_common.py` — `Rule of Three` 발생 
- **도메인 보정** — `DailyPrice` → `StockDaily` + `PricePoint` 분리

## 시작하기 전에

### 1. 공통 헬퍼는 `Rule of Three`까지 기다렸다
`YFinanceFetcher`와 `YFinanceIndexFetcher`에서 같은 `_calculate_change` 로직이 나왔지만 추출 보류. `YFinanceExchangeRateFetcher` 에서도 `_calculate_change` 로직이 발생하여 `_yfinance_common.py`로 추출.

### 2. 도메인 보정
어댑터 4개 만드는 동안 `history`/`DailyPrice` 관련 설계 결정이 다섯 번 반복됐다. 원인은 `DailyPrice` 와 어댑터 사이에서 발생했다. `DailyPrice`가 종목 `OHLCV`에 최적화되어 지수·환율 쪽에서 호환이 어려웠다. 이를 `StockDaily`/`PricePoint` 로 분리했다.


## 어댑터 4개의 공통 패턴

| 항목 | 적용 방식 |
| :--- | :--- |
| 설정 의존 | 생성자 주입 (모듈 상수 import 금지) |
| 실패 처리 | `Port` 규약별로 다름 (아래 어댑터별 표) |
| 순수 변환 헬퍼 | `@staticmethod` |
| `self._news_limit` 사용 헬퍼 | 일반 메서드 |
| `Port` 상속 | 명시적 상속 (`class X(StockFetcher):`) |

생성자 주입을 강조하는 이유. 원본은 `from src.config import NEWS_LIMIT`처럼 모듈 상수를 어댑터 내부에서 직접 import. 이러면 (1) 테스트에서 `NEWS_LIMIT` 바꾸려면 `config` monkey-patch 필요, (2) 생성자만 보고는 어댑터 의존성 파악 불가. **의존성은 생성자 시그니처에 명시돼야 한다**. `Spring`이 생성자 주입을 권장하는 것과 같은 이유.

## 어댑터 4개 — 책임과 특이점

| 어댑터 | 입력 | 출력 | 특이점 |
| :--- | :--- | :--- | :--- |
| `YFinanceFetcher` | `dict[str, str]` 심볼-이름 매핑 | `list[StockSnapshot]` | 종목 단위 격리 + 뉴스 격리 |
| `YFinanceIndexFetcher` | `(symbol, name)` | `IndexSnapshot` | `history_days` 생성자 주입 |
| `YFinanceExchangeRateFetcher` | (없음) | `ExchangeRate` | `history` 필드 없음 → 최소 데이터(`"5d"`) |
| `YFinanceMarketNewsFetcher` | (없음) | `list[NewsItem]` | `^GSPC` 뉴스를 시장 뉴스로 사용 |

각 어댑터의 의미 있는 결정만 짚는다.

### `YFinanceFetcher` — 종목 단위 실패 격리

```python
def fetch(self, tickers: dict[str, str]) -> list[StockSnapshot]:
    results, errors = [], []
    for symbol, name in tickers.items():
        try:
            snapshot = self._fetch_one(symbol, name)
            if snapshot is not None:
                results.append(snapshot)
        except Exception as e:
            errors.append((symbol, e))
            logger.warning(f"미국 주식 조회 실패 ({symbol}): {e}")

    if not results and errors:
        raise RuntimeError(f"모든 미국 종목 조회 실패: {errors}")
    return results
```

원본 패턴은 `except Exception + log + continue`. **외형이 비슷하지만 의도가 다르다**.

| 원본 | 새 어댑터 |
| :--- | :--- |
| `except` 후 **전체 성공으로 위장** | `errors` 누적, 모두 실패 시 예외로 표면화 |
| 호출측에 실패 정보 전달 안 함 | 예외 메시지에 실패 종목 목록 포함 |
| 뉴스/주가 실패 구분 없음 | 뉴스 실패는 `news=[]` 격리, 주가 실패는 종목 스킵 |

"부분 성공 허용"은 배치 잡의 성질이지 에러 처리 철학의 후퇴가 아니다.

### `YFinanceIndexFetcher` — 원본의 `fast_info` 보정 로직 폐기

원본은 한국 지수(KOSPI/KOSDAQ) 어제 데이터 누락 시 `ticker.fast_info['last_price']`로 강제 주입했다. 자세히 보면 이 로직은 `OHLCV` 모든 컬럼을 `last_price` 하나로 덮어쓴다. **거래량이 가격값이 되는 명백한 버그 성격**.

`Phase 2` 어댑터에서는 이 로직을 **재이식하지 않고 삭제**. 미국 지수에는 필요 없고, 한국 지수는 `Phase 7`로 이동. `Phase 7` 재설계 시점에 이 로직을 **복사하면 안 된다**. 근본 원인(시간대 이슈? `yfinance`의 아시아 시장 지연?)부터 규명해야 한다.

### `YFinanceExchangeRateFetcher` — 도메인 차이가 구조를 결정

`ExchangeRate`에는 `history` 필드가 없다. 어댑터 구조가 `YFinanceIndexFetcher`와 살짝 다르다.

| 항목 | `YFinanceIndexFetcher` | `YFinanceExchangeRateFetcher` |
| :--- | :--- | :--- |
| 데이터 요청 기간 | `history_days + 2`일 | `"5d"` 고정 |
| 생성자 파라미터 | `history_days` | (없음, 클래스 상수) |
| `history` 파싱 | 필요 | **불필요** |

어댑터 간 "형식 대칭" 유혹을 거부하고 도메인이 요구하는 만큼만. **형식 일관성보다 의미가 우선**.

### `YFinanceMarketNewsFetcher` — `S&P 500` 뉴스를 시장 뉴스로

미국 시장 뉴스 API는 따로 없다. `yfinance`가 지수 단위 뉴스를 제공하는 특성을 활용해 `^GSPC` 뉴스를 시장 뉴스로 사용. 어댑터 내부 구현은 `YFinanceFetcher`의 종목 뉴스 파싱과 동일.

이 어댑터를 만들면서 `MarketNewsFetcher` `Port` docstring에 실패 전략을 보강. `Port` 설계의 두 번째 균열(`Phase 2-a` 참조).

## `_yfinance_common.py` — Rule of Three의 실제 적용

세 번째 사용처에서 추출했다. 헬퍼 두 개 + 내부 헬퍼 하나.

```python
def calculate_change(history: pd.DataFrame) -> tuple[float, float, float]:
    """(최신 종가, 전일 대비 변동, 변동률%) 계산."""
    latest = history.iloc[-1]
    prev = history.iloc[-2]
    close = float(latest["Close"])
    prev_close = float(prev["Close"])
    return close, close - prev_close, ((close - prev_close) / prev_close) * 100


def parse_yfinance_news(ticker: yf.Ticker, limit: int) -> list[NewsItem]:
    """yfinance Ticker에서 뉴스를 NewsItem 리스트로 변환.

    파싱 실패 격리는 호출측이 Port 규약에 따라 결정한다.
    """
    return [
        NewsItem(
            title=item.get("content", {}).get("title", ""),
            link=_extract_news_link(item.get("content", {})),
            ...
        )
        for item in ticker.news[:limit]
    ]
```

이 모듈의 의도된 비대칭: **`parse_yfinance_news`는 실패 격리를 하지 않는다**. 격리 정책이 `Port`마다 다르기 때문.

- `StockFetcher`의 뉴스 실패 → `news=[]` (종목 단위 격리)
- `MarketNewsFetcher`의 뉴스 실패 → `[]` 반환 (리포트 단위 격리)

공통 함수가 격리하면 컨텍스트(어느 심볼 실패?)를 잃는다. 격리 책임은 호출측 어댑터에 위임. **공통화 단위는 "정책"이 아니라 "변환"**.

> `Java`에서 `Optional<T>` 반환 vs 예외 던지기 결정을 호출측 책임으로 두는 패턴과 유사. 공통 유틸은 가장 일반적 형태로, 정책은 호출측.

## 도메인 보정 — `StockDaily` / `PricePoint` 분리

`Phase 1`의 `DailyPrice`는 종목 `OHLCV`에 최적화됐다. 지수·환율에 부담을 준 지점.

```python
# 보정 전 — YFinanceIndexFetcher._parse_history
DailyPrice(
    date=..., open=close, high=close, low=close, close=close, volume=0
)
```

지수는 `OHLCV` 중 종가만 의미 있는데 다른 필드를 억지로 채운다. `volume=0`은 "거래량 0"인지 "데이터 없음"인지 구분 불가. **원본은 `{"date": ..., "price": ...}` 2필드 dict로 우회했는데, `Phase 1` 도메인이 모든 시계열을 `DailyPrice`로 통합하면서 이 도메인 사실을 잃었다**.

해결 — 두 타입 분리.

```python
# domain/stock.py
@dataclass(frozen=True)
class StockDaily:           # 종목용 OHLCV
    date: str
    open: float
    high: float
    low: float
    close: float
    volume: int

# domain/market.py
@dataclass(frozen=True)
class PricePoint:           # 지수·환율 스파크라인용
    date: str
    price: float
```

`StockSnapshot.history`는 `list[StockDaily]`, `IndexSnapshot.history`는 `list[PricePoint]`.

보정 후 `YFinanceIndexFetcher._parse_history`:

```python
PricePoint(date=..., price=float(row["Close"]))
```

8줄 → 1줄. `volume=0` 매직 넘버 사라짐. 억지 채우기 사라짐.

**보정의 의미**: `Phase 1`에서 이걸 못 본 게 실수일까? 어느 정도 그렇다. 다만 `Phase 2` 중 발견하고 같은 Phase에서 해결한 것이 더 중요하다. "원본 패턴 복제 금지"는 코드에만 적용되는 게 아니라 **원본이 이미 알고 있던 도메인 사실을 잃지 말라**는 의미도 포함된다.

## 디렉토리 구조

```
src/
├── adapter/                                  # ← Phase 2 신설
│   ├── _yfinance_common.py
│   ├── yfinance_fetcher.py
│   ├── yfinance_index_fetcher.py
│   ├── yfinance_exchange_rate_fetcher.py
│   └── yfinance_market_news_fetcher.py
├── domain/
│   ├── stock.py       # Market, StockDaily, StockSnapshot
│   ├── news.py
│   ├── market.py      # IndexSnapshot, MarketOverview, ExchangeRate, PricePoint
│   └── report.py
└── port/
    └── (Phase 2-a에서 정의됨)
```

`Notifier`/`Analyzer` 어댑터는 `Phase 2-c`에서 추가.

## 결과 분석

| 항목 | Before (원본) | After (어댑터) |
| :--- | :--- | :--- |
| 외부 의존 위치 | 서비스 레이어 | 어댑터 레이어로 격리 |
| 반환 타입 | `dict[str, Any]` | 도메인 객체 |
| 실패 처리 | `except + continue` (실패 은폐) | `Port` 규약별 격리/예외 |
| 설정 의존 | 모듈 상수 직접 import | 생성자 주입 |
| 공통 로직 | 모듈 함수 분산 | `_yfinance_common.py` 집중 |
| 도메인 정확성 | 시계열 = `OHLCV` 일원화 | 종목(`OHLCV`)/지수(`종가`) 분리 |

## 이번 글에서 배운 것

1. **`Rule of Three`는 추출 시점의 객관적 신호**. 두 번째 중복은 추출 비용보다 결합 위험이 크고, 세 번째에서 정당화. 횟수 기반 의사결정이라 흔들림이 적다.
2. **어댑터 간 "형식 대칭"보다 "도메인 충실"이 우선**. `YFinanceExchangeRateFetcher`가 `history_days`를 안 받는 이유 — `ExchangeRate`에 `history`가 없어서.
3. **어댑터의 의존 감추기 경계는 `Port` 시그니처까지**. 내부 헬퍼 시그니처에 `pd.DataFrame`이 나오는 건 정상.
4. **공통 함수는 가장 일반적 형태로**. `parse_yfinance_news`가 실패 격리를 호출측에 위임하는 이유 — 격리 정책이 `Port`마다 다르기 때문.
5. **도메인 설계는 한 번에 끝나지 않는다**. `Phase 1` 도메인을 어댑터 구현 중 보정. 보정 자체가 학습 자산.

## What's Next

**`Phase 2-c`: 마지막 어댑터들과 조립**

- `SlackNotifier`, `DiscordNotifier` — webhook 기반 알림 어댑터
- `GeminiAnalyzer` — AI 시황 분석 + 모델 폴백 체인
- `prompt_builder.py` — AI 어댑터에서 분리된 프롬프트 빌더
- `main.py` — DI 조립 + 단계별 예외 처리 + exit code 정책