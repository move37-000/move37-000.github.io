---
title: "throws 한 줄, 컴파일러까지 내려간 기록"
date: 2026-07-15
categories: [Curiosity, Java]
tags: [java, exception, checked, unchecked, JLS, javac, SneakyThrows, mybatis, spring, retrospective]
---

이력 저장 기능을 개발하던 중, repository 인터페이스에 이런 시그니처가 있었다.

```java
void saveHistory(...) throws ServletException, IOException, SQLException;
```

내가 만든 시그니처다. 정확히는, **무의식적으로 복붙하다 나온 거다.** 늘 하던 대로 어딘가의 시그니처를 가져다 붙였고, 늘 그랬듯 잘 돌아갔고, 그래서 한 번도 의심하지 않았다.

그런데 이번엔 걸렸다. 이걸 호출하는 서비스에서 "그냥 시그니처에 `throws`로 올려버릴까? 어차피 컨트롤러에서 전역으로 잡는데" 라고 생각했다. 그런데, **MyBatis 매퍼가 `ServletException`을 던질 일이 대체 뭐가 있지?**

## 던질 리 없는 예외가 시그니처에 있었다
답은 "없다"였다. 이 인터페이스는 MyBatis 쿼리 하나를 실행할 뿐이다. 서블릿 API를 사용하지도, 파일 IO를 하지도 않는다. `ServletException`과 `IOException`은 **웹 계층의 예외인데 영속 계층 시그니처까지 침범한 것이고**, 출처는 내 복붙이었다.

그럼 `SQLException`은? 쿼리를 실행하니 이건 맞는 거 아닌가. 하지만 알고보니 **mybatis-spring 환경에서 매퍼는 `SQLException`을 밖으로 던지지 않는다.**

매퍼 인터페이스의 구현체는 내가 만들지 않는다. MyBatis가 런타임에 동적 프록시로 만들어 넣는다. 그리고 쿼리에서 터진 `SQLException`은 그 프록시 경계 안에서 이미 번역된다.

```
매퍼 호출 → MapperProxy → JDBC에서 SQLException 발생
          → MyBatisExceptionTranslator가 번역
          → DataAccessException 으로 프록시 밖으로 나옴
```

하나의 포괄적인 예외가 아니라, SQL 에러코드를 보고 `DuplicateKeyException`, `BadSqlGrammarException` 같은 **의미 있는 하위 타입으로 분류**해서 던진다. DB가 Oracle이든 MySQL이든 같은 추상 타입으로 잡을 수 있게 하는 게 이 계층의 존재 이유다.

매퍼 시그니처의 `throws` 세 개는 전부 지우는 게 맞았다. 그런데 지우고 실험해보니 이상한 게 하나 있었다. **`DataAccessException`이 매퍼에서 나가는데, 서비스에서 아무 처리를 안 해도 컴파일이 된다.** `SQLException`이었을 땐 컴파일러가 "잡거나 선언하라"고 강제했는데.

여기서 의문이 생겼다. **같은 예외인데 왜 어떤 건 강제당하고 어떤 건 강제당하지 않는가?**

## checked / unchecked
Java의 예외처리 규칙에는 두 가지 기준이 있다.
- **checked**: 컴파일러가 "이 예외 던지는 코드를 부를 거면 반드시 잡거나(`try-catch`) 선언(`throws`)하라"고 강제한다. 안 하면 컴파일 자체가 안 된다.
- **unchecked**: 컴파일러가 아무것도 강요하지 않는다. 안 잡으면 상위로 전파된다.

그리고 이 둘을 가르는 기준은 단 하나, **상속 계보 중 `RuntimeException`이 있느냐**다.

```
Throwable
├── Error                  (unchecked)
└── Exception              (checked)
    └── RuntimeException   (unchecked)  ← 여기가 분기점
```

`DataAccessException`의 계보를 직접 따라가 봤다. `DataAccessException → NestedRuntimeException → RuntimeException`. 중간에 `RuntimeException`을 거친다. 그래서 unchecked. 반면 `SQLException`은 `RuntimeException`을 거치지 않고 곧장 `Exception`이다. 그래서 checked.

순수 JDBC 시절엔 checked인 `SQLException` 때문에 모든 계층이 try-catch나 `throws`를 짊어져야 했다. 그런데 SQL 에러는 대부분 그 자리에서 복구가 안 된다. 쿼리 문법이 틀린 걸 런타임에 고칠 순 없으니까. 그래서 스프링은 checked `SQLException`을 unchecked `DataAccessException` 계층으로 번역한다.

> 복구도 못 할 예외를 모든 계층에 강제로 잡게 하는 건 코드만 더럽힌다.

여기까지는 납득이 됐다. 그런데 궁금해서 `RuntimeException` 소스를 열어봤다가, 예상과 다른 걸 발견했다.

## RuntimeException 안에는 아무것도 없다
분기점의 근거를 찾으려고 열었는데, 안에 있는 건 생성자 몇 개가 전부였다.

```java
public class RuntimeException extends Exception {
    public RuntimeException() { super(); }
    public RuntimeException(String message) { super(message); }
    // ... 생성자들뿐
}
```

`Exception`과 구조가 사실상 같다. 필드도, 특별한 로직도 없다. 게다가 `RuntimeException`도 결국 `Exception`을 상속한다. **그럼 대체 어디서 checked와 unchecked가 갈리는 건가?**

규칙은 두 곳에 나뉘어 있었다.
1. **JLS(자바 언어 명세)** — 규칙이 글로 적힌 곳. JLS 11장이 "`RuntimeException`과 `Error` 및 그 하위는 unchecked, 나머지 `Exception`은 checked"라고 정의한다.
2. **javac(컴파일러)** — 규칙을 집행하는 곳. 컴파일 시점에 예외 타입의 상속을 타고 올라가면서 `RuntimeException`을 만나면 통과시키고, 못 만나면 "잡거나 선언하라"며 컴파일을 거부한다.

즉 `RuntimeException`은 특별한 로직을 가진 클래스가 아니라, **컴파일러가 참조하는 기준점 역할만 하는 빈 껍데기**다. 소스에서 못 찾은 게 착각이 아니라, 원래 거기 없는 게 맞았다.

그리고 이 검사는 **컴파일 타임에만 존재한다.** 실행 시점의 JVM은 checked/unchecked를 아예 구분하지 않는다. JVM에게는 `ServletException`이든 `RuntimeException`이든 그냥 다 같은 `Throwable`이다.

여기까지 오니, 눈으로만 확인한 게 찜찜했다. 명제가 세 개로 정리됐고, 셋 다 손으로 검증할 수 있는 것들이었다.

## 손으로 검증하기

### 실험 1 — 구분은 "내용"이 아니라 "상속 계보"
본문이 똑같이 텅 빈(`{}`) 예외 클래스 두 개를 만들었다. 차이는 `extends` 뒤 한 단어뿐이다.

```java
class MyChecked extends Exception {}
class MyUnchecked extends RuntimeException {}
```

`MyUnchecked`는 `throws` 선언 없이 던져도 컴파일이 통과한다. `MyChecked`를 선언 없이 던지면

![](/assets/img/posts/curiosity/java/curiosity-java-1-img-1.png)

![](/assets/img/posts/curiosity/java/curiosity-java-1-img-2.png)*[throw 미선언]*

throws 를 추가하면 된다. 

![](/assets/img/posts/curiosity/java/curiosity-java-1-img-3.png)

**클래스 내용이 동일한데 `extends` 뒤 한 단어로 결과가 정반대다.** 구분이 클래스 내용이 아니라 상속 계보에 있다는 증거다.

### 실험 2 — 사슬 "중간"의 RuntimeException

`DataAccessException(→ NestedRuntimeException → RuntimeException)` 구조를 비슷하게 재현했다. `Level2 → Level1 → Level0 → RuntimeException`으로 계단을 만들고, `RuntimeException`을 직접 상속하지 않는 `Level2`를 `throws` 없이 던져봤다.

```java
public class ErrorTest {

    static class Level0 extends RuntimeException {}  // RuntimeException 직접 상속
    static class Level1 extends Level0 {}            // 한 단계 떨어짐
    static class Level2 extends Level1 {}            // 두 단계 떨어짐

    static void deepThrow() {
        throw new Level2();
    }

    public static void main(String[] args) {
        Class<?> c = Level2.class;
        while (c != null) {
            System.out.println("getSimpleName: " + c.getSimpleName());
            c = c.getSuperclass();
        }

        try {
            deepThrow();
        } catch (Level2 e) {
            System.out.println("throw!");
        }
    }
}
```

[실행 결과 (3)]

최종 조상은 `Exception → Throwable`이다. 그런데도 unchecked다. **컴파일러는 "최종 조상"이 아니라 "사슬 어딘가에 `RuntimeException`이 있느냐"를 본다.**

### 실험 3 — sneaky throw, 속는 건 JVM이 아니라 컴파일러다

찾아보다 롬복의 `@SneakyThrows`를 만났다. 처음엔 "javac가 강제한 걸 JVM이 실행 중에 무효화하나?" 싶었다. 반대였다. JVM은 checked를 구분하지도 않으니 속일 대상이 아니다. **속는 건 컴파일 타임의 javac다.** 원리는 제네릭 타입 추론이다.

```java
static <T extends Throwable> void sneakyThrow(Throwable param) throws T {
    throw (T) param;
}
```

호출부에 힌트가 없으면 컴파일러는 `T`를 `RuntimeException`으로 추론한다. `throws T`가 unchecked로 보이니 강제하지 않는다. 그리고 `(T)` 캐스팅은 제네릭 소거(erasure)로 런타임엔 사라져서, 원본 checked 예외가 그대로 던져진다.

> 파라미터가 T param이 아니라 Throwable param이라 T와 연결되지 않고, 반환도 void라 T를 추론할 힌트가 어디에도 없다. 이럴 때 컴파일러는 T를 RuntimeException으로 추론한다.

```java
public class ErrorTest {
    static <T extends Throwable> void sneakyThrow(Throwable param) throws T {
        throw (T) param;
    }

    public static void main(String[] args) {
        sneakyThrow(new MyChecked());
    }
}
```

위 소스를 실제로 돌려보면, `throws`도 try-catch도 없는 메서드에서 런타임에 `MyChecked`(checked)가 튀어나온다.

[에러 사진 4]

하지만 이렇게 나가는 checked 예외를 **명시적으로 잡으려 하면 오히려 컴파일 에러가 난다.**

[에러 사진 5]

컴파일러 입장에선 이 예외가 여기서 던져질 리 없다고 믿으니, catch를 "도달 불가능"으로 판정하는 것이다. **컴파일러가 예외의 존재 자체를 못 보고 있다**는 증거다.

## 그래서 어떻게 잡을 것인가
컴파일러까지 내려갔다 돌아오니, 처음의 질문이 다르게 보였다. "서비스 시그니처에 `throws`로 올릴까?"가 아니라 **"이 예외를 잡을 이유가 있는가?"** 가 맞는 질문이었다.

정보를 더 찾아보고 생각을 정리하니 결과가 명확했다. **의미 있는 처리를 할 수 있을 때만 잡고, 아니면 흘려보낸다.** 계층마다 잡아서 로그 찍고 다시 던지는 건 로그만 중복시키는 안티패턴이다. 안 잡아도 정보는 사라지지 않는다.

예외는 스택 트레이스를 계속 들고 다니고, 감쌀 때 원본을 cause로 넘기면(`new ...Exception(code, e)`) 뿌리까지 보존된다. **정보 유실을 결정하는 건 어느 계층에서 잡느냐가 아니라, throwable째로 로깅하고 cause를 끊지 않느냐다.**

흘려보내지 않고 잡아야 할 경우로는

| Case | Reason |
| :--- | :--- |
| 도메인 번역 | 인프라 예외를 비즈니스 의미가 있는 예외로 바꾼다 |
| 보상/폴백 | 재시도, 대체 경로 등 실질적 대응을 한다 |
| 정책 강제 | "이 실패는 전체 실패다" 같은 실패의 의미를 규정한다 |

그리고 내 케이스는 이 중 두 개에 해당했다.

**이력 저장 실패는 인증 전체의 실패다.** 공기업 폐쇄망에서 이력은 매우 중요하다. 이력이 안 남았는데 사용자에게 성공을 돌려주면, 시스템 관점에서 그 요청은 **존재하지 않는 조회**가 된다. 나중에 사용자가 "난 성공했다"고 주장해도 대조할 근거가 없다. 이로 인해 이력이 실패하면 전체를 실패시키는 방식으로 해야 했다. 이건 예외 처리 스타일 문제가 아니라 도메인 요구사항이고, 이 요구사항이 "잡을지 말지"를 결정했다.

최종적으로 매퍼 시그니처의 `throws` 세 개는 삭제, 서비스에서 저장 실패만 잡아 도메인 예외로 감싼다.

```java
} catch (DataAccessException e) {
    throw new HistorySaveException(HISTORY_SAVE_FAILED, e);  // cause 보존
}
```

이러면 컨트롤러의 `catch (HistorySaveException)`으로 떨어져 에러 코드가 살아남는다. 그냥 raw로 흘렸다면 `catch (Exception)`에 걸려 "시스템 오류가 발생했습니다."로 뭉개졌을 것이다. 애써 만든 에러 코드 체계를 살리는 것도 "잡을 이유"의 일부였다.

## 정리

- checked/unchecked의 "check" 주체는 컴파일러다. checked는 컴파일러가 처리(잡기/선언)를 강제하고, unchecked는 강제하지 않는다.
- 구분 기준은 클래스 내용이 아니라 **상속 사슬에 `RuntimeException`이 있느냐**다. `RuntimeException` 자체는 로직 없는 기준점(marker)이다.
- 규칙은 JLS가 정의하고 javac가 컴파일 타임에 집행하며, **JVM은 실행 중 이 구분을 신경 쓰지 않는다.** 그래서 컴파일러(제네릭 타입 추론)만 가리면 checked도 선언 없이 던질 수 있다.
- mybatis-spring 매퍼는 `SQLException`을 밖으로 던지지 않는다. 프록시 안에서 unchecked인 `DataAccessException` 계층으로 번역돼 나온다. 매퍼 시그니처의 `throws`는 필요 없다.
- 예외는 기본적으로 흘려보내고, **도메인 번역 / 보상 / 정책 강제** 세 가지 이유가 있을 때만 잡는다. 정보 보존의 관건은 잡는 위치가 아니라 cause 체인과 throwable 로깅이다.
- 커스텀 예외의 checked/unchecked 선택은 "호출자가 복구할 수 있는가"라는 질문에 대한 답을 상속 구조로 선언하는 것이다.

복붙 한 줄에서 시작했다. 늘 하던 복붙이 잘 돌아가는 상태에서, 왜 돌아가는지 아는 상태로 되었다. 이제 저 세 개의 `throws`는 지웠지만, 그게 왜 지워져야 하는지는 지워지지 않았다.
