---
title: 
date: 2026-04-15
categories: [Java, Refactoring]
tags: [java, spring, mybatis, nexacro, oracle, legacy, architecture]
image:
---

## 레거시 SI 코드에 새 기능을 얹으며 — 이상과 현실 사이의 타협점 기록

### 동기
회사에서 **권한별 메뉴 관리** 기능을 새로 만들 일이 생겼다. 메뉴 트리에서 권한을 할당하는 단순 관리자 화면이다. 처음엔 "며칠이면 끝나겠네" 라고 생각했다.

**착각이었다.** 단순 CRUD 하나를 만드는데 매 단계마다 "어떻게 해야 잘 만드는가" 라는 질문이 새로운 형태로 돌아왔다.

회사는 전형적인 공공기관 `SI` 프로젝트다. `web/service/impl/dao` 로 나뉜 구조, `MyBatis + Oracle`, 프론트는 `Nexacro`, 그리고 **폐쇄망**. 거기에 `Java 8, Spring 4.3.25` 라는 레거시 환경.

이런 환경에서 새 기능을 짜면서 **"네카라쿠배 같은 테크 기업이면 어떻게 짤까"** 와 **"회사 현실에선 어디까지 가능한가"** 사이를 끊임없이 오갔다. 이 글은 그 고민의 기록이다.

### 현재 프로젝트 환경

| 구분 | 기술 |
| :--- | :--- |
| `Language` | `Java 8` |
| `Framework` | `Spring 4.3.25 (Spring Boot 아님)` |
| `ORM` | `MyBatis` |
| `DB` | `Oracle` |
| `Frontend` | `Nexacro(넥사크로)` |
| `Logging` | `log4jdbc` |
| 환경 | 폐쇄망, 공공기관 |

**Spring Boot가 아닌 레거시 Spring** 이라는 점, **폐쇄망 공공기관** 이라는  점은 이번 고민 내내 가장 큰 변수가 됐다.

## 문제 분석

기능을 만들기 전에 기존 코드 구조를 봤다. 그리고 동료 리뷰어 관점으로 내가 쓰려던 접근을 분석했다. 

### 문제 1: 화면 메뉴 구조를 그대로 반영한 패키지 깊이
회사 기존 구조는 화면 메뉴를 패키지로 그대로 옮겨놓은 형태다.

```
com.company.system.management
  ├─ improvement/   (시스템관리 > 관리 > 개선사항)
  └─ menu/          (시스템관리 > 관리 > 메뉴)
```

**이건 패키지 분리가 아니라 화면 복제다.** 화면 메뉴는 기획 요구로 수시로 재편된다. "개선사항을 별도 최상위 메뉴로 빼주세요" 한 마디에 `import` 경로 전부가 바뀐다.

`Netflix`, `Naver`, `Kakao` 같은 테크 기업 오픈소스를 보면 전부 **도 메인 기반 평평한 구조**다. `system.management.xxx` 같은 화면 메뉴 그룹명은 패키지에 등장하지 않는다.

### 문제 2: `web/service/impl/dao` 레거시 3계층 구조
회사 기존 패턴:

```
menu/
  ├─ web/
  │   └─ MenuController.java
  └─ service/
      ├─ vo/MenuVO.java
      ├─ MenuService.java       (interface)
      └─ impl/
          ├─ MenuServiceImpl.java
          └─ MenuDao.java
```

`Service` 인터페이스와 `ServiceImpl` 분리는 **구현체가 하나뿐인데 인터페이스를 두는** `SI` 관성이다. `VO` 라는 네이밍은 `MyBatis` 매핑용 `DTO`에 가깝지 진짜 `Value Object` 가 아니다. `dao` 는 `Repository` 로 불리는 게 `Spring` 생태계 표준이다.

**패키지 이름 하나하나가 레거시 관성의 흔적**이다.

### 문제 3: 넥사크로의 제약과 특수성
`Nexacro` 는 일반 `REST API` 처럼 `JSON` 을 주고받지 않는다.

- 응답은 반드시 `NexacroResult.addDataset(name, list)` 패턴만 가능
- 요청은 자체 `PlatformData` 포맷. `@RequestBody` 로 못 받는다
- 각 `Dataset` 행마다 `RowType` (0/1/2/4)이 자동 추적된다

테크 기업 기준의 `REST + JSON` 마인드로 접근하면 전부 깨진다. 그렇다고 넥사크로를 빼고 생각할 수도 없다. **프레임워크가 요구하는 패턴 안에서 코드를 설계해야 한다.**

### 문제 4: `log4jdbc` 의 JDBC 4.0 고착
회사는 `SQL` 로깅을 위해 `log4jdbc` 를 쓴다. **문제는 이게 `JDBC 4.0` 기준이라 `getObject(String, Class<T>)` 메서드가 미구현**이라는 점이다.

`LocalDateTime` 매핑이 아예 안 된다.

```
Method net/sf/log4jdbc/ResultSetSpy.getObject(...) is abstract
```

`Java 8` 의 표준 `java.time API` 를 못 쓴다는 뜻이다. 신규 프로젝트라면 있을 수 없는 제약이다.

### 문제 5: 공공기관 + 폐쇄망이라는 컨텍스트
**감사(監査) 관점이 모든 데이터 설계의 최상위 기준**이 된다.

- 공공기록물법, 개인정보보호법
- 감사원/내부 감사 대응: "왜 이 시점에 이 권한이 부여됐는가?"
- 책임 소재 추적

테크 기업에서는 "매핑 테이블은 전체 삭제 후 재저장" 이 표준이지만, 공공기관에서는 **그 단순화가 오히려 리스크**가 된다.

## 리팩토링(은 아니고) 설계 방향성

### 원칙
1. **회사 전체를 갈아엎지 않는다.** 본인 영역 안에서만 구조를 개선하고, 팀 일관성은 유지한다.
2. **"아는 것"과 "쓰는 것"을 구분한다.** 테크 기업 정석을 알고도 회사 제약 때문에 선택 못 하는 건 패배가 아니라 판단이다.
3. **각 선택의 이유를 말할 수 있어야 한다.** "팀 컨벤션이라서" 는 답이 아니다. **"왜 이 상황에서 이게 맞는지"** 를 설명할 수 있어야 한다.

### 테크 기업 원칙 vs 회사 현실 — 매핑표

| 항목 | 테크 기업 정석 | 이 프로젝트에서 선택 |
| :--- | :--- | :--- |
| 패키지 구조 | 도메인 기반 평평 | `system.management` 유지, 본인 영역만 도메인 분리 |
| 계층 구조 | `presentation/application/domain/infrastructure` 4계층 | `controller/service/repository/dto` 3계층 |
| 도메인 모델 | `Entity` 에 비즈니스 로직 풍부하게 | `MyBatis + DTO` 덩어리 (한계 인정) |
| 날짜 타입 | `LocalDateTime + Jackson` 전역 설정 | `String + TO_CHAR` (log4jdbc 제약) |
| 응답 포맷 | `ApiResponse<T>` 통일 | `NexacroResult` 강제 |
| 매핑 테이블 저장 | 전체 삭제 + 재저장 | `Diff 방식` (공공기관 감사 요구) |

이 표가 이번 설계의 핵심 결론이다. **각 행의 오른쪽 칸은 왼쪽 칸을 모른 채 내린 선택이 아니다.** 알고도 제약 때문에 선택한 것이다.

## 단계별 고민과 해결 기록

### Step 1: 패키지를 어디까지 나눌까
권한별 메뉴 관리는 `menu` 패키지 안에 둘까, 따로 뺄까? 쿼리가 거의 똑같은데 분리하면 중복 아닌가?

**결론: 분리한다.** 주어가 다른 도메인이기 때문이다.

- `menu` 도메인: 메뉴 자체의 `CRUD`
- `authority` 도메인: 권한과 다른 것들(메뉴, 사용자)의 매핑 관리

쿼리가 지금 똑같아 보이는 것도 잠깐이다. 권한 관리 화면은 곧 "메뉴별 할당된 권한 수" 같은 컬럼을 요구한다. **각 도메인이 자기 쿼리를 소유하는 게 결합도 측면에서 이득**이다.

```
authority/
  ├─ role/          (권한 마스터)
  ├─ rolemenu/      (메뉴별 권한 매핑)
  └─ userrole/      (사용자별 권한 매핑)
```

`rolemenu`, `userrole` 같은 소문자 연속 패키지명은 어색하다. 그런데 자바 패키지 규칙상 이게 표준이다. 차라리 **관계를 명시적으로 드러내는 네이밍**이 `menu` 같은 모호한 것보다 낫다.

### Step 2: 내부 구조는 몇 계층인가
이상은 4계층이다. `presentation / application / domain / infrastructure`. 헥사고날 아키텍처도 적용해보고 싶었다.

**현실은 3계층이 맞다.** 이유는 세 가지다.

1. **MyBatis 환경**은 도메인 모델에 비즈니스 로직을 풍부하게 담기 어렵다. 어차피 `DTO` 덩어리가 된다.
2. 권한 매핑 CRUD 같은 **단순 도메인** 에 4계층은 오버엔지니어링이다.
3. `NexacroResult` 강제 반환이 이미 어댑터 경계 역할을 하고 있다.

```
authority/rolemenu/
  ├─ controller/
  ├─ service/
  ├─ repository/
  └─ dto/
      ├─ request/
      └─ response/
```

4계층은 개인 프로젝트(`order-transaction-lab`)에서 마음껏 하기로 했다. 회사에서 **혼자 튀는 구조**는 팀원의 코드 탐색 비용만 올린다.

### Step 3: `DTO / Request / Response` 분리 기준
세 가지가 뒤섞이기 쉽다. 명확하게 역할을 정했다.

| 종류 | 역할 | 개수 기준 |
| :--- | :--- | :--- |
| `Request` | 프론트 → 백엔드 입력 | `API` 별 |
| `DTO` | 내부 전달 (`Repository` ↔ `Service`) | 쿼리 결과 타입별 |
| `Response` | 백엔드 → 프론트 출력 | 화면 출력 단위별 |

`MyBatis` 매핑 전용 `VO` 를 따로 둘까 고민했지만 **DTO 하나로 통일**했다. `VO / DTO` 분리는 옛날 스타일이고, 객체 종류만 늘어난다.

조회 `Request` 가 비어 있으면? **`YAGNI`. 과감히 삭제한다.** 미리 빈 껍데기를 두는 건 후임자에게 "이 Request는 왜 비어있지?" 라는 의문만 남긴다.

### Step 4: 공통 필드를 어떻게 뺄까
모든 `DTO / Response` 에 등록일시, 등록자, 수정일시, 수정자가 들어간다. 추상 클래스로 뺐다.

```java
public abstract class BaseDto {
    private String createdAt;
    private String createdBy;
    private String updatedAt;
    private String updatedBy;
}
```

`abstract` 키워드의 의미는 **"단독 인스턴스화에 의미가 없는 상속 전용 부모"** 라는 의도를 컴파일러에 전달하는 것이다. 일반 클래스로 두면 누군가 `new BaseDto()` 같은 엉뚱한 코드를 짤 수 있다. `abstract` 면 차단된다.

위치는 각 도메인 패키지 구조와 **대칭**이 되도록 배치했다.

```
global/
  └─ dto/
      ├─ BaseDto.java             (≈ domain/dto/XxxDto)
      ├─ request/
      │   └─ BaseSaveItem.java    (≈ domain/dto/request/XxxRequest)
      └─ response/
          └─ BaseResponse.java    (≈ domain/dto/response/XxxResponse)
```

**공통 클래스도 구조적 일관성을 가져야** 한다. 이게 장기적으로 유지보수 비용을 낮춘다.

### Step 5: 첫 번째 큰 타협 — `TO_CHAR`
`BaseDto / BaseResponse` 에 날짜 필드를 `LocalDateTime` 으로 받고 `Jackson` 전역 설정으로 포맷팅하려 했다. 테크 기업 표준이다.

**실행하니 에러.**

```
Method net/sf/log4jdbc/ResultSetSpy.getObject(...) is abstract
```

`log4jdbc` 는 `JDBC 4.0` 고정이라 `LocalDateTime` 매핑 자체가 안 된다. 선택지는 세 가지였다.

| 선택지 | 장점 | 단점 |
| :--- | :--- | :--- |
| `log4jdbc-log4j2` 업그레이드 | 근본 해결, 다른 `java.time` 도 쓸 수 있음 | 팀 합의, 전체 영향 검증 필요 |
| 본인 영역만 다른 `DataSource` | 본인 영역 독립 | 비현실적 |
| **`String + TO_CHAR`** | **즉시 동작, 팀 영향 0** | **레거시 관습 유지** |

**3번을 선택했다.** 단일 기능을 개발하면서 회사 전체 인프라를 건드리는 건 책임 범위를 넘는다.

다만 중요한 건 이것이다. **`TO_CHAR` 가 정석이 아니라는 걸 알고 쓰는 것** 과 **관성으로 `TO_CHAR` 를 쓰는 것** 은 완전히 다르다. 전자는 나중에 기회가 왔을 때 업그레이드를 제안할 수 있다. 후자는 못 한다.

### Step 6: 넥사크로 환경의 응답 설계
페이지 진입 시 메뉴 트리와 권한 리스트가 동시에 필요하다. 일반 REST 라면 래퍼 `Response` 를 만들었을 것이다.

```java
public class MenuAuthInitResponse {
    private List<MenuResponse> menus;
    private List<RoleResponse> roles;
}
```

그런데 넥사크로는 `NexacroResult.addDataset(name, list)` 패턴이 강제다. **여러 Dataset 을 한 응답에 담기** 가 프레임워크 자체의 기본 설계였다.

```java
NexacroResult result = new NexacroResult();
result.addDataset("dsMenu", menus);
result.addDataset("dsRole", roles);
return result;
```

래퍼 `Response` 자체가 불필요해졌다. **프레임워크 제약이 오히려 코드를 단순하게 만든 케이스**다. 제약이 항상 나쁘다고 여기면 안 된다.

### Step 7: 저장 로직 — `Batch` vs `순회`
매핑 데이터 저장은 여러 행을 한 번에 처리한다. 자연스럽게 떠오르는 건 순회다.

```java
for (Item item : items) {
    repository.insert(item);  // ❌ 100건이면 DB 왕복 100번
}
```

**안티패턴이다.** 네트워크 왕복 비용, 트랜잭션 롤백 범위 모호성. `Batch Insert` 가 답이다.

```xml
<insert id="insertMenuRoles">
    INSERT ALL
    <foreach collection="items" item="item">
        INTO tb_role_menu (role_id, menu_id, target, reg_dt)
        VALUES (#{item.roleId}, #{item.menuId}, #{item.target}, SYSDATE)
    </foreach>
    SELECT 1 FROM DUAL
</insert>
```

`Oracle` 은 `MySQL` 과 달리 다중 `VALUES` 구문이 안 돼서 `INSERT ALL ... SELECT 1 FROM DUAL` 패턴을 쓴다. 처음 보면 어색하지만 관용구다.

### Step 8: 전체 삭제 + 재저장 vs Diff
매핑 테이블 저장에는 두 가지 접근이 있다.

**A. 전체 삭제 + 재저장**
```java
repository.deleteByMenuId(menuId);
repository.insertMenuRoles(items);
```

매핑 테이블의 표준 패턴이다. 단순하고 명확하다.

**B. Diff 방식**
```java
Set<Long> toInsert = diff(requested, existing);
Set<Long> toDelete = diff(existing, requested);
```

실제 변경된 것만 처리한다. 이력 추적이 필요할 때 유리하다.

**단순성만 보면 A, 이력 추적을 보면 B.**

그런데 **공공기관 + 폐쇄망** 이라는 컨텍스트가 결정적이었다.

- 권한 매핑은 **100% 감사 대상**이다
- "왜 이 시점에 이 권한이 부여됐는가" 에 답해야 한다
- 단순 삭제 후 재저장은 **어느 행이 실제로 변경됐는지를 잃는다**

**B를 선택했다.** 테크 기업 표준이 A라도, 공공기관 환경에서는 B가 맞다. **조직의 요구사항이 기술 선택의 최상위 기준**이다.

### Step 9: 넥사크로의 `RowType` 이라는 선물
`Diff` 를 백엔드에서 직접 계산하려다가, 넥사크로 `Dataset` 의 `RowType` 기능을 발견했다. 프론트에서 각 행의 변경 상태를 자동 추적해 함께 보내준다.

| `RowType` | 의미 |
| :--- | :--- |
| `0` | Normal (변경 없음) |
| `1` | Insert (신규) |
| `2` | Update (수정) |
| `4` | Delete (삭제) |

**프론트가 이미 Diff 를 계산해서 넘겨주는 셈**이다. 백엔드에서 기존 데이터 조회 후 비교하는 로직이 필요 없다.

```java
@Transactional
public void saveRoles(List<MenuAuthRoleSaveItem> items) {
    List<MenuAuthRoleSaveItem> toInsert = new ArrayList<>();
    List<MenuAuthRoleSaveItem> toDelete = new ArrayList<>();

    for (MenuAuthRoleSaveItem item : items) {
        if (item.isInsert())      toInsert.add(item);
        else if (item.isDelete()) toDelete.add(item);
    }

    if (!toDelete.isEmpty()) repository.deleteMenuRoles(toDelete);
    if (!toInsert.isEmpty()) repository.insertMenuRoles(toInsert, currentUser);
}
```

`isInsert() / isDelete()` 같은 편의 메서드는 매 `SaveItem` 마다 중복 정의하기 싫어서 `BaseSaveItem` 추상 클래스로 뺐다.

```java
public abstract class BaseSaveItem {
    private String rowType;

    public boolean isInsert() { return "1".equals(rowType); }
    public boolean isUpdate() { return "2".equals(rowType); }
    public boolean isDelete() { return "4".equals(rowType); }
}
```

### Step 10: Controller 에 진입조차 안 했다
저장 로직을 다 짜고 테스트했는데 `Controller` 에 진입조차 안 했다. `@RequestBody` 로 받았기 때문이다.

넥사크로는 `JSON` 이 아니라 자체 `PlatformData` 포맷으로 전송한다. 일반 `Spring` 방식으로는 매핑이 안 된다.

`@ParamDataSet` 으로 바꿨다.

```java
@PostMapping("/save")
public NexacroResult saveRoles(
        @ParamDataSet(name = "dsSaveItems") List<MenuAuthRoleSaveItem> items) {
    menuAuthService.saveRoles(items);
    return new NexacroResult();
}
```

이 시점에 깨달았다. `Dataset` 은 본질적으로 `List` 다. 일반 REST 에서 필요한 `Request` 래퍼 객체가 **아예 불필요하다.** 만들어둔 `MenuAuthRoleSaveRequest` 를 삭제했다.

**프레임워크 제약이 또 한 번 코드를 단순하게 만들었다.**

### Step 11: 반복된 작은 함정들
저장 로직을 짜는 동안 문법은 맞는데 동작 안 하는 에러들에 여러 번 빠졌다.

**`MyBatis @Param` 누락**

```java
void deleteMenuRoles(List<Item> items);
```
```
Parameter 'items' not found. Available parameters are [collection, list]
```

회사 레거시 `Spring` 은 `-parameters` 컴파일 옵션이 꺼져 있어서 `MyBatis` 가 자바 파라미터 이름을 추출 못 한다. **모든 Mapper 파라미터에 `@Param` 명시**가 안전한 컨벤션이다.

**`INSERT ALL` + 시퀀스 함정**

```sql
INSERT ALL
    INTO tb_role_menu VALUES (seq.NEXTVAL, ...)
    INTO tb_role_menu VALUES (seq.NEXTVAL, ...)
SELECT 1 FROM DUAL;
```

Oracle 의 `INSERT ALL` 은 하나의 `SQL` 문이라 `NEXTVAL` 이 한 번만 평가된다. **모든 행이 같은 값을 받아서 `PK` 중복**으로 터진다.

이 함정 때문에 결국 테이블 설계 자체를 다시 봤다.

**테이블 설계의 모순**

```
PK: (ROLE_ID, MENU_ID)           -- 이걸로 이미 유니크
UK: (ROLE_ID, MENU_ID, TARGET)   -- 의미 없음
```

`PK` 가 더 좁은 컬럼 조합이라 `UK` 가 사실상 무의미했다. `TARGET` (시스템 구분: WEB/MOBILE)이 달라도 같은 `(ROLE_ID, MENU_ID)` 조합은 들어갈 수 없는 구조다.

**매핑 테이블은 복합키가 본질**이다. 시퀀스 `PK` 를 두면 중복 매핑이 삽입될 수 있고, 별도 `UNIQUE` 제약이 또 필요해진다. 의미 없는 컬럼만 늘어난다.

`DBA` 에 요청해 `PK` 를 `(ROLE_ID, MENU_ID, TARGET)` 로 변경하고 `UK` 를 삭제했다. **설계 오류를 발견했다면, 코드로 우회하지 말고 스키마를 고치는 게 맞다.**

## 회고

### 기술적인 것보다 더 중요했던 것

**"아는 것" 과 "쓰는 것" 의 거리를 받아들이기.** 테크 기업 정석을 알아도 회사 환경에선 어디까지 적용 가능한지 판단하는 게 진짜 실력이다. 판단의 결과물이 정석과 달라도 괜찮다. **이유를 말할 수 있으면 된다.**

**타협은 패배가 아니라 의사결정이다.** `TO_CHAR` 를 쓰는 게 정석이 아닌 걸 알면서도 인프라 제약 때문에 선택하는 것과, 그냥 관성으로 쓰는 건 천지차이다. 전자는 **개선의 씨앗을 갖고 있고**, 후자는 씨앗조차 없다.

**프레임워크 제약이 때로 코드를 단순하게 만든다.** 넥사크로의 `addDataset`, `RowType` 은 처음엔 제약 같았지만 알고 보니 자연스러운 패턴을 강제해줬다. 래퍼 `Response`, 백엔드 `Diff` 계산 로직이 전부 불필요해졌다. **제약을 저항하기 전에 먼저 이해해야 한다.**

### 구체적으로 배운 것

| 주제 | 얻은 것 |
| :--- | :--- |
| 패키지 설계 | 화면 구조와 도메인 구조를 분리. 본인 영역부터라도 도메인 기반으로 |
| 공통 추상 클래스 | `abstract` 는 "상속 전용" 의도를 컴파일러에 전달하는 신호 |
| 매핑 테이블 설계 | 복합키가 본질. 시퀀스 `PK` 는 대부분 불필요한 복잡도 |
| `MyBatis` 실무 | `@Param` 명시, `INSERT ALL` 시퀀스 함정, `foreach` 빈 컬렉션 방어 |
| 넥사크로 연동 | `@ParamDataSet`, `NexacroResult.addDataset`, `RowType` 활용 |
| 레거시 타협 | `TO_CHAR` 같은 선택은 인프라 제약을 이해한 뒤의 의사결정 |

### 메타적인 것

가장 크게 남은 생각은 이것이다.

> **"좋은 코드" 의 정의는 절대적이지 않다.**

테크 기업 정석, 회사 레거시 컨벤션, 폐쇄망 제약, 공공기관 감사 요구 — 이 네 가지가 모두 "좋은 코드" 의 기준에 영향을 준다. 어느 한 축만 보고 판단하면 실패한다.

시니어의 감각은 **"모든 축을 알고 있는 상태에서 지금 이 환경에 맞는 균형점을 찾는 것"** 이라고 느꼈다. 그건 단순 지식이 아니라 **상황 판단 능력**이다.

레거시 환경은 답답하지만, 동시에 그 답답함 안에서 **의사결정 근육**을 키울 수 있는 곳이기도 하다. 개인 프로젝트에서는 마주칠 수 없는 종류의 제약들이 매일 새로운 문제를 던져준다.

이번 권한 관리 기능은 코드 양으로는 작지만, 생각의 양으로는 크게 남는 작업이었다.