---
title: Daily Stock Bot 리팩토링 - 3-a. 예외 계층과 재시도 데코레이터
date: 2026-05-22
categories: [Python, Project]
tags: [python, refactoring, exception-handling, retry, decorator, hexagonal-architecture, fail-fast]
image:
---

## Daily Stock Bot 리팩토링 #3-a

### 이번 Phase의 목표
`Phase 2`에서 모든 어댑터는 실패 시 `raise RuntimeError`로 통일했다. **모든 실패가 같은 이름으로 묶여 호출측이 구별할 수 없는 상태**였다. `Phase 3`는 그 `RuntimeError`를 의미 단위로 분리하고, 그 분리를 전제로 재시도 데코레이터를 설계한다.

`Phase 3`도 분량이 커서 두 편으로 나눈다.
- **3-a**: 예외 계층(`common/errors.py`) + 도메인 불변식 검증 + 재시도 데코레이터(`common/retry.py`)
- **3-b**: 어댑터 7개 수정 + `main.py`의 `except` 수정

## 예외 계층 구조
어떤 예외가 필요한가?

- `NetworkError` — 연결 실패, 타임아웃, DNS. **재시도 가능**.  
- `ParseError` — 응답은 왔는데 스키마가 깨짐 (`KeyError`, `IndexError`, `response.text is None`). **재시도 무의미**.
- `ApiResponseError` — `4xx`/`5xx`. webhook 거부, Gemini quota 초과 등.

세 번째가 문제다. "API 응답 오류"를 한 덩어리로 두면 재시도 정책이 안 갈린다. `5xx`(서버 일시 장애)는 재시도 가능, `4xx`(보내는 요청이 틀림)는 재시도가 무의미하다.

**평면 계층 (flat) 예외 구조**
```python
AdapterError (Exception)
├── NetworkError
├── ParseError
└── ApiResponseError   # status_code 속성으로 4xx/5xx 구분
```
`@retry`가 `isinstance(e, NetworkError) or (isinstance(e, ApiResponseError) and e.status_code >= 500)`로 판단.

**재시도 가능성은 예외의 속성이 아니라 정책이다.**

`4xx`도 상황에 따라 재시도하고 싶을 수 있다. Gemini `429`(Rate Limit)는 형식상 `4xx`지만 잠깐 기다리면 풀린다. **재시도 여부를 타입 계층에 박으면, 정책이 바뀔 때 계층을 다시 짜야 한다.**

> 정책은 데코레이터(`common/retry.py`)가 갖고, 예외는 "무슨 일이 일어났는가"라는 사실만 들고 있어야 한다.

## `domain`이 아니라 `common`
이 예외 파일을 어디에 둘 것인가.

- **A: `domain/errors.py`**
- **B: `adapter/errors.py`**
- **C: `common/errors.py`**

**`C안`을 선택했다.**

`A안`이 안 되는 이유 — `NetworkError`, `ParseError`, `ApiResponseError`는 전부 **외부 시스템과의 작업에서 생기는 에러**다. 도메인(`StockSnapshot`, `DailyReport`)은 네트워크가 뭔지 HTTP가 뭔지 몰라야 한다. 헥사고날에서 도메인은 가장 안쪽 순수 계층이다. 거기에 `NetworkError`를 두면 **도메인이 인프라 관심사를 알게 된다 — 의존성 방향 위반.**

`B안`이 안 되는 이유 — 어댑터만 쓰는 게 아니다. `@retry` 데코레이터도 이 예외를 알아야 분류하고, `main.py`도 잡아야 한다. **어댑터 전용이 아니다.**

`C안` — 어댑터 계층의 **공통 어휘**고, 같은 `common/`에 들어올 `retry.py`와 한 패키지에 사는 게 자연스럽다(데코레이터가 이 예외들을 분류 대상으로 삼으니까). 도메인은 건드리지 않는다.

>  `DailyReport.top_gainer` 빈 리스트 검증은 **도메인 안의 일**이다. 거기서 던질 예외는 `common/errors.py`의 어댑터 예외 계열이 아니라 파이썬 `ValueError`다. **인프라 예외와 도메인 예외는 다른 계열이다.**

## 예외 필드 — 잡는 쪽이 쓸 정보
예외를 **잡는 쪽이 쓸 수 있는 정보를 들고 있게** 해야 한다.

1. `@retry` 데코레이터 — `ApiResponseError.status_code`로 `5xx` 여부 판단.
2. `main.py` — 어느 단계 실패인지 로그에 남기고 `exit code` 결정.
3. `GitHub Actions` 에러 발생 이유 추적

3번이 중요하다. **예외 메시지 = 유일한 디버깅 단서다.** 부실하면 `Actions` 로그를 열어도 원인을 모른다.

### raw 예외 보존 — `from e` 체이닝
어댑터는 `yfinance`/`requests`의 raw 예외를 잡아서 우리 예외로 번역할 것이다. 그때 raw 예외를 어떻게 보존할 것인가.

```python
raise NetworkError("yfinance 연결 실패") from e
```
`Python` 예외 체이닝. `__cause__`에 raw 예외가 객체로 보존되고, 트레이스백에 `The above exception was the direct cause of...`로 **두 트레이스백이 다 찍힌다.**

`from e`는 `Python`이 예외 번역(translation)을 위해 만든 전용 문법이다. 문자열 보간은 raw 예외의 **타입과 스택을 지운다**. (`requests.ConnectTimeout`인지 `requests.ReadTimeout`인지 사라진다.) 객체로 살려두면 `e.__cause__`로 언제든 꺼낼 수 있다.

### `ApiResponseError` 필드

`status_code`는 `@retry`가 `5xx` 판단에 쓰니까 필수. 그 외에 `status_code` + `response_body`도 사용한다.

 webhook이 `4xx`를 줄 때 `Slack`/`Discord`는 본문에 거부 이유를 적어준다(`invalid_payload` 등). 그게 없으면 `400`만 보고 뭐가 틀렸는지 모른다.

`response_body`는 **로그 분석시 매우 중요하다.** `4xx`는 재시도해도 안 풀리니까 **수동으로 고쳐야 하는데**, 본문 없으면 "`Slack`이 `400` 줬음"만 알고 끝이다. 다만 `response_body`는 길 수 있으니 생성자에서 잘라낸다(`200`자).

## `common/errors.py` 
```python
class AdapterError(Exception):


class NetworkError(AdapterError):


class ParseError(AdapterError):


class ApiResponseError(AdapterError):


    def __init__(
        self,
        message: str,
        status_code: int,
        response_body: str = "",
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.response_body = response_body[:200]
```
> Docstring 제외, Docstring 포함 파일은 Github repo 참고

- **1. `NetworkError`/`ParseError`는 `__init__`을 안 썼다.** `Exception` 기본 생성자(`message` 하나 받는)를 그대로 상속. 빈 `def __init__(self, message): super().__init__(message)`는 아무것도 안 하는 코드다.
- **2. `response_body[:200]`을 생성자에서 자른다.**  예외 객체가 스스로 "나는 `200`자까지만 들고 다닌다"를 보장한다. 로그로 흘러갈 값이라 객체 레벨에서 못박는 게 안전하다.

## 기본 전제 — `top_gainer` 빈 리스트
`DailyReport.top_gainer`는 `max(self.us_stocks, ...)`를 부르는데, `us_stocks`가 비면 `ValueError`를 던진다.

비는 시점은, `YFinanceFetcher`가 모든 종목 실패하면 `NetworkError`를 던지니까 `us_stocks=[]`인 `DailyReport`는 **정상 흐름에선 안 만들어진다**. **그럼에도 검증을 해야한다.**

**예외처리가 아닌 제약 조건을 위해서다.** "빈 `DailyReport`는 만들어지면 안 되는 객체" 로 명시한다. 추후 `us_stocks=[]`으로 `DailyReport`를 만들면 **`top_gainer`를 호출하는 곳이 아니라 생성 시점에 터져야 한다.**

**`__post_init__`에서 검증**
```python
def __post_init__(self) -> None:
    if not self.us_stocks:
        raise ...
```
`frozen=True` dataclass도 `__post_init__`은 돈다. 생성 즉시 터진다. fail-fast.

`max([])`가 `SlackNotifier` 깊은 곳에서 터지면 "왜 `Notifier`가?" 하고 헤매지만, `DailyReport(...)` 줄에서 터지면 원인이 즉시 보인다.

### 무슨 예외를 던지나 — `ValueError`
여기서 `common/errors.py`의 `AdapterError` 계열을 쓰면 **안 된다**. 이건 어댑터 사고가 아니라 **호출자가 잘못된 인자를 넣은 것**. 

도메인 전용 예외(`EmptyReportError` 같은)를 새로 만들지 않는다. 도메인에서 전제 조건 위반은 `ValueError`로 충분하고, 이건 잡으라고 던지는 게 아니라 **버그를 즉시 노출시키려고** 던지는 거다.

```python
def __post_init__(self) -> None:
    if not self.us_stocks:
        raise ValueError(
            "us_stocks가 비어있는 DailyReport는 생성할 수 없음"
        )
```
> Docstring 제외, Docstring 포함 파일은 Github repo 참고

`top_gainer`/`top_loser` `property`에서는 별도 검증을 두지 않는다. `__post_init__`이 통과한 객체는 `us_stocks`가 비어있지 않음이 보장되기 때문이다.

## 재시도 데코레이터 — 무엇을 재시도하는가
예외 계층을 만든 1차 목적은 **재시도 정책을 세우기 위해서**다. 네트워크 타임아웃은 재시도하면 풀리지만, `404`나 스키마 깨짐은 재시도해도 똑같다. 둘을 타입으로 구별해야 재시도 데코레이터가 일을 할 수 있다.

| 예외 | 재시도? | 근거 |
|:---|:---|:---|
| `NetworkError` | O | 타임아웃·연결 끊김은 다음에 풀릴 수 있음 |
| `ParseError` | X | 스키마 깨짐은 재시도해도 똑같음 |
| `ApiResponseError` (`5xx`) | O | 서버 일시 장애 |
| `ApiResponseError` (`4xx`) | X | 우리 요청이 틀림. 재시도 무의미 |
| `ApiResponseError` (`429`) | **O** | `4xx`지만 Rate Limit — 기다리면 풀림 |
| 그 외 (raw `Exception` 등) | X | 정체 모를 것은 재시도 안 함 (보수적) |

`429`가 예외 계층 구조를 평면 계층으로 선택한 가장 중요한 이유다.

```python
def _is_retryable(exc: Exception) -> bool:
    if isinstance(exc, NetworkError):
        return True
    if isinstance(exc, ApiResponseError):
        return exc.status_code == 429 or exc.status_code >= 500
    return False  # ParseError 포함, 나머지 전부 재시도 안 함
```

이 판정을 데코레이터에 **하드코딩** 한 이유는, **어댑터가 판정하지 않기 때문이다.**

"`NetworkError`/`5xx`/`429`는 재시도 가능"은 **시스템 전체의 보편 사실**이지 어댑터별로 갈리는 사항이 아니다. `StockFetcher`의 `NetworkError`와 `SlackNotifier`의 `NetworkError`가 재시도 가능성이 다를 이유가 없다. 어댑터마다 다른 건 **횟수**지(`StockFetcher` 3회, `Notifier` 1회) 판정 규칙이 아니다.

## 인터페이스 — `max_attempts`는 총 시도 횟수
**`max_attempts` = 총 시도 횟수.** `3`이면 최초 1회 + 재시도 2회 = 총 3번 호출. `1`이면 재시도 없음, 딱 1번.

예로 들어 "`Notifier`는 1회" 가 직관적으로 "한 번 한다"지 "한 번 더 재시도한다(= 총 2번)"가 아니다. `max_attempts`를 "총 횟수"로 잡으면 `Notifier`는 `@retry(max_attempts=1)` "재시도 안 함" 의미와 일치한다. 

```python
def retry(max_attempts: int = 3, delay: float = 2.0):
    def decorator(func):
        @functools.wraps(func)   
        def wrapper(*args, **kwargs):
            ...
        return wrapper
    return decorator
```
> Docstring 제외, Docstring 포함 파일은 Github repo 참고

## 대기 전략 — 고정과 지수 백오프
재시도를 즉시 하면 의미가 약하다(서버가 회복할 시간을 안 줌). 

- **A — 고정 대기 (fixed).** 매번 똑같이 `N`초.
- **B — 지수 백오프 (exponential backoff).** `1`초 → `2`초 → `4`초. 재시도할수록 더 기다림.

**`A안` 으로 선택했다. 프로젝트 구조상 지수 백오프가 불필요하다.**

지수 백오프는 "다수의 클라이언트가 동시에 한 서버를 때려서 thundering herd가 일어나는" 상황을 위한 거다. 근데 이 프로젝트는 `GitHub Actions`에서 **하루 한 번, 단일 프로세스**로 돈다. 동시성이 없다. `yfinance`/`Slack` 서버에 가하는 부하는 무시할 수준이고, 이 요청이 thundering herd의 일부가 될 일도 없다.

게다가 재시도 3회가 다 깨지면 어차피 `sys.exit(1)`로 끝나고 `GitHub Actions`가 실패를 알린다. 이 프로젝트엔 "빠르게 3번 시도해보고 안 되면 깔끔하게 죽기"가 맞지, "`8`초까지 늘려가며 매달리기"가 아니다. `Actions job`엔 시간 제한도 있다.

> "재시도 = 지수 백오프"는 거의 정답인 답 이지만, **단일 프로세스, 하루 1회 는 고정 대기가 맞다.**

## `common/retry.py` 전체 코드

```python
import functools
import logging
import time
from typing import Callable, TypeVar

from src.common.errors import ApiResponseError, NetworkError

logger = logging.getLogger(__name__)

T = TypeVar("T")


def _is_retryable(exc: Exception) -> bool:
    if isinstance(exc, NetworkError):
        return True
    if isinstance(exc, ApiResponseError):
        return exc.status_code == 429 or exc.status_code >= 500
    return False


def retry(
    max_attempts: int = 3,
    delay: float = 2.0,
) -> Callable[[Callable[..., T]], Callable[..., T]]:


    def decorator(func: Callable[..., T]) -> Callable[..., T]:
        @functools.wraps(func)
        def wrapper(*args: object, **kwargs: object) -> T:
            for attempt in range(1, max_attempts + 1):
                try:
                    return func(*args, **kwargs)
                except Exception as e:
                    is_last = attempt == max_attempts
                    if is_last or not _is_retryable(e):
                        raise
                    logger.warning(
                        f"{func.__name__} 실패 "
                        f"(시도 {attempt}/{max_attempts}): {e} "
                        f"— {delay}초 후 재시도"
                    )
                    time.sleep(delay)
            raise AssertionError("retry 루프 불변식 위반")

        return wrapper

    return decorator
```
> Docstring 제외, Docstring 포함 파일은 Github repo 참고

- **1. 이 데코레이터의 광역 캐치는 예외를 먹지 않는다** — `_is_retryable`이 `False`면 즉시 `raise`로 통과시킨다. 잡되 안 먹는다. 정체불명 예외(코드 버그 등)도 여기 잡히지만 `_is_retryable`이 `False`라 그대로 전파된다. 광역 캐치가 안전한 건 "잡은 걸 반드시 다시 판정해서 흘려보내기" 때문.
- **2. `is_last`를 `_is_retryable`보다 먼저 본다.**  마지막 시도면 재시도 가능 여부와 무관하게 무조건 전파.(더 시도할 횟수가 없으니까) 
- **3. 루프는 `return`(성공) 아니면 `raise`(실패 전파)로만 빠져나간다.**`for`가 정상 종료될 길이 없다.  그럼에도 추가한건, **불변식의 안전망이다.**

## 이번 글에서 배운 것
1. **예외와 정책은 다른 계층이다.** 예외 클래스는 "무슨 일이 일어났는가"라는 사실만 담고, "그래서 재시도하는가"라는 정책은 데코레이터가 갖는다. 정책은 바뀌고 사실은 안 바뀌므로 분리해두는 게 변화에 강하다.
2. **`from e` 체이닝.**  문자열 보간으로 raw 예외를 죽이지 않는다. `Java` 생성자 `cause` 인자와 의미는 같지만 문법이 분리돼 있어 예외 클래스 생성자가 더 단순해진다.
3. **데코레이터는 함수를 교체하는 것이다.** `Java` 어노테이션이 메타데이터를 붙이는 선언이라면, `Python` 데코레이터는 원본 함수를 wrapper로 **갈아치우는 실행**이다. 그래서 `functools.wraps`로 원본 메타데이터를 손으로 복사해줘야 하고, 클로저로 파라미터(`max_attempts`, `delay`)를 잡아둔다. AOP 비슷한 결과를 내지만 메커니즘은 완전히 다르다.
4. **재시도 = 지수 백오프는 무조건적인 정답이 아니다.** 단일 프로세스, 하루 1회 시스템에서 지수 백오프는 푸는 문제 자체가 없다.

## What's Next

**`Phase 3-b`: 어댑터 7개 수정 + `main.py`의 `except` 좁힘**

- `yfinance` 계열 4개 어댑터 — `try` 블록을 호출/파싱으로 분리, `NetworkError`/`ParseError` 번역, `@retry` 부착
- `Slack`/`Discord` 어댑터 — `requests.HTTPError` → `ApiResponseError` 번역, `except` 순서 철칙
- `Gemini` 어댑터 — SDK 예외를 번역하지 않는 비대칭
