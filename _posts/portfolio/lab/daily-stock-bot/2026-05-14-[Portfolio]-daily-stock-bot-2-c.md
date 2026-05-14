---
title: Daily Stock Bot 리팩토링 - 2-c. Notifier · Analyzer · 조립
date: 2026-05-14
categories: [Python, Project]
tags: [python, refactoring, hexagonal-architecture, adapter, dependency-injection, fail-fast, exit-code]
image:
---

## Daily Stock Bot 리팩토링 #2-c

### 이번 Phase의 목표
`Phase 2`의 마지막 어댑터들과 조립을 다룬다.

- **알림 어댑터 2개** — `SlackNotifier`, `DiscordNotifier` (webhook 기반)
- **AI 어댑터 + 프롬프트 빌더** — `GeminiAnalyzer` + `prompt_builder.py`
- **`main.py`** — 어댑터 8개의 DI 조립 + 단계별 예외 처리 + exit code 정책
- **도메인 보정 마무리** — `DailyReport.analysis` 필드 추가, `Notifier` 생성자 검증

## 시작하기 전에

### 1. HTML 리포트 어댑터 누락 — Phase 0 로드맵의 또 다른 공백
`Phase 0` 로드맵에는 `Notifier`/`Analyzer` 어댑터는 있었지만 **HTML 리포트 생성 어댑터가 없다**. 원본 `main.py`의 `generate_report()`가 HTML을 만들어 `GitHub Pages`에 배포했는데, `Phase 2` 에서 누락이 되어버렸다.

→ `Phase 2`에서는 HTML 리포트 생성을 **제외**. `Notifier`의 `report_url` 인자는 외부에서 주어진다는 전제로 유지(이전 빌드의 HTML이 `GitHub Pages`에 남아있으면 그대로 사용). HTML 리포트 어댑터는 별도 작업으로 추가 예정.

### 2. fail-fast 일관 적용
`GeminiAnalyzer`를 만들면서 "`API_KEY`가 비어있으면 어댑터 생성 자체를 실패시키자"는 결정을 했다. 그러고 보니 `SlackNotifier`, `DiscordNotifier`도 `webhook_url`이 빈 문자열일 때 같은 검증이 없었다. 일관성을 위해 두 어댑터에 검증 로직을 추가했다.

> **외부 의존성(`API_KEY`, `webhook_url`)의 누락은 어댑터 생성 시점에 잡는다.** 사용 시점(`send()` 호출 시)에 잡으면 늦다.

### 3. `DailyReport.analysis` 필드 추가
`MarketAnalyzer.analyze()` 결과를 담을 자리. `DailyReport`에 `analysis: str | None = None` 필드를 추가. AI 분석은 보조 정보라 실패 시 `None` 유지 — 호출측이 `try/except`로 처리한다.

## 알림 어댑터 — `SlackNotifier` / `DiscordNotifier`

| 항목 | `SlackNotifier` | `DiscordNotifier` |
| :--- | :--- | :--- |
| 페이로드 | `{"text": ..., "blocks": [...]}` | `{"embeds": [{...}]}` |
| 볼드 문법 | `*bold*` (`mrkdwn`) | `**bold**` (`markdown`) |
| 가격 강조 | 없음 | 백틱 (`` `5,234` ``) |
| 리포트 버튼 | Block Kit `actions` 블록 | 마크다운 링크 |
| 메시지 조립 메서드 | `_build_message` + `_build_blocks` | `_build_description` |

생성자 / 예외 처리 / 타임아웃 정책은 동일하다.

```python
class SlackNotifier(Notifier):
    def __init__(self, webhook_url: str, timeout: float = 10.0) -> None:
        if not webhook_url:
            raise ValueError("Slack webhook_url이 비어있다")
        ...

    def send(self, report: DailyReport, report_url: str | None = None) -> None:
        ...
        response = requests.post(self._webhook_url, json=payload, timeout=self._timeout)
        response.raise_for_status()
```

### `AbstractNotifier`를 만들지 않은 이유
`Java/Spring`이라면 `AbstractWebhookNotifier`에 공통 인프라(HTTP 호출, 타임아웃, 예외 전파)를 모으고 자식들이 `buildPayload()`만 `override`하는 패턴이 자연스럽다. 하지만

- 현재 `Notifier` 2개. `Rule of Three` 해당 안됨.
- 실제 중복은 `requests.post + raise_for_status + timeout` 3줄 정도.
- `Python`의 `Protocol` 기반 구조에서 추상 클래스는 "객체지향 본능"이지 `Python` 관용이 아니다.

### Slack 메시지의 KR 섹션 제거
원본 메시지는 한국 종목/지수도 포함했지만, 한국 주식은 사용하지 않기에 제거.

## AI 어댑터 — `GeminiAnalyzer` + `prompt_builder.py`

### 왜 분리했나
원본 `ai_service.py`는 한 파일에 프롬프트 조립과 `Gemini API` 호출이 같이 들어 있었다. 이걸 두 책임으로 분리한다.

| 책임 | 위치 |
| :--- | :--- |
| 프롬프트 빌드 (`DailyReport` → 프롬프트 문자열) | `prompt_builder.py` (모듈 함수) |
| Gemini API 호출, 모델 폴백, 응답 파싱 | `GeminiAnalyzer` (클래스) |

 **서로 하는 일이 다르다**.

- API 호출 로직이 바뀌는 이유: `Gemini SDK` 변경, 폴백 정책 변경.
- 프롬프트가 바뀌는 이유: AI 출력 품질 개선, 프롬프트 엔지니어링.

단일 책임 원칙을 적용했다. 

### `GeminiAnalyzer` — 모델 폴백 체인
```python
def analyze(self, report: DailyReport) -> str:
    client = genai.Client(api_key=self._api_key)
    prompt = build_prompt(report)
    errors: list[tuple[str, Exception]] = []

    for model in self._models:
        try:
            response = client.models.generate_content(model=model, contents=prompt)
            return response.text.strip()
        except Exception as e:
            errors.append((model, e))

    raise RuntimeError(f"모든 Gemini 모델 실패: {errors}")
```

모델별 제약사항이 복잡해 풀백이 반필수다. 풀백은 어댑터의 구현 디테일이지 추상화 대상이 아니기에 `FallbackMarketAnalyzer` 같은 `Composite` 패턴으로 별도 어댑터를 만들지 않고 어댑터 내부에 포함.

| 항목 | 원본 | 어댑터 |
| :--- | :--- | :--- |
| API 키 누락 | `None` 반환 | 생성자에서 `ValueError` (fail-fast) |
| 모든 모델 실패 | `None` 반환 | `RuntimeError` 발생 |

`None` 반환은 호출측이 분석 실패와 빈 결과를 구분하지 못한다.

### `prompt_builder.py`
`DailyReport`에서 지수/환율/종목 + 작성 규칙을 조합한 프롬프트 문자열을 만든다.

| 항목 | 원본 | 신규 |
| :--- | :--- | :--- |
| 작성 규칙 번호 | `3.` 두 번 (번호 중복) | 1~6 순차 |
| 환율 데이터 | **누락** (`usd_krw`를 받지도 않음) | 데이터 섹션에 포함 |
| 한국어 표현 | "최대한 참고하면서 설명도" | 자연스럽게 정리 |
| 한국장 데이터 | 포함 | 제외 (`Phase 2` 범위) |

## `main.py` — DI 조립
8개 어댑터를 묶고, 데이터를 수집하고, 알림을 보낸다.

### 옵셔널 어댑터 패턴
```python
slack_notifier: Notifier | None = None
if SLACK_WEBHOOK_URL:
    slack_notifier = SlackNotifier(webhook_url=SLACK_WEBHOOK_URL)
```

`webhook_url`/`api_key`가 누락된 경우 어댑터를 만들지 않고 `None` 유지. 사용 시점에 `if notifier is not None:` 분기처리를 한다. 

### 단계별 예외 처리

| 단계 | 실패 시 |
| :--- | :--- |
| 어댑터 생성 (env 누락) | fail-fast → `sys.exit(1)` |
| 미국 종목 수집 | 실패 → `sys.exit(1)` |
| 미국 지수 수집 | 실패 → `sys.exit(1)` |
| 환율 수집 | 실패 → `sys.exit(1)` |
| 시장 뉴스 수집 | 어댑터가 `[]` 격리 |
| AI 분석 | 실패해도 진행 (`analysis = None`) |
| Slack/Discord 전송 | 모두 실패 시에만 `sys.exit(1)` |

어느 단계 실패인지 명확하게 하기 위해 단계별 `try/except`로 분리했다.

### `DailyReport` 조립 + AI 분석
`DailyReport`는 `frozen=True` (immutable). AI 분석 결과를 나중에 채우려면 `dataclasses.replace`를 쓴다.

```python
report = DailyReport(date=..., us_stocks=..., us_market=..., exchange_rate=..., us_news=...)

if analyzer is not None:
    try:
        analysis = analyzer.analyze(report)
        report = replace(report, analysis=analysis)
    except Exception as e:
        logger.error(f"AI 분석 실패: {e}", exc_info=True)
```

### exit code 정책
**알림 1개라도 성공하면 exit 0**. 둘 다 실패해야 exit 1. `GitHub Actions`가 이 exit code로 실패를 감지하고 알림을 보낸다.

## 디렉토리 구조
```
src/
├── adapter/
│   ├── _yfinance_common.py
│   ├── yfinance_fetcher.py
│   ├── yfinance_index_fetcher.py
│   ├── yfinance_exchange_rate_fetcher.py
│   ├── yfinance_market_news_fetcher.py
│   ├── slack_notifier.py
│   ├── discord_notifier.py
│   ├── gemini_analyzer.py
│   └── prompt_builder.py
├── common/
│   └── date_utils.py
├── domain/
│   ├── stock.py
│   ├── news.py
│   ├── market.py
│   └── report.py
├── port/
│   ├── stock_fetcher.py
│   ├── index_fetcher.py
│   ├── exchange_rate_fetcher.py
│   ├── market_news_fetcher.py
│   ├── notifier.py
│   └── market_analyzer.py
├── config.py
└── main.py
```

## 개선

### `main.py` 변화

| 항목 | 원본 | 신규 |
| :--- | :--- | :--- |
| 책임 | DB + 크롤러 + 변환 + 리포트 + 알림 (모두 직접) | 어댑터 조립 + 흐름 제어 |
| 라인 수 | 169줄 | 약 130줄 |
| DB 초기화 | `init_db()` | **제거** (`Phase 5` cleanup) |
| 데이터 변환 | `transform_us_data` 등 | **제거** (어댑터가 도메인 객체 직접 반환) |
| exit code | 없음 (return으로 종료) | `sys.exit(1)` 명시 |

### `Phase 2` 전체 결과 (미국 파이프라인)

| 항목 | Phase 1 직후 | Phase 2 완료 |
| :--- | :--- | :--- |
| 도메인 모델 | 5개 (`StockSnapshot` 외) | 7개 (`DailyReport`, `PricePoint` 추가) |
| `Port` | 0개 | 6개 |
| `Adapter` | 0개 | 8개 + `prompt_builder` |
| 외부 의존 위치 | 서비스 레이어 | 어댑터 레이어로 격리 |
| 테스트 가능성 | 네트워크 필수 | `Port` mock 주입 가능 |
| `Phase 7` KR 추가 비용 | 도메인·로직 모두 수정 | **어댑터만 추가** (`Port`·도메인 불변 가설) |

## 이번 글에서 배운 것

1. **`Port` 규약이 같아도 어댑터 코드가 같지는 않다**. `SlackNotifier`/`DiscordNotifier`는 `Port`가 같지만 포맷 차이로 코드 90% 동일·10% 차이. 추상 부모 클래스로 묶는 유혹은 `Rule of Three`까지 기다린다.
2. **fail-fast는 외부 의존성 검증에 적합**. `webhook_url`, `API_KEY` 누락은 어댑터 생성 시점에. 사용 시점에 잡으면 늦다.
3. **`main.py`는 로직이 아니라 조립**. 어댑터 조립, 단계별 예외 처리, exit code 정책. 비즈니스 로직은 어댑터와 도메인에 있다.
4. **운영자 알림과 사용자 알림의 분리**. 에러는 사용자(`Slack`/`Discord`)에게 노출하지 않고 운영자(`GitHub Actions`)에게만. 이 분리가 exit code 정책의 근거.
5. **"원본 패턴 복제 금지"는 프롬프트에도 적용된다**. 코드뿐 아니라 AI에게 보내는 문장도 리팩토링 대상.

## What's Next

**`Phase 3`: Error Strategy — 예외 계층과 재시도**

`Phase 2`에서 `RuntimeError`로 통일했던 예외를 의미 단위로 분리한다.
- 네트워크 오류, 파싱 오류, API 응답 오류를 구분하는 예외 계층
- 어댑터 단위 재시도 데코레이터 (`@retry`)
- 단계별 재시도 정책 (`StockFetcher`는 3회, `Notifier`는 1회 등)

`Phase 2`에서 미뤘던 `response.text` 비정상 응답 검증, `top_gainer` 빈 리스트 검증도 같이 처리.