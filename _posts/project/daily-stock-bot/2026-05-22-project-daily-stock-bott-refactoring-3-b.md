---
title: "[Python Project Refactoring] 3-b. 어댑터 수정과 호출 정리"
date: 2026-05-22
categories: [Project, Daily Stock Bot Refactoring]
tags: [python, refactoring, exception-handling, retry, hexagonal-architecture]
---

## Daily Stock Bot 리팩토링 #3-b

### 이번 Phase의 목표
`3-a`에서 `common/errors.py`와 `common/retry.py`를 새로 만들었다. 어댑터 7개와 `main.py`가 이 구조를 사용하지 않으면 이 소스들은 의미가 없다. `3-b`는 그 의미를 만드는 작업이다.

**예외 계층의 진짜 가치는 어댑터가 아니라 호출측에서 드러난다.** 어댑터에 `NetworkError`/`ParseError`/`ApiResponseError`를 넣는 작업은 절반에 불과하다.

## 변경점 요약

| 파일 | 변경 |
|:---|:---|
| `adapter/yfinance_fetcher.py` | `try` 블록 분리, `NetworkError`/`ParseError` 번역, `@retry(3, 2.0)` |
| `adapter/yfinance_index_fetcher.py` | 동일 패턴 + `len(history) < 2`를 `ParseError`로 |
| `adapter/yfinance_exchange_rate_fetcher.py` | 동일 패턴 |
| `adapter/yfinance_market_news_fetcher.py` | 의도 주석 추가 (`@retry`/번역 모두 안 함) |
| `adapter/slack_notifier.py` | `HTTPError` → `ApiResponseError`, `@retry(1)` |
| `adapter/discord_notifier.py` | 동일 패턴 (Slack에 위임) |
| `adapter/gemini_analyzer.py` | `response.text` `None` 명시 검증, 의도 주석 |
| `domain/report.py` | `__post_init__` 불변식 검증 |
| `main.py` | `except Exception` → `except AdapterError` |

## yfinance 계열 — `YFinanceFetcher` 깊이 보기
yfinance 어댑터 4개는 같은 라이브러리를 쓰지만 **격리 정책이 다르다.** 대표로 `YFinanceFetcher`를 정리하고, 나머지 3개는 차이만 표로 정리한다.

### 1. `try` 블록 분리
한 `try`로 묶으면 **`NetworkError`(연결 실패)인지 `ParseError`(스키마 깨짐)인지 구별할 수 없다.** `@retry`가 `5xx` 재시도와 `4xx` 즉시 포기를 구분하지 못한다.

```python
def _fetch_one(self, symbol: str, name: str) -> StockSnapshot | None:
    try:
        ticker = yf.Ticker(symbol)
        history = ticker.history(period="5d")
    except requests.RequestException as e:
        raise NetworkError(f"yfinance 연결 실패 ({symbol})") from e

    if history.empty:
        logger.warning(f"미국 주식 데이터 없음: {symbol}")
        return None

    try:
        stock_daily = self._parse_history(history)
        close, change, change_pct = calculate_change(history)
    except (KeyError, IndexError, ValueError, TypeError) as e:
        raise ParseError(f"yfinance 응답 파싱 실패 ({symbol})") from e

    ...
```

> Docstring 제외, Docstring 포함 파일은 Github repo 참고

`history.empty`는 `try` 사이에 둔다. 이건 예외가 아니라 yfinance의 "종목 데이터 없음" 이다.

yfinance가 자체 예외를 제공하지 않아서 `requests.RequestException`을 직접 잡는다. yfinance 내부가 `requests`를 쓰고 그 예외를 그대로 던지기 때문이다.

### 2. 전 종목 실패
종목별 `try/except`로 격리하고, 모든 종목이 실패하면 `NetworkError`로 처리한다.

yfinance의 일시적 실패는 **전체 단위로 온다.** 종목 10개가 다 실패했다는건 "각 종목의 실패가 우연히 겹쳤다"가 아니라 "연결 자체가 죽었다"가 확률상 훨씬 크다. 그래서 `NetworkError`. `@retry`가 이걸 받아 3회까지 재시도한다.

`AdapterError`(루트) 직접 던지는 선택도 있지만, `@retry`가 재시도를 안 해버리게 된다(`_is_retryable: False`). **재시도 가치가 가장 큰 자리에서 재시도를 없애버리는 셈** 이 된다.

> 종목별 `try/except`가 `NetworkError`와 `ParseError`를 둘 다 잡으니까 `errors` 리스트에 `ParseError`도 섞일 수 있다. "전 종목이 다 `ParseError`였는데 `NetworkError`로 던지는" 케이스가 가능하다.(yfinance 응답 스키마가 통째로 바뀌어서 전 종목 파싱이 깨진 경우 등) 이때 `@retry`가 작동하지만 그렇게까지 정밀 분류를 해야하는 스케일의 작업이 아니라고 생각해서 `NetworkError` 로 통일했다.

### 3. @retry
`@retry`를 어디에 걸 것인가.

- **A: `_fetch_one`에 종목별 `@retry`.** 종목 하나가 실패하면 그 종목만 재시도.
- **B: `fetch` 전체에 `@retry`.** 모든 종목 실패 시에만 재시도.

A가 깔끔해 보였다. "AAPL만 순간 타임아웃 한 번"을 잡아낼 수 있으니까. 하지만 **B를 선택했다.**

yfinance의 실패 모델이 **전체 단위로 온다.**  끊기면 다 끊기고, 되면 다 된다. "AAPL만 실패하고 MSFT는 성공"이 일어나려면 AAPL **티커 자체**의 문제(상장폐지, 심볼 오타)여야 하는데 그건 `NetworkError`가 아니라 `history.empty`(`None` 스킵) 아니면 `ParseError`(재시도 무의미)다. **즉 "종목별 `@retry`가 구해줄 수 있는 케이스" = "개별 종목만 일시적 `NetworkError`"가 일어날 가능성이 거의 없다.**

> 시간도 다르다. A로 가면 진짜 네트워크가 죽은 날 종목 10개 × 3회 × 2초 = 60초 가 걸린다. B는 6초.

> 하지만 개별 종목 단위 일시 실패가 실제로 발생한다면 그땐 A 방법을 고려해봐야 할 거 같다.

### 4. 코드

```python
@retry(max_attempts=3, delay=2.0)
def fetch(self, tickers: dict[str, str]) -> list[StockSnapshot]:
    results: list[StockSnapshot] = []
    errors: list[tuple[str, Exception]] = []

    for symbol, name in tickers.items():
        try:
            snapshot = self._fetch_one(symbol, name)
            if snapshot is not None:
                results.append(snapshot)
        except (NetworkError, ParseError) as e:
            errors.append((symbol, e))
            logger.warning(f"미국 주식 조회 실패 ({symbol}): {e}")

    if not results and errors:
        raise NetworkError(f"모든 미국 종목 조회 실패: {errors}")

    return results
```

> Docstring 제외, Docstring 포함 파일은 Github repo 참고

## yfinance 나머지 3개
나머지 세 어댑터는 `YFinanceFetcher`와 **같은 구조에 다른 정책**이다.

| | `IndexFetcher` | `ExchangeRateFetcher` | `MarketNewsFetcher` |
|:---|:---|:---|:---|
| 단일/복수 | 단일 지수 | 단일 환율 | 단일 뉴스 리스트 |
| 데이터 부족 처리 | `ParseError` 던짐 | `ParseError` 던짐 | 해당 없음 |
| 실패 격리 | 없음 (예외 전파) | 없음 (예외 전파) | `[]` 자체 격리 |
| `@retry` | `(3, 2.0)` | `(3, 2.0)` | **미적용** |
| 예외 번역 | `NetworkError`/`ParseError` | `NetworkError`/`ParseError` | **번역 안 함** |

### `IndexFetcher`의 데이터 부족 → `ParseError`
`StockFetcher`는 `history.empty`를 "그 종목 스킵"으로 처리했다. `IndexFetcher`는 `len(history) < 2`를 **예외로 던진다.**

**지수는 스킵이 불가능하다.** S&P 500이 없는 미국 시장 리포트는 의미가 없다. 종목은 일부 빠져도 리포트가 성립하지만, 지수가 빠지면 리포트 자체가 깨진다.

### `MarketNewsFetcher`만 `@retry` 미적용
`MarketNewsFetcher`는 실패 시 `[]`로 **자체 격리**하며 예외를 밖으로 안 던진다. `@retry`의 의미가 없다.

```python
def fetch(self) -> list[NewsItem]:
    try:
        ticker = yf.Ticker(self._symbol)
        return parse_yfinance_news(ticker, self._news_limit)
    except Exception as e:
        logger.warning(f"미국 시장 뉴스 조회 실패 ({self._symbol}): {e}")
        return []
```

> Docstring 제외, Docstring 포함 파일은 Github repo 참고

### 같은 형태인데 추출 안 한 이유
yfinance 4개 어댑터가 모두 `try: ticker.history()` → 검증 → `try: 파싱` 패턴이다. 그런데 공통 함수나 데코레이터로 추출하지 않았다.

**추상화의 단위는 형태가 아니라 의미다.** 네 어댑터의 격리 정책이 다르다.
- `StockFetcher`: 종목 단위 격리 (`None` 스킵)
- `IndexFetcher`/`ExchangeRateFetcher`: 격리 없음 (예외 전파)
- `MarketNewsFetcher`: 리포트 단위 격리 (`[]`)

같은 헬퍼로 묶으면 이 의미 차이가 다 사라지고 "디폴트 값 반환 헬퍼"라는 의미만 남게 된다.

## Notifier
`Slack`/`Discord` 어댑터는 `requests.post() + raise_for_status()` 구조다.

### `except` 순서
```python
try:
    response = requests.post(self._webhook_url, json=payload, timeout=self._timeout)
    response.raise_for_status()
except requests.HTTPError as e:
    raise ApiResponseError(
        "Slack 알림 전송 실패",
        status_code=e.response.status_code,
        response_body=e.response.text,
    ) from e
except requests.RequestException as e:
    raise NetworkError("Slack 연결 실패") from e
```

**`HTTPError`가 `RequestException`의 서브클래스다.** `RequestException`을 먼저 잡으면 `HTTPError`가 거기 먹혀서 `ApiResponseError` 가 잡히지 않는다.

### `max_attempts=1`의 이유
재시도하지 않을 거면 `@retry` 자체를 안 달면 된다. **그럼에도 `@retry(max_attempts=1)`을 추가해줬다.**

`max_attempts=1`은 데코레이터가 없는 것과 **동일하다**. 그럼에도 **정책을 코드에 명시하기 위해서다.** 데코레이터가 없으면 "재시도를 깜빡한 건지, 안 하기로 결정한 건지" 코드만 봐선 모른다.

알림 전송은 **부분 성공 부작용** 의 케이스가 존재한다. `requests.post`가 응답을 받기 전에 끊겼는데 실제론 `Slack`에 메시지가 갔을 수 있다. 재시도하면 **중복 알림**이 간다.

> DiscordNotifier 는 Slack 과 거의 같아서 생략한다.

## `GeminiAnalyzer` 는 예외를 따로 처리하지 않는다.
다른 어댑터들은 raw 예외를 커스텀 예외로 번역했다. **`GeminiAnalyzer`만 SDK 예외를 번역하지 않는다.**

1. **SDK 예외 구조를 검증하지 않았다.** `google.genai`가 어떤 예외를 어떻게 던지는지 모른다.
2. **SDK 버전마다 바뀐다.** 이미 한 번 바뀐 전적이 있다(`google-generativeai` → `google-genai`).

### `response.text` `None` 명시 검증
`safety filter`로 응답이 차단되면 `response.text`가 `None`이 되고 `.strip()`에서 `AttributeError` 에러로 된다. 동작은 하지만, **`errors` 리스트에 `AttributeError("NoneType...")`로 찍힌다.**

```python
text = response.text
if text is None:
    # 응답 차단(safety filter 등) — 식별 가능하므로 명시 검증.
    raise ParseError(
        f"Gemini 응답 본문이 비어있음 (model={model})"
    )
```

같은 `except Exception`이 이 `ParseError`를 잡는다. `errors`에 `AttributeError` 대신 의미 있는 `ParseError`가 담기게 된다.

## `main.py`

### `except Exception` → `except AdapterError`
`except Exception`으로 모든 실패를 잡았던 것을 `except AdapterError` 으로 변경한다.

```python
try:
    us_stocks = stock_fetcher.fetch(US_TICKERS)
except AdapterError as e:
    logger.error(f"미국 종목 수집 실패: {e}", exc_info=True)
    sys.exit(1)
```

### 코드 버그가 일어났을 때
`stock_fetcher.fetch` 내부에 오타 버그가 있다고 가정하면

```python
results.appedn(snapshot)  # append → appedn 오타
```

`except Exception`:
- `AttributeError`가 잡힌다.
- 로그: `"미국 종목 수집 실패: 'list' object has no attribute 'appedn'"`
- `sys.exit(1)`.

"미국 종목 수집 실패" 에러로 떠버린다. GitHub Actions 로그 확인 시 yfinance 문제로 생각하게 된다.

> 상세 에러('list' object has no attribute 'appedn'"`...) 를 보면 문제없긴 하다.

`except AdapterError`:
- `AttributeError`는 `AdapterError`가 아니므로 안 잡힌다.
- 트레이스백째로 그대로 죽는다.
- GitHub Actions는 마찬가지로 exit code != 0으로 실패 처리.
- 로그에 진짜 트레이스백이 박힌다.

**외부 실패와 내부 버그가 구별된다.**

### 5번 반복되는 `try/except`
`main.py`에 `try/except AdapterError` 블록이 5개 등장한다. 종목/지수/환율/AI 분석/ Notifier. 모양이 거의 같다. 헬퍼나 `with` 컨텍스트 매니저로 묶을 수 있다.

하지만 추출하지 않았다.
- 종목/지수/환율: `sys.exit(1)` (필수 단계)
- AI 분석: 그냥 진행 (옵셔널)
- Notifier: `failed_notifiers`에 추가 (부분 성공 추적)

형태는 비슷해도 의미가 다르다. 헬퍼로 추출하면 "어떤 단계가 필수냐"가 헬퍼 인자로 숨는다. 현재 코드만 봐도 `sys.exit(1)`이 있어서 "여기 실패하면 끝"이 즉시 보인다.

yfinance 어댑터들에서 추출하지 않은 이유와 **같은 원칙**이다.

## 이번 글에서 배운 것
1. **회수 시점이 설계 시점보다 중요하다.** `3-a`에서 만든 예외 계층은 어댑터에 박는 것까지가 절반, `main.py`의 `except`를 좁히는 마지막 한 줄이 절반이다. **`except AdapterError`로 좁히면 코드 버그가 외부 실패로 덮어지지 않는다.**
2. **비대칭은 일관성의 반대말이 아니다.** yfinance 4개 어댑터의 격리 정책이 다 다른 것, `GeminiAnalyzer`만 SDK 예외를 커스텀화하지 않는 것. 모두 **의미가 달라서** 다른 것이다.
3. **`max_attempts=1`과 `try` 바깥 분해는 정책 명시다.** 동작은 안 한 것과 같지만, 코드에 "안 하기로 결정했다"가 박힌다.

## What's Next
- `Port`가 `Protocol`인 목적 테스트
- `@retry`의 `time.sleep` 결정
- 어댑터 자체 격리(`MarketNewsFetcher`, `_fetch_news_safely`, `GeminiAnalyzer`) 검증
- 도메인 불변식(`DailyReport.__post_init__`) 테스트