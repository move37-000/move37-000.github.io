---
title: Daily Stock Bot 리팩토링 - 4. 테스트
date: 2026-06-30
categories: [Python, Project]
tags: [python, pytest, pytest-mock, hexagonal-architecture, fake, mock, testing]
image:
---

## Daily Stock Bot 리팩토링 #4

### 이번 Phase의 목표
`Phase 2`에서 `Port/Adapter`를 도입하면서 두 가지를 정했다.

- **테스트 가능성** — 도메인이 외부 의존성 없이 단위 테스트 가능해야 한다.
- **교체 가능성** — 어댑터는 `Port`를 만족하는 한 자유롭게 교체 가능해야 한다.

이번 글의 중요 내용은

1. **`Port`는 `Fake`, 라이브러리는 `Mock`** — 같은 도구로 통일하지 않은 이유
2. **`@retry` 테스트는 `mocker.patch("time.sleep")`** — `sleep_fn`을 사용하지 않은 이유

## `Port`는 `Fake`, 라이브러리는 `Mock`

| 대상 | 도구 | 사용 위치 |
|---|---|---|
| `Port` (`Protocol`) | `Fake` 클래스 | 도메인/서비스 테스트 |
| 외부 라이브러리 (`yfinance`, `requests`, `google.genai`) | `mocker.patch` | 어댑터 테스트 |
| 호출 횟수 / 인자 검증 | `mocker.MagicMock` + `side_effect` | 어댑터 내부의 외부 라이브러리에 한정 |

`mocker.Mock(spec=Port)`로 통일할 수도 있다. 하지만 `Port`와 외부 라이브러리는 **테스트가 검증하려는 대상이 다르다.**
- `Port`에 가짜 구현을 끼워 넣는 것 자체가 "이 자리에 다른 구현이 들어올 수 있다"는 증거이다.
- 외부 라이브러리는 어댑터 안에 갇혀 있다. 가짜 구현을 만들 이유가 없다.

### `Fake` 
`conftest.py`에 `Port`별 `Fake` 클래스를 직접 정의한다.

```python
class FakeStockFetcher(StockFetcher):
    def __init__(self, snapshots: list[StockSnapshot]) -> None:
        self._snapshots = snapshots
        self.fetch_calls: list[dict[str, str]] = []

    def fetch(self, tickers: dict[str, str]) -> list[StockSnapshot]:
        self.fetch_calls.append(tickers)
        return self._snapshots
```

> Docstring 제외, Docstring 포함 파일은 Github repo 참고

`Protocol`은 구조적 서브타이핑이라 `class FakeStockFetcher:`만 써도 `StockFetcher` 자리에 들어가지만 `(StockFetcher)`를 명시 상속하는 이유는 두 가지다.
1. **`mypy`가 시그니처 불일치를 정적으로 잡는다.** `Port`가 바뀌었는데 `Fake`를 못 따라가면 테스트가 깨지기 전에 타입 체커가 먼저 잡는다.
2. **읽는 사람이 "이건 `StockFetcher` 자리에 들어가는 구현"임을 한눈에 안다.**

`MagicMock(spec=StockFetcher)`도 같은 자리에 들어간다. 차이는 표현력이다. `Fake`는 "어떤 입력에 어떤 출력이 나오는지" 클래스 본문에 명시된다. `Mock`은 테스트 케이스마다 `mock.fetch.return_value = ...`를 써야한다. 

### 외부 라이브러리는 `mocker.patch`
어댑터 단위 테스트는 어댑터와 외부 라이브러리 경계를 테스트한다. `yfinance.Ticker`를 `Fake` 클래스로 다시 만들 이유도 도구도 없다. 그 자리에 `mocker.patch`가 들어간다.

```python
mocker.patch("src.adapter.yfinance_fetcher.yf.Ticker", return_value=ticker)
```

첫 인자가 `yfinance.Ticker`가 아니라 `src.adapter.yfinance_fetcher.yf.Ticker`인 게 핵심이다. **`patch`는 모듈 네임스페이스에서 이름을 대체한다.** `yfinance_fetcher.py`가 `import yfinance as yf`로 가져온 그 자리의 `Ticker`만 가짜로 바꾼다. `yfinance` 원본은 그대로다. 어댑터가 보고 있는 **대상**만 바꿔치기한다.

## `@retry` 테스트는 `mocker.patch("time.sleep")`

`@retry`는 `delay=2.0`초 고정이다. 어댑터에는 `@retry(3, 2.0)`이 박혀 있다. 테스트가 어댑터를 실호출하면 실패 케이스마다 최소 4초씩 잡아먹는다.

| 안 | 방법 |
|---|---|
| A | `@retry(delay=0)`을 데코레이터로 다시 호출 | 
| B | `@retry`에 `sleep_fn` 파라미터 주입 | 
| C | `mocker.patch("src.common.retry.time.sleep")` | 

### A안
어댑터 소스의 `@retry(3, 2.0)`을 안 거친다. 테스트가 자기만의 `@retry(delay=0)` 경로를 따로 만든다.

이러면 검증되는 게 어댑터 실제 정책이 아니라 테스트가 만든 정책이다. 어댑터에서 누군가 `@retry(5, 2.0)`으로 바꿔도 이 테스트는 통과한다. 

### B안
데코레이터 시그니처를 변경한다.

```python
def retry(max_attempts: int, delay: float, sleep_fn=time.sleep):
    ...
```

테스트에서는 `sleep_fn=lambda _: None`을 넣어 우회한다. 

`Python`에서는 과한 추상화다. 테스트가 아닌 소스 시그니처에 **테스트 전용 파라미터**가 박힌다. 호출측 코드가 다 떠안고, "왜 `sleep_fn`이 인자에 있지?"라는 의문이 발생한다.

### C안(선택) - `mocker.patch`는 모듈 네임스페이스를 갈아치운다
```python
mock_sleep = mocker.patch("src.common.retry.time.sleep")
```
1. `src.common.retry` 모듈을 import한다.
2. 그 모듈의 `time` 객체에서 `sleep` 속성을 찾는다.
3. 원본 `time.sleep`을 떼어내고 `MagicMock` 인스턴스를 끼워 넣는다.
4. 테스트 함수가 끝나면 원본을 돌려놓는다.

**첫 인자가 `time.sleep`이 아니라 `src.common.retry.time.sleep`**이라는 점이다. `time` 라이브러리 원본은 안 건드린다. `retry.py`가 보고 있는 `time.sleep`만 갈아치운다. 어댑터에서 `yf.Ticker`를 patch한 것과 같은 메커니즘이다.

이게 가능한 이유는 **`Python`의 모듈이 1급 객체이고, 모듈 속성을 런타임에 교체할 수 있기 때문**이다. `Java`의 `import`는 컴파일 타임에 해소되어 런타임 교체가 불가능하다. 

`pytest-mock`의 `mocker` fixture는 `unittest.mock.patch`를 테스트 환경에 묶은 것이다. 함수 끝에 자동 복원되므로 다른 테스트로 새는 일이 없다.

### mocker 실제 사용 
어댑터 소스의 `@retry(3, 2.0)`은 그대로 통과시키면서, 호출 횟수까지 검증한다.

```python
def test_전종목_실패시_retry_3회_발동(self, mocker):
        mock_sleep = mocker.patch("src.common.retry.time.sleep")
        ticker_call_count = 0

    def _failing_ticker(*_args, **_kwargs):
        nonlocal ticker_call_count
        ticker_call_count += 1
        t = mocker.MagicMock()
        t.history.side_effect = requests.RequestException("conn lost")
        return t

    mocker.patch(
        "src.adapter.yfinance_fetcher.yf.Ticker",
        side_effect=_failing_ticker,
    )

    with pytest.raises(NetworkError):
        YFinanceFetcher().fetch({"AAPL": "Apple", "MSFT": "Microsoft"})

    assert ticker_call_count == 6
    assert mock_sleep.call_count == 2
```

> Docstring 제외, Docstring 포함 파일은 Github repo 참고

`@retry(3, 2.0)` 정책이 그대로 검증된다. 어댑터에서 `(3, 2.0)`을 `(5, 2.0)`으로 바꾸면 `ticker_call_count`와 `mock_sleep.call_count` 두 assert가 모두 깨진다.

> 테스트마다 `mocker.patch("...time.sleep")`을 추가해줘야 한다. 실수로 추가하지 않으면 그 테스트만 진짜로 4초씩 잠든다. B안이라면 시그니처가 강제하므로 누락이 원천 불가능하다.

> 하지만 이 비용보다 원본 소스 시그니처를 건들고 싶지 않았다. 그리고 무엇보다 어댑터 개수가 많지도 않아서(테스트 케이스가 적어서) mock 안으로 적용했다.

## 이번 Phase에서 배운 것

1. **`Port`와 인프라를 같은 도구로 다루지 않는다.** `Port`는 약속이라 `Fake` 클래스로 명시 구현하고, 외부 라이브러리는 `mocker.patch`로 모듈 네임스페이스에서 갈아치운다. 통일하면 편하지만 헥사고날의 경계가 테스트 코드에서 안 보이게 된다.
2. **`Protocol`에 명시 상속을 박는다.** 구조적 서브타이핑이라 안 박아도 동작하지만, `mypy`가 시그니처 불일치를 정적으로 잡고, 읽는 사람이 의도를 한눈에 본다. 
3. **테스트 한 가지를 위해 프로덕션 시그니처를 확장하지 않는다.** `sleep_fn` 주입 방식은 익숙하지만 비용이 크다. `mocker.patch`로 같은 효용을 얻을 수 있다면 시그니처는 그대로 둔다.

## What's Next
- `repository/` 등 미사용 코드 제거
- `requirements.txt` 버전 고정
- 운영 품질 정리