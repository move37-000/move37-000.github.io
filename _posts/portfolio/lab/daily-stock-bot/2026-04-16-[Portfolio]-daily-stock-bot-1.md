---
title: Daily Stock Bot 리팩토링 - 1. Domain Model로 dict 지옥 탈출
date: 2026-04-16
categories: [Python, Project]
tags: [python, refactoring, dataclass, domain-model, type-safety, enum, property]
image:
---

## Daily Stock Bot 리팩토링 #1

### 이번 Phase의 목표
`Phase 0`에서 확인한 가장 근본적인 문제인 **`dict[str, Any]` 기반 데이터 전달**을 타입이 있는 도메인 모델로 전환한다.

결론부터 말하면, `symbol`과 `name`이 뒤바뀌던 버그가 **구조적으로 불가능**해졌고, 표현 로직이 여러 곳에 반복되던 문제가 `@property` 캡슐화로 한 곳에 모였다. 외부 API 응답에 의존하던 데이터 흐름을 시스템의 도메인 개념이 주도하는 흐름으로 뒤집은 것이 이번 `Phase`의 핵심이다.

### dataclass
`Java/Spring`에서는 `DTO/VO`를 사용하는 것이 당연하다. `Entity`, `Request`, `Response`를 명시적 타입으로 분리하고, 각 레이어 간에는 이 타입들만 주고받는다. `Python`에서도 `dataclass`, `Pydantic`이 같은 역할을 한다.

이 프로젝트에서는 **`dataclass`를 선택**했다.
- 외부 API 응답을 파싱하는 게 아니라 **내부적으로 정리된 데이터를 전달**하는 용도이므로 `Pydantic`의 런타임 `validation`이 과하다.
- 표준 라이브러리이므로 외부 의존성이 늘지 않는다.
- `Java`의 `record`, `Lombok @Value`와 개념이 완전히 동일해서 익숙하다

## Phase 0 → Phase 1 변경점
```
Phase 0: 크롤러가 dict 반환 → 서비스가 dict key로 접근 → 트랜스포머가 dict 변환 → 알림이 dict key로 접근
Phase 1: 도메인 모델 정의 완료 (크롤러/서비스 연결은 Phase 2에서)
```

`Phase 1`은 **도메인 모델 정의만** 수행한다. 도메인을 먼저 안정화시킨 뒤에 외부 레이어를 붙이는 **안에서 밖으로의 접근(Inside-Out)** 이 목적이기 때문이다.

## 설계 순서 — 왜 도메인이 가장 먼저인가
**외부에서 안으로 (Outside-In)**
- "yfinance에서 데이터를 가져와야지" → 함수 작성 → 반환값은 dict(가장 빠르니까) → 다음 단계가 그 dict를 받는다
- **외부 API의 응답 형태가 코드 전체의 데이터 구조를 결정**한다.

**안에서 밖으로 (Inside-Out, 도메인 중심)**
- "이 시스템이 다루는 핵심 개념이 뭐지?" → 개념을 표현하는 타입 정의 → 외부 `API`는 그 타입을 만들어내는 도구가 된다.

원본 코드는 전자다. `yfinance`가 반환하는 `dict` 구조가 크롤러, 서비스, 트랜스포머, 알림 레이어까지 그대로 흘러갔다. 극단적으로, **"`yfinance`를 다른 라이브러리로 바꾸세요"** 라는 요청이 오면 모든 레이어를 다 수정해야 한다.

이번 리팩토링은 도메인 중심으로 변경한다. 도메인 모델 `StockSnapshot`을 먼저 정의하고, 외부 `API`는 그 모델을 만들어내는 어댑터일 뿐이다. 데이터 소스를 바꿔도 어댑터만 교체하면 끝이다.

> 진행했던 다른`Java/Spring`프로젝트들의 패키지 구조(`domain/entity/`, `application/service/`, `infrastructure/`)가 같은 구조이다. `Entity`가 가장 안쪽에, `Infrastructure`가 가장 바깥에 있는 이유는 **도메인은 가장 안정적이고 외부는 가장 변하기 쉽기** 때문이다.

## 핵심 구현

### 1. `DailyPrice` — 가장 단순한 값 객체
하루치 `OHLCV`(시가/고가/저가/종가/거래량)가 시세 데이터의 기본 단위다.

```python
from dataclasses import dataclass 


@dataclass(frozen=True)
class DailyPrice:
    """하루치 OHLCV 시세 데이터
    
    시세 데이터는 본질적으로 불변이므로 frozen=True로 설정.
    date는 "YYYY-MM-DD" 형식의 ISO 8601 문자열.
    """
    date: str
    open: float
    high: float
    low: float
    close: float
    volume: int
```

**1. `@dataclass` 사용**

`Python 3.7+`에서 데이터를 담는 클래스의 표준이다. `__init__`, `__repr__`, `__eq__`가 자동 생성된다. `Java`의 `record`와 같은 개념이다.

**2. `frozen=True` (불변 객체)**

시세 데이터는 본질적으로 불변이다. 데이터를 조회하는 순간 그 종목의 종가는 이미 확정된 값이므로, 코드에서 이 값을 바꾼다는 건 말이 안 된다.

```python
price = DailyPrice(date="2026-04-15", open=100, high=105, low=99, close=103, volume=1000)
price.close = 200  # FrozenInstanceError: cannot assign to field 'close'
```

`Java` 에서 `VO(Value Object)는 불변이어야 한다`는 원칙과 같다. 또한, 불변 객체는 `hashable`이 되어 `set`의 원소나 `dict`의 키로 사용할 수 있다.

**3. 타입 힌트 필수**

`dataclass`는 **타입 힌트가 있어야** 필드로 인식된다.

```python
@dataclass
class Wrong:
    date = "hello"  # 클래스 변수로 취급됨

@dataclass
class Right:
    date: str       # 필드로 인식
```

`IDE`가 타입 체크를 해 주게 된다.

**4. `date`를 `str`로 두기 (`datetime` 대신)**

이유가 있는 결정이다.
- 리포트에 결국 `"2026-04-15"` 형식의 문자열이 들어가므로 변환 비용이 없다.
- `ISO 8601` 형식은 문자열 비교가 그대로 날짜 비교와 같다.
- 외부 `API(yfinance, KRX)`의 날짜 포맷이 제각각이라, 어댑터에서 통일된 문자열로 정규화하는 게 경계가 명확하다.

**이 프로젝트에서는 날짜 계산이 거의 없고 표시/정렬 위주**이므로 `str`을 선택했다. 날짜 계산이 많다면 `datetime.date`로 진행했을 것이다.

### 2. `StockSnapshot` — 종목 하나의 완전한 상태
`DailyPrice`를 사용해 더 큰 개념인 "종목 스냅샷"을 정의한다. 원본에서 `dict`로 다루던 이 구조가 가장 문제였다.

```python
# 원본 미국 주식 (us_stock.py)
{'symbol': 'NVDA', 'close': 135.5, 'change': 2.3, 'change_pct': 1.73, ...}

# 원본 한국 주식 (kr_stock.py)
{'code': '471760', 'name': 'TIGER AI반도체', 'close': 12850.0, ...}
# 'symbol'이 아니라 'code',  미국에는 없는 'name' 필드
```

**미국과 한국의 구조가 미묘하게 다르다.** `transformer.py`가 이 둘을 통일하려다가 `symbol`과 `name`이 뒤바뀌는 버그를 만들었다.

**1. 미국/한국을 같은 클래스로 통합**
- 분리: `UsStockSnapshot` + `KrStockSnapshot`
- 통합: `StockSnapshot` + `market: Market` 판별 필드

실제 코드에서 미국과 한국을 **같게 다루는 코드가 훨씬 많다**. 상승/하락 카운트, `top gainer/loser` 계산, 리포트 렌더링 모두 시장 구분 없이 동일하게 처리된다. 다르게 다루는 부분은 로고 `URL`과 가격 포맷팅 정도인데, 이건 판별 필드로 분기하면 된다.

> `DDD` 관점에서 보면 "공통 개념을 상속 계층으로 만들 것인가, 판별 필드(discriminator)로 만들 것인가"의 고전적 문제다. **계층이 단순하고 행동 차이가 적으면 판별 필드가 낫다.** 상속은 행동(메서드)이 많이 다를 때 쓰는 도구다.

**2. 시장 구분은 `Enum`으로**

```python
from enum import Enum

class Market(Enum):
    US = "US"
    KR = "KR"
```

`str`로 하면 오타가 잡히지 않는다. `market="us"`(소문자)로 넣어도 에러가 나지 않고, 나중에 `if stock.market == "US"` 비교에서 아무도 모르게 실패한다. `Enum`을 쓰면 `Market.us`처럼 오타는 즉시 `AttributeError`로 터진다.

**3. `symbol` vs `name` 역할 분리**

| 필드 | 의미 | 예시 (미국) | 예시 (한국) |
| :--- | :--- | :--- | :--- |
| `symbol` | 시장에서 쓰는 고유 식별자 | `"NVDA"` | `"471760"` |
| `name` | 사람이 읽는 종목명 | `"NVIDIA Corporation"` | `"TIGER AI반도체핵심공정"` |

원본의 버그가 발생한 이유는 이 역할 분리가 되어 있지 않았기 때문이다. 이제 타입 정의에 역할이 고정되므로 뒤바뀔 수 없다.

**4. 리스트 필드는 `field(default_factory=list)`**

```python
@dataclass(frozen=True)
class StockSnapshot:
    history: list[DailyPrice] = []  # 이렇게 하면 dataclass가 에러를 낸다
```

`[]`를 기본값으로 쓰면 `ValueError: mutable default <class 'list'> for field history is not allowed`가 발생한다. 모든 인스턴스가 **하나의 리스트를 공유**하는 버그를 방지하기 위한 `Python`의 안전장치다.

해결책은 `field(default_factory=list)`:

```python
from dataclasses import dataclass, field

@dataclass(frozen=True)
class StockSnapshot:
    symbol: str
    name: str
    market: Market
    close: float
    change: float
    change_pct: float
    history: list[DailyPrice] = field(default_factory=list)
    news: list[NewsItem] = field(default_factory=list)
```

`Java`에서 생성자에 `new ArrayList<>()`를 호출하는 것과 같다.

### 3. `NewsItem` — 필드 통일로 일관성 확보
원본에서 뉴스 구조는 소스마다 달랐다.

```python
# 미국 뉴스
{'title': ..., 'link': ..., 'publisher': ..., 'time': ...}

# 한국 종목 뉴스 (publisher 없음!)
{'title': ..., 'link': ..., 'time': ...}

# 한국 시장 뉴스 (여기서만 publisher 추가)
{'title': ..., 'link': ..., 'time': ..., 'publisher': '네이버 금융'}
```

같은 "뉴스"인데 시장에 따라 구조가 달랐다. 이것도 `dict` 기반 구조의 전형적인 문제다. **필드 존재 여부가 런타임에 결정**되니까 템플릿에서 `news.publisher` 접근 시 `KeyError`가 나는지 빈 문자열이 나오는지 알 수 없다.

통일된 모델로 정의한다.

```python
@dataclass(frozen=True)
class NewsItem:
    """뉴스 기사 하나
    
    publisher와 time은 소스에 따라 없을 수 있으므로 빈 문자열을 기본값으로.
    """
    title: str
    link: str
    publisher: str = ""
    time: str = ""
```

**`None` vs 빈 문자열 선택 기준**

`publisher`의 기본값을 `None`으로 할지 `""`로 할지가 고민 지점이다.

- `None`의 장점: "진짜 없음"과 "빈 문자열"을 구분할 수 있다. `Java`의 `Optional<String>` 개념.
- `None`의 단점: 사용하는 쪽에서 항상 `if news.publisher is not None` 체크가 필요하다.

이 프로젝트에서는 **`publisher`가 "진짜 없음"인지 "빈 문자열"인지 구분할 필요가 없다.** 어느 쪽이든 `UI`에서 표시하지 않으면 되기 때문이다.

> "있음/없음"을 **의미적으로 구분**해야 하면 `None`, **단지 UI 표시 여부**만이면 빈 값(`""`, `[]`)이 낫다.

### 4. `IndexSnapshot` — `@property`로 표현 로직 캡슐화
시장 지수는 원본에서 가장 심각하게 꼬여 있던 부분이었다.

```python
# 원본 index_crawler.py
return {
    "price": f"{close:,.2f}",         # 이미 포맷팅된 문자열
    "change": change,                  # float (원본값)
    "change_pct": change_pct_str,     # "+1.73" 같은 문자열
    "history": daily_data
}
```

**`price`가 이미 포맷팅된 문자열**로 저장된다. 이 값은 계산에 다시 쓸 수 없다. `"1,234.56"`은 숫자가 아니라 표시용 문자열이다. 반면 `change`는 `float`로 남아서 `< 0` 비교는 가능하다. **일관성이 없다.**

그리고 `notification_service.py`를 보면 같은 포맷팅 로직이 반복된다.

```python
def _format_index_line(index_data, name, use_backticks=False):
    emoji = "🔴" if index_data.get('change', 0) < 0 else "🟢"
    sign = "+" if index_data.get('change', 0) >= 0 else ""
    price = index_data.get('price', '-')
    pct = index_data.get('change_pct')
    ...
```

`emoji`, 부호 계산이 `Slack`, `Discord`, 템플릿 각각에 비슷하게 반복된다. 안티 패턴이다.

도메인 모델은 **가공되지 않은 원본값**만 저장하도록 한다. 포맷팅된 문자열이 필요하면 `@property`로 계산한다.

```python
@dataclass(frozen=True)
class IndexSnapshot:
    """시장 지수 스냅샷 (S&P 500, KOSPI 등)"""
    name: str
    price: float           # 원본 float
    change: float          # 원본 float
    change_pct: float      # 원본 float
    history: list[DailyPrice] = field(default_factory=list)
    
    @property
    def is_up(self) -> bool:
        """상승 여부 (0 포함)"""
        return self.change >= 0
    
    @property
    def formatted_price(self) -> str:
        """천단위 콤마 + 소수점 2자리 (예: '5,234.56')"""
        return f"{self.price:,.2f}"
    
    @property
    def formatted_change_pct(self) -> str:
        """부호 포함 변동률 (예: '+1.73', '-0.45')"""
        return f"{self.change_pct:+.2f}"
    
    @property
    def emoji(self) -> str:
        return "🟢" if self.is_up else "🔴"
```

`@property`는 메서드를 속성처럼 호출할 수 있게 하는 데코레이터다. `Java getter`와 개념은 같지만 사용법이 다르다.

```java
// Java: 괄호 필수
index.getFormattedPrice();
```

```python
# Python: 속성처럼 접근
index.formatted_price
```

호출자 입장에서 **필드인지 계산된 값인지 구분할 필요가 없다.** `index.price`든 `index.formatted_price`든 같은 문법이다. 그래서 처음엔 필드로 노출했다가 나중에 계산으로 바꿔도 **호출부를 수정할 필요가 없다.**

### 5. `MarketOverview`, `ExchangeRate`
`MarketOverview`는 두 개의 지수를 묶는 상위 개념이다. 두 가지 선택지가 존재했다.

```python
# 선택지 A: 시장별 명시적 필드명
class UsMarket:
    sp500: IndexSnapshot
    nasdaq: IndexSnapshot

# 선택지 B (선택): 통합 + 일반화
class MarketOverview:
    market: Market
    primary: IndexSnapshot    # SP500 or KOSPI
    secondary: IndexSnapshot  # NASDAQ or KOSDAQ
```

`B`를 선택했다. **리포트 렌더링과 알림 로직을 시장과 무관하게 재사용**할 수 있기 때문이다. 실제 지수 이름은 `IndexSnapshot.name`에 이미 들어있다.

```python
for market in [us_market, kr_market]:
    print(market.primary.formatted_price)
    print(market.secondary.formatted_price)
```

시장 구분 없이 같은 루프로 처리된다.

**환율은 별도 타입으로**

```python
@dataclass(frozen=True)
class ExchangeRate:
    """환율 스냅샷 (USD/KRW 등)"""
    pair: str
    price: float
    change: float
    change_pct: float
    
    @property
    def is_up(self) -> bool:
        return self.change >= 0
    
    @property
    def formatted_price(self) -> str:
        return f"{self.price:,.2f}"
    
    @property
    def formatted_change_pct(self) -> str:
        return f"{self.change_pct:+.2f}"
```

`IndexSnapshot`과 구조가 유사하지만 **의미가 다르므로 별도 타입**이다. `DDD`에서 말하는 "같은 구조라도 맥락이 다르면 다른 타입" 원칙이다. `Order`의 `amount`와 `Refund`의 `amount`가 둘 다 `BigDecimal`이라고 해서 같은 타입으로 쓰지 않는 것과 같다.

## 최종 프로젝트 구조
```
daily-stock-bot-lab/
├── src/
│   ├── __init__.py
│   └── domain/
│       ├── __init__.py
│       ├── stock.py       # Market, DailyPrice, StockSnapshot
│       ├── news.py        # NewsItem
│       └── market.py      # IndexSnapshot, MarketOverview, ExchangeRate
├── tests/
│   └── __init__.py
├── requirements.txt
├── .gitignore
├── README.md
└── run.py
```

`domain/` 폴더만 내용이 채워져 있고, `crawler/`, `service/` 등은 아직 만들지 않았다. `Phase 2`에서 외부 어댑터를 도메인 모델과 연결하면서 자연스럽게 추가될 예정이다.

## 결과 분석

### Before/After 비교

| 항목 | Before (dict 기반) | After (도메인 모델)             |
| :--- | :--- |:---------------------------|
| 데이터 전달 | `dict[str, Any]` | 타입이 있는 `dataclass`         |
| 필드 존재 보장 | ❌ `.get()`으로 방어 | ✅ 타입이 보장                   |
| 오타 방지 | ❌ 런타임 `KeyError` | ✅ `IDE`가 즉시 잡음             |
| `symbol/name` 버그 | 실제 발생함 | 구조상 불가능                    |
| 미국/한국 구조 | 불일치 (`symbol` vs `code`) | 통일 (같은 타입)                 |
| 뉴스 `publisher` | 소스마다 있음/없음 | 항상 존재 (빈 문자열 기본값)          |
| 표현 로직 | `Slack`/`Discord`/템플릿에 반복 | `@property`에 캡슐화           |
| 지수 `price` 타입 | `str` (이미 포맷팅) | `float` (원본값) + `property` |
| 값 객체 불변성 | 없음 (`dict` 수정 가능) | `frozen=True`로 보장          |

### 표현 로직이 얼마나 줄었는가
**Before** — 8줄의 포맷팅 함수가 `Slack`, `Discord`, 템플릿 각각에 반복되었다.

```python
def _format_index_line(index_data, name, use_backticks=False):
    emoji = "🔴" if index_data.get('change', 0) < 0 else "🟢"
    sign = "+" if index_data.get('change', 0) >= 0 else ""
    price = index_data.get('price', '-')
    pct = index_data.get('change_pct')
    
    if use_backticks:
        return f"{emoji} {name} `{price}` ({sign}{pct}%)"
    return f"{emoji} {name}  {price} ({sign}{pct}%)"
```

**After** — `IndexSnapshot`에 캡슐화된 `property`를 조립만 하면 된다.

```python
def format_index_line(index: IndexSnapshot, display_name: str) -> str:
    return f"{index.emoji} {display_name} {index.formatted_price} ({index.formatted_change_pct}%)"
```

동일한 포맷팅이 여러 채널에서 필요할 때, `IndexSnapshot` 하나만 수정하면 전체에 반영된다.

### 원본 버그가 사라진 이유
원본 `transformer.py`의 `symbol/name` 뒤바뀜 버그:

```python
return {
    "symbol": stock['name'],    # 종목명이 symbol에
    "name": stock['code'],      # 종목코드가 name에
}
```

이제 이 코드가 **애초에 쓸 수 없다.**
- `dict`를 만들지 않고 `StockSnapshot`을 직접 생성한다.
- `StockSnapshot(symbol=..., name=...)`에서 각 필드의 의미가 타입 정의로 고정된다.
- `IDE`가 각 필드의 이름과 타입을 표시해준다.

## 이번 Phase에서 배운 것
1. **도메인 중심 설계** — 외부 `API`의 응답 형태가 아니라 시스템이 다루는 **개념**부터 모델링한다. 의존성 방향이 외부 → 내부(도메인)로 향해야 한다.
2. **값 객체(VO)와 `frozen=True`** — 시세, 뉴스처럼 본질적으로 불변인 데이터는 `frozen=True`로 불변성을 강제한다. 실수를 구조적으로 차단하고, `hashable`이 되어 `set/dict` 활용이 가능해진다.
3. **`dataclass` + 타입 힌트** — `Python`에서 `Java`와 유사한 수준의 타입 안전성을 얻는 가장 표준적인 방법이다.
4. **`Enum`으로 판별 필드** — 문자열 비교는 오타를 잡지 못한다. 상태/구분이 유한한 집합이면 `Enum`이 정답이다.
5. **`@property`로 표현 로직 캡슐화** — 원본값(숫자)은 필드로, 표현값(포맷팅 문자열, emoji)은 `@property`로. 외부에서는 같은 문법으로 접근하므로 나중에 구현 방식을 바꿔도 호출부가 영향받지 않는다.
6. **"같은 구조, 다른 의미"** — `IndexSnapshot`과 `ExchangeRate`가 구조적으로 유사해도 의미가 다르면 별도 타입으로 둔다. 코드 중복을 피한다는 이유로 타입을 합치면 나중에 분리할 때 비용이 더 크다.

**도메인 모델 정의의 핵심은 "데이터의 형태를 타입으로 고정한다"는 한 줄로 요약된다.** `dict[str, Any]`로 `"뭐가 들었는지는 런타임에 알아봐"`라고 했던 것을, `StockSnapshot`으로 `"이 타입에는 정확히 이 필드들이 들어있다"`라고 선언하는 것이다. 이 단순한 전환이 오타 버그, 필드 존재 여부 확인, 표현 로직 중복 등 여러 문제를 한 번에 해결한다.

## What's Next

**Phase 2: Port/Adapter — 테스터블 아키텍처**

- 현재는 도메인 모델만 정의되어 있고, 크롤러와 서비스는 여전히 원본의 `dict` 기반 구조를 쓰고 있다.
- `Protocol`(Python의 `interface`)을 정의해 크롤러의 **형태**를 명시하고, 서비스 레이어가 구체 구현(`yfinance`, `pykrx` 등)이 아닌 인터페이스에 의존하도록 전환한다.
- `KRX Open API`를 메인 소스로, 네이버 금융을 폴백 소스로 구성하여 **`FallbackIndexFetcher` 복합 어댑터 패턴**을 실전 적용한다. `Phase 0`에서 언급한 한국 지수 데이터 소스 교체 문제를 구조적으로 해결한다.
- 의존성 주입(`DI`)을 도입해 테스트 가능한 구조를 만든다. `Mock` 어댑터를 끼워 네트워크 없이 테스트할 수 있게 된다.