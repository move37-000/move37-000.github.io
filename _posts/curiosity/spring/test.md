---
title: ""
date: 2026-07-XX
categories: [Curiosity, Spring]
tags: [spring, aop, proxy, advisor, order, transaction, rollback, retrospective]
published: false
---

회사 프로젝트의 AOP 설정을 확인하다가, 예전의 내가 만들었던 소스를 다시 봤다.

```java
@Configuration
@Order(1)
public class TransactionConfig {
    // 트랜잭션 advisor 빈들...
}
```

내가 넣은 어노테이션이다. 넣을 때의 생각도 기억난다. **"트랜잭션은 제일 중요하니까, 제일 먼저 돌아야지."** 그렇게 믿고 박았고, 시스템은 몇 년을 잘 돌았고, 그래서 한 번도 의심하지 않았다.

그런데 이번에 advisor들의 실제 적용 순서를 찍어보니, 트랜잭션은 1등이 아니었다. **제일 마지막이었다.** `@Order(1)`은 아무 일도 하고 있지 않았다.

그런데도 **시스템이 멀쩡하게 돌아가고 있었다.** 예외가 터지면 비즈니스 데이터는 롤백되고, 에러 로그는 DB에 남았다. 원하던 동작 그대로. 대체 뭐가 어떻게 맞아떨어져서 굴러가고 있었던 건가.

## 1은 1등이 아니었다
먼저 `@Order`의 숫자부터. 나는 이 숫자를 **중요도**로 읽고 있었다. 작을수록 중요하고, 중요하니까 먼저 실행된다고.

절반만 맞다. 작은 숫자가 먼저 실행되는 건 맞다. 하지만 그 "먼저"의 의미가 내 생각과 달랐다.

Spring AOP는 프록시 기반이다. 대상 빈을 advisor들이 **겹겹이 감싼다.** 양파처럼. 호출은 바깥 겹부터 뚫고 들어가고, 리턴과 예외는 안쪽 겹부터 뚫고 나온다.

```
호출 →  [ order 0 ]  [ order 5 ]  [ target ]  → 실행
예외 ←  [ order 0 ]  [ order 5 ]  [ target ]  ← throw
```

`@Order`의 숫자는 이 겹에서의 **위치**다. 작은 숫자 = 바깥 겹, 큰 숫자 = 안쪽 겹. 즉 order 1은 "가장 중요한 자리"가 아니라 **"target에서 가장 먼 자리"**다.

**order는 중요도가 아니라 겹의 깊이였다.**

이 그림으로 보면 "먼저 실행된다"의 실체도 달라진다. 바깥 겹은 진입 시엔 먼저지만, **예외를 받을 땐 제일 나중이다.** 예외는 안쪽에서 바깥으로 나오니까. 중요도라는 일차원 개념으로는 이 양방향이 안 보인다.

그렇다면 내가 박은 `@Order(1)`은 왜 이 겹 어디에도 반영되지 않았는가?

## @Configuration 위의 @Order는 허공에 뜬다
회사 프로젝트의 트랜잭션은 `@Transactional`이 아니라 수동 advisor 방식이다. 포인트컷으로 서비스 구현체를 지정하고, 트랜잭션 인터셉터를 물린다.

```java
@Bean
public DefaultPointcutAdvisor txAdvisor(DataSourceTransactionManager txManager) {
        AspectJExpressionPointcut pointcut = new AspectJExpressionPointcut();
        pointcut.setExpression("execution(* com.example.demo..*Service.*(..))");

        TransactionInterceptor interceptor =
        new TransactionInterceptor(txManager, transactionAttributeSource());

        return new DefaultPointcutAdvisor(pointcut, interceptor);
        }
```

Spring이 프록시를 만들 때 보는 것은 **advisor 빈 자신의 순서 정보**다. advisor가 `Ordered` 인터페이스로 뭐라고 답하는지, 혹은 그 빈에 직접 붙은 `@Order`가 몇인지. 그 advisor를 **어느 config 클래스가 만들었는지는 보지 않는다.**

`@Configuration` 클래스에 붙인 `@Order(1)`은 config 빈 자신의 순서일 뿐, 그 안에서 생성된 advisor들에게 상속되지 않는다. 어노테이션은 문법적으로 유효하게 붙어 있었고, 컴파일러도 Spring도 아무 문제가 없었다. 그래서 **잘 돌아가는 것처럼 보였다.**

그럼 순서를 못 받은 advisor는 몇 번이 되는가. `DefaultPointcutAdvisor`의 기본값은 `Ordered.LOWEST_PRECEDENCE`, int의 최댓값이다. **가장 안쪽 겹**으로 등록된다. 내 트랜잭션은 1등으로 지정된 게 아니라, 지정이 통째로 증발해서 꼴등으로 떨어져 있었다.

> 어노테이션이 무효인데 에러도 경고도 없었다. 틀린 코드는 컴파일러가 잡아주지만, 아무 일도 안 하는 코드는 아무도 잡아주지 않는다.

여기서 처음의 진짜 의문으로 돌아온다. 트랜잭션이 의도와 정반대인 최내부에 있었는데, **왜 에러 로그는 살아남았는가?**

## 우연이 맞아떨어진 지점
회사 프로젝트의 에러 로깅은 전역 aspect가 담당한다. 서비스에서 예외가 터지면 aspect가 받아서 에러 테이블에 insert하고, 예외는 다시 위로 던진다. 비즈니스 작업은 롤백되어야 하고, 에러 로그는 남아야 한다.

이 요구가 성립하려면 조건이 하나 필요하다. **로그 insert가 롤백되는 트랜잭션 바깥에서 실행되어야 한다.**

겹의 배치를 다시 보면, 로깅 aspect는 `@Order(2)`(트랜잭션을 @Order(1) 로 설정해놔서). 트랜잭션은 order 증발로 `LOWEST_PRECEDENCE` — 최내부. 예외가 터지면:

```
[ 로깅(2) ]  [ 트랜잭션(LOWEST) ]  [ target ]
                                      ① throw
                  ② 롤백 후 재전파
     ③ 로그 insert (이 시점, 트랜잭션은 이미 없다)
```

예외가 로깅 aspect에 도달했을 때, 안쪽의 트랜잭션은 **이미 롤백을 마치고 스레드에서 내려간 뒤다.** 그래서 로그 insert는 죽은 트랜잭션에 얹히지 않고 새로 커밋된다. 비즈니스는 사라지고 로그는 남는, 정확히 원하던 결과.

그런데 이 결과를 만든 건 내 `@Order(1)`이 아니다. **어노테이션이 무효가 되면서 설정된 기본값이, 하필 정답 자리였다.** 만약 `@Order(1)`이 진짜로 먹혔다면 트랜잭션이 로깅보다 바깥이 되고, 로그 insert는 살아있는 트랜잭션 안에서 실행됐다가 함께 롤백됐을 것이다. 에러는 났는데 에러 로그는 없는 시스템. 정상적인 설계로 돌아가는게 아니라 아니라 운으로 돌아가고 있었다.

더 확실하게 알아보기 위해 테스트 코드를 만들어봤다.

## 검증
회사 프로젝트와 동일한 구조를 `com.example`로 재구성했다. Spring Boot + 인메모리 H2, 테이블 두 개(`biz_order`, `error_log`), 예외를 던지는 서비스.

```java
@Service
public class ExampleService {
    private final JdbcTemplate jdbcTemplate;

    public void placeOrder() {
        System.out.println("[target] tx active? "
                + TransactionSynchronizationManager.isActualTransactionActive());
        jdbcTemplate.update("INSERT INTO biz_order(content) VALUES ('order-1')");
        throw new RuntimeException("boom");
    }
}
```

### `@Order` 값이 작은 aspect가 바깥 겹이다.
`@Around` aspect 두 개를 만들었다. 각각 `@Order(0)`, `@Order(5)`. proceed 전후로 ENTER/EXIT만 찍는다.

```java
@Aspect
@Component
@Order(0)
public class OuterAspect {
    @Around("execution(* com.example.demo.ExampleService.*(..))")
    public Object around(ProceedingJoinPoint pjp) throws Throwable {
        System.out.println("ENTER outer(0)");
        try {
            return pjp.proceed();
        } finally {
            System.out.println("EXIT outer(0)");
        }
    }
}
```

[첫번째 이미지]

`ENTER 0 → ENTER 5 → target → EXIT 5 → EXIT 0`. 0이 바깥, 5가 안. **진입은 작은 숫자부터, 이탈은 큰 숫자부터.** 겹이라는 그림 그대로다.

### order를 지정하지 않은 트랜잭션 advisor는 최내부에 놓인다.
트랜잭션 advisor를 order 지정 없이 등록하고, 두 aspect와 target 안에서 각각 트랜잭션 활성 여부를 찍었다. `TransactionSynchronizationManager.isActualTransactionActive()`는 "지금 이 스레드에 트랜잭션이 존재하는가" 이다. 어디서 부르느냐에 따라 답이 달라진다.

[트랜잭션 설정 소스]

[두번째 이미지]

두 aspect에서는 proceed 전에도, finally에서도 **false.** target 안에서만 **true.**

aspect 입장에서 트랜잭션은 통째로 `proceed()` 안에서만 살다 죽는다. 진입 시점엔 아직 시작 전이라 false, 돌아온 시점엔 이미 커밋/롤백 후라 또 false. **트랜잭션이 두 aspect보다 깊은 겹에 있다는 뜻이다.**

### config 클래스에 붙인 `@Order(1)`은 advisor 순서에 영향이 없다.
advisor를 만드는 `@Configuration` 클래스에 `@Order(1)` 한 줄만 추가했다. 회사 프로젝트와 똑같은 형태다.

[세번째 이미지]

**결과가 똑같이 나왔다.**  트랜잭션은 여전히 최내부다. 몇 년 전의 내가 추가한 그 어노테이션은, 이 테스트에서도 똑같이 아무 일도 하지 않았다.

### 로깅이 트랜잭션보다 바깥이면, 예외 시 에러 로그가 살아남는다.
로깅 aspect를 `@Order(0)`으로 두고, `@AfterThrowing`에서 `error_log`에 insert한다. target은 `biz_order`에 insert한 뒤 예외를 던진다. 호출부에서 예외를 잡고 두 테이블을 조회했다.

```java
@Aspect
@Component
@Order(0)
public class ErrorLoggingAspect {
    private final JdbcTemplate jdbcTemplate;

    @AfterThrowing(pointcut = "execution(* com.example.demo.ExampleService.*(..))",
            throwing = "ex")
    public void logError(Exception ex) {
        jdbcTemplate.update("INSERT INTO error_log(message) VALUES (?)", ex.getMessage());
    }
}
```

[네번째 이미지]

| 테이블 | 결과 |
| :--- | :--- |
| `biz_order` | 0건 — 최내부 트랜잭션이 롤백 |
| `error_log` | 1건 — 트랜잭션 종료 후 새 커밋으로 생존 |

운영에서 몇 년간 봐온 결과다. 이걸 바꿔봤다.

advisor에 `setOrder(-1)`을 줬다. 로깅(0)보다 작으니 트랜잭션이 최외곽이 된다. 만약 config 클래스에 붙인 `@Order(1)`이 진짜로 먹혔다면 벌어졌을 일이다.

[다섯번째 이미지]

| 테이블 | 결과 |
| :--- | :--- |
| `biz_order` | 0건 |
| `error_log` | **0건** |

예외가 로깅 aspect에 닿는 시점에 트랜잭션이 아직 살아 있다. 로그 insert는 그 트랜잭션에 들어가있고, 바깥에서 롤백이 일어나며 **로그까지 함께 지워졌다.** 에러는 났는데 에러의 기록은 없다.

## 우연을 의도로
회사 프로젝트에서 에러 로그는 있으면 좋은 부가 기능이 아니다. 장애가 났을 때 유일하게 남는 증거다. 로그가 롤백을 같이 당하는 순간, 장애는 났는데 흔적은 없는 최악의 상태가 된다. 그러니 "로그는 트랜잭션 바깥"이라는 배치는 **튜닝 값이 아니라 도메인 요구사항이다.**

```java
DefaultPointcutAdvisor advisor = new DefaultPointcutAdvisor(pointcut, interceptor);
        advisor.setOrder(10);  
```

`@Configuration` 위의 `@Order(1)`은 지웠다. 동작은 바뀌지 않았다. 원래도 아무 일을 안 하던 코드였으니까. 바뀐 것은 **이 배치가 우연이 아니라 선언이 되었다**는 점이다.

> 결과가 잘 나온다고 코드도 맞게 짜여진게 아니었다. 결과는 몇 년간 잘 나왔지만, 그 결과에 대한 통제권이 나에게 없었다.

## 정리
- `@Order`의 숫자는 중요도가 아니라 **프록시 겹의 깊이**다. 작을수록 바깥, 클수록 target에 가깝다. 진입은 바깥부터, 예외는 안쪽부터 흐른다.
- `@Configuration` 클래스에 붙인 `@Order`는 그 안에서 생성된 advisor에게 **전파되지 않는다.** Spring은 advisor 빈 자신의 순서 정보만 본다.
- 순서를 지정하지 않은 `DefaultPointcutAdvisor`는 `LOWEST_PRECEDENCE`, **최내부**로 떨어진다.
- 에러 로그의 생존은 "로깅 aspect가 트랜잭션보다 바깥"이라는 배치에 달려 있다. 예외가 로깅에 도달하는 시점에 트랜잭션이 이미 끝나 있어야 로그가 독립적으로 커밋된다.
- 기본값에 맡기지 말고 `setOrder()`로 **명시**한다. 우연히 돌아가는 코드와 의도대로 돌아가는 코드는 천지차이다.

`@Order(1)`을 지우고 `setOrder(10)`을 적었다. 시스템의 동작은 그대로다. 달라진 건 시스템이 어떤 원리로 어떻게 돌아가는지 깨달은 나 자신이다.