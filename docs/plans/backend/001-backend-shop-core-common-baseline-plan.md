# 001. shop-core 공통 기반 클래스 — 구현 Plan

> 영역: backend (JPA 공통 엔티티 기반 + 예외 응답 기반 + 테스트)
> 대상 프로젝트: `shop-core` (REST + Thymeleaf View 공존)
> 작성일: 2026-05-30
> 상태: plan only (코드 변경 없음)

---

## 구현 목표
shop-core 전 도메인 모듈이 재사용할 JPA 공통 베이스 엔티티(BaseEntity + auditing)와 REST/View 분리형 예외 응답 기반(공통 예외 베이스, ErrorResponse, REST/View 전용 핸들러)을 최소 범위로 구성하고, 시큐리티/실 DB 없는 테스트 컨텍스트에서 통과하는 검증을 갖춘다.

## 영향 범위
- 신규 파일 (main)
  - `shop-core/src/main/java/com/shop/shop/common/domain/BaseEntity.java`
  - `shop-core/src/main/java/com/shop/shop/common/config/JpaAuditingConfig.java`
  - `shop-core/src/main/java/com/shop/shop/common/exception/BusinessException.java`
  - `shop-core/src/main/java/com/shop/shop/common/exception/ErrorResponse.java`
  - `shop-core/src/main/java/com/shop/shop/common/exception/RestExceptionHandler.java`
  - `shop-core/src/main/java/com/shop/shop/common/exception/ViewExceptionHandler.java`
  - `shop-core/src/main/resources/templates/error/error.html` (View 에러 뷰 — view-implementor 분담, 본 Task는 모델 키/뷰 이름만 확정)
- 신규 파일 (test)
  - `shop-core/src/test/java/com/shop/shop/common/exception/RestExceptionHandlerTest.java`
  - `shop-core/src/test/java/com/shop/shop/common/exception/ViewExceptionHandlerTest.java`
  - `shop-core/src/test/java/com/shop/shop/common/exception/support/DummyRestController.java` (test 전용 더미)
  - `shop-core/src/test/java/com/shop/shop/common/exception/support/DummyViewController.java` (test 전용 더미)
  - `shop-core/src/test/java/com/shop/shop/common/domain/BaseEntityTest.java` (auditing 구조/동작 단위 검증)
- 수정 파일
  - 없음 (운영 컨트롤러/엔티티는 아직 없으며 본 Task에서 신설하지 않는다)
- 범위 밖 (필요성만 언급, 후속 Task로 미룸)
  - SecurityConfig 전면 도입, 도메인별 구체 예외, ErrorCode enum 트리, 도메인 모듈/엔티티

---

## 1. 설계 방식 및 이유

### 1.1 패키지 배치
- 공통 기반은 `com.shop.shop.common` 하위에 `domain` / `config` / `exception` 으로 분리한다. CLAUDE.md의 모듈별 패키지 규칙(`{module}/...`)에서 `common`을 횡단 공통 모듈로 취급한다.
- BaseEntity는 `@MappedSuperclass`로 두어 응답/모델에 직접 노출되지 않는 매핑 전용 기반임을 명확히 한다 (Entity 직접 반환 금지 제약의 출발점).

### 1.2 REST/View 분리의 핵심 원칙
- shop-core는 REST(`@RestController`)와 View(`@Controller`) 진입점이 공존한다. 예외 응답 형식이 서로 달라야 한다.
  - REST → 공통 JSON `ErrorResponse`
  - View → 에러 뷰(HTML)
- `@RestController`는 `@Controller`의 메타 애너테이션이므로 `@ControllerAdvice(annotations = Controller.class)`는 RestController까지 포함하는 함정이 있다. advice 두 개를 선택자(annotations/assignableTypes)로 분리하고 `@Order`로 우선순위를 고정한다 (상세는 섹션 4).

### 1.3 커스텀 예외 베이스 — 방향 정리 최소 구현
- ErrorCode enum 트리/도메인 예외 계층은 만들지 않는다. `RuntimeException`을 상속한 단일 베이스 `BusinessException`만 둔다.
- `BusinessException`은 메시지 + HTTP 상태 1개(`HttpStatus`, 기본 400)만 보유한다. 상태코드 최종 결정은 핸들러가 수행하되, 베이스가 상태 힌트를 제공한다.
- 도메인별 구체 예외는 후속 도메인 Task에서 이 베이스를 상속해 추가한다.

### 1.4 Spring Boot 기본 에러 처리와의 관계
- Spring Boot는 기본 `BasicErrorController`(`/error`) + `ErrorMvcAutoConfiguration`으로 JSON/HTML 폴백을 제공한다. 다만 REST 응답을 공통 포맷으로 통일하고 View 예외를 도메인 의미로 분기하려면 명시적 advice가 필요하다.
- 따라서 advice를 두되, advice가 처리하지 못한 미처리 경로는 Spring 기본 `/error`에 위임한다(완전 대체하지 않음). 기본 error 뷰(templates/error/) 위치를 재사용하면 View 폴백으로도 동작한다.

---

## 2. 구성 요소 (생성할 클래스/파일)

### main

#### `com.shop.shop.common.domain.BaseEntity`
- 역할: 모든 도메인 Entity가 상속하는 공통 매핑 기반.
- 애너테이션: `@MappedSuperclass`, `@EntityListeners(AuditingEntityListener.class)`, `@Getter`(Lombok).
- 필드:
  - `@CreatedDate @Column(updatable = false) private Instant createdAt;`
  - `@LastModifiedDate private Instant updatedAt;`
- 비고: `id`는 도메인별 전략(시퀀스/UUID)이 다를 수 있어 BaseEntity에 강제하지 않는다(과도 설계 회피). auditing 시간 필드만 공통화한다. setter/응답 노출 없음.

#### `com.shop.shop.common.config.JpaAuditingConfig`
- 역할: `@CreatedDate`/`@LastModifiedDate` 채움 활성화.
- 애너테이션: `@Configuration`, `@EnableJpaAuditing`.
- 충돌 회피: 별도 `@Configuration`으로 분리하면 JPA 자동설정을 제외한 슬라이스(@WebMvcTest)에 자동 포함되지 않는다. 풀 컨텍스트(@SpringBootTest + test profile)에서는 JpaAuditing이 `AuditingEntityListener`만 등록할 뿐 DataSource를 요구하지 않으므로 현재 제외 설정과 충돌하지 않는다(검증 → 5.4).

#### `com.shop.shop.common.exception.BusinessException`
- 역할: 모든 커스텀 예외의 단일 베이스.
- `extends RuntimeException`.
- 필드: `private final HttpStatus status;` (기본값 `BAD_REQUEST`).
- 생성자: `(String message)` / `(String message, HttpStatus status)`.

#### `com.shop.shop.common.exception.ErrorResponse`
- 역할: REST 전용 공통 에러 응답 DTO (Entity 아님).
- 필드(record 권장): `int status`, `String error`(HttpStatus reason), `String message`, `String path`, `Instant timestamp`.
- 정적 팩토리: `of(HttpStatus, String message, String path)`.

#### `com.shop.shop.common.exception.RestExceptionHandler`
- 역할: REST 진입점 예외 → `ErrorResponse` JSON.
- 애너테이션: `@RestControllerAdvice(annotations = RestController.class)`, `@Order(Ordered.HIGHEST_PRECEDENCE)`.
- 핸들러:
  - `@ExceptionHandler(BusinessException.class)` → `e.getStatus()`로 `ResponseEntity<ErrorResponse>`.
  - `@ExceptionHandler(MethodArgumentNotValidException.class)` → 400, 검증 메시지 취합.
  - `@ExceptionHandler(Exception.class)` → 500 fallback(내부 메시지 노출 최소화).
- `path`는 `HttpServletRequest.getRequestURI()`에서 추출.

#### `com.shop.shop.common.exception.ViewExceptionHandler`
- 역할: View 진입점 예외 → 에러 뷰(ModelAndView).
- 애너테이션: `@ControllerAdvice(annotations = Controller.class)`, `@Order(Ordered.LOWEST_PRECEDENCE)`.
- 핸들러:
  - `@ExceptionHandler(BusinessException.class)` → `ModelAndView("error/error")`, 모델 키 `status`,`message`, `setStatus(...)`로 상태 설정.
  - `@ExceptionHandler(Exception.class)` → 500 에러 뷰 fallback.
- 모델에는 DTO/원시값만 담는다(Entity 금지). 확정 모델 키: `status`(int), `message`(String).

#### `templates/error/error.html` (view-implementor 분담)
- 역할: View 예외 공통 에러 화면. 모델 키 `status`,`message` 바인딩.
- 본 backend Task는 모델 키 계약과 뷰 이름(`error/error`)만 확정한다. 마크업은 view-implementor 담당. Spring Boot 기본 error 뷰 폴백 경로와 동일하므로 최소 placeholder 한 장이면 테스트/폴백 모두 충족.

### test

#### `support/DummyRestController` (test 전용)
- `@RestController`. `/__test/rest/business`(BusinessException throw), `/__test/rest/boom`(RuntimeException throw), `/__test/rest/valid`(@Valid 바인딩 실패 유도). Entity 반환 없음.

#### `support/DummyViewController` (test 전용)
- `@Controller`. `/__test/view/business`(BusinessException throw), `/__test/view/boom`(RuntimeException throw). view name 반환만, Entity 모델 금지.

#### `RestExceptionHandlerTest`
- `@WebMvcTest(controllers = DummyRestController.class, excludeAutoConfiguration = SecurityAutoConfiguration.class)` + `@Import(RestExceptionHandler.class)`. MockMvc로 JSON 포맷/상태코드 검증.

#### `ViewExceptionHandlerTest`
- `@WebMvcTest(controllers = DummyViewController.class, excludeAutoConfiguration = SecurityAutoConfiguration.class)` + `@Import(ViewExceptionHandler.class)`. view name `error/error` 및 모델 attribute, 비-JSON 응답 검증.

#### `BaseEntityTest`
- 실 DB 없이 auditing 동작 검증: `AuditingHandler` + 고정 `DateTimeProvider`를 구성해 `markCreated/markModified` 후 `createdAt`/`updatedAt` 채워짐 검증. 보강으로 매핑 애너테이션 존재(reflection) 검증 병행 가능(섹션 6).

---

## 3. 데이터 흐름

### 3.1 REST 예외 흐름
```
HTTP(JSON) 요청 → @RestController → (Service에서 BusinessException throw)
  → RestExceptionHandler(@RestControllerAdvice, annotations=RestController) 매칭
  → ErrorResponse.of(status, message, path) 생성
  → ResponseEntity<ErrorResponse>(status) JSON 직렬화 반환
```

### 3.2 View 예외 흐름
```
HTTP(text/html) 요청 → @Controller → (Service에서 BusinessException throw)
  → ViewExceptionHandler(@ControllerAdvice, View 한정) 매칭
  → ModelAndView("error/error", {status, message}) + setStatus(status)
  → Thymeleaf가 templates/error/error.html 렌더링
미매칭/그 외 → Spring Boot 기본 /error (BasicErrorController) 폴백
```

### 3.3 Auditing 채움 흐름
```
Entity 영속화(save) → Hibernate flush 직전 AuditingEntityListener 콜백
  → AuditingHandler가 DateTimeProvider(현재 시각)로
     @CreatedDate(최초 insert), @LastModifiedDate(insert/update) 주입
@EnableJpaAuditing(JpaAuditingConfig)이 이 핸들러를 활성화
```

---

## 4. 예외 처리 전략

### 4.1 커스텀 예외 베이스
- `BusinessException extends RuntimeException` 단일 베이스 + `HttpStatus status`(기본 400).
- 도메인 구체 예외는 후속 Task에서 상속 추가. ErrorCode enum 미도입(방향만 정리).
- "모든 예외는 RuntimeException 상속 커스텀 예외로 변환" 규칙: 도메인 Service가 외부/checked 예외를 BusinessException으로 변환하는 권장 패턴을 명시(본 Task는 베이스 제공까지).

### 4.2 REST/View advice 분리 (핵심 함정 해결)
- REST: `@RestControllerAdvice(annotations = RestController.class)` → 정확히 `@RestController` 빈만 대상.
- View: `@ControllerAdvice(annotations = Controller.class)`는 `@RestController`(= `@Controller` 메타)까지 잡으므로 그대로 쓰면 안 됨. 분리 전략:
  - (채택) View advice는 `ModelAndView` 반환 + `@Order(LOWEST_PRECEDENCE)`, REST advice는 `@Order(HIGHEST_PRECEDENCE)`. RestControllerAdvice는 셀렉터(annotations=RestController)로 RestController 요청에만 매칭되고, View 요청은 그 셀렉터에 안 걸려 ViewExceptionHandler로 흐른다. 셀렉터 차이가 1차 분리, @Order가 2차 안전장치.
  - 보강: ViewExceptionHandler가 RestController까지 잡는 부작용을 더 막으려면 `assignableTypes`/`basePackages`로 View 컨트롤러 범위를 한정한다. 도메인 컨트롤러가 아직 없어 basePackages 한정은 후속 도메인 Task에서 재조정(주석 명시).
- 결론: REST=annotations=RestController, View=annotations=Controller + @Order 분리. 더미 컨트롤러 슬라이스 테스트로 교차 매칭이 없음을 검증.

### 4.3 상태코드 매핑
- `BusinessException` → `e.getStatus()`.
- `MethodArgumentNotValidException`/바인딩 → 400.
- 그 외(`Exception`) → 500 fallback.

### 4.4 미처리 예외 fallback
- REST: `@ExceptionHandler(Exception.class)` → 500 ErrorResponse(메시지 일반화).
- View: `@ExceptionHandler(Exception.class)` → 500 에러 뷰. 그래도 미매칭 시 Spring Boot 기본 `/error`로 위임.

---

## 5. 검증 방법 (`./gradlew test`)

### 5.1 시큐리티 우회 전략 (SecurityConfig 신설 회피)
- SecurityConfig 신설은 본 Task 범위 밖(인증/인가 정책 미정). 대신 테스트 슬라이스에서 시큐리티 비활성:
  - 1차: `@WebMvcTest(..., excludeAutoConfiguration = SecurityAutoConfiguration.class)`.
  - 보강(필요 시): `@AutoConfigureMockMvc(addFilters = false)`로 필터체인 제거.
- 이유: 예외 핸들러는 인증 결과와 무관하게 동작해야 하며, 401/403이 핸들러 검증을 가리는 것을 막는다. `@WithMockUser`+csrf는 무인증 더미 엔드포인트에 과함 → 미채택.

### 5.2 REST 예외 JSON 검증 (RestExceptionHandlerTest)
- `/__test/rest/business`(커스텀 상태) → 해당 status, body `$.status`,`$.message`,`$.path`,`$.timestamp` 존재, Content-Type JSON.
- `/__test/rest/boom` → 500, fallback 메시지.
- `/__test/rest/valid` → 400, 검증 메시지 포함.

### 5.3 View 예외 분기 검증 (ViewExceptionHandlerTest)
- `/__test/view/business` → view name `error/error`, model `status`/`message` 존재, 응답이 JSON이 아님(HTML 경로). MockMvc `view().name(...)`, `model().attributeExists(...)`로 검증.
- `/__test/view/boom` → 500 에러 뷰.
- 슬라이스에 `spring.thymeleaf.check-template-location=false`(test profile)로 템플릿 미존재여도 view name 검증은 통과(렌더링까지 강제하지 않음).

### 5.4 Auditing 검증 (BaseEntityTest)
- 실 DB 없이 `AuditingHandler` + 고정 `DateTimeProvider` 구성 → `markCreated()` 후 `createdAt != null`, `markModified()` 후 `updatedAt` 갱신 검증.
- 추가로 `@SpringBootTest`(test profile) 풀 컨텍스트 기동(contextLoads)이 `JpaAuditingConfig` 로드 시에도 깨지지 않는지 확인(JPA 자동설정 제외 환경에서 `@EnableJpaAuditing`이 DataSource를 강제하지 않음 보장). 충돌 시 → JpaAuditingConfig에 조건/프로파일 가드 추가(섹션 6) 후 재검증.

### 5.5 Acceptance Criteria ↔ 검증 매핑
| Acceptance | 검증 |
|---|---|
| REST 요청 예외 시 공통 JSON 포맷 반환 | RestExceptionHandlerTest (5.2) |
| View 요청 예외 시 JSON 아닌 에러 뷰/View 처리로 분기 | ViewExceptionHandlerTest (5.3) |
| BaseEntity가 도메인 Entity에서 재사용 가능 | @MappedSuperclass 설계 + BaseEntityTest (5.4) |
| 관련 테스트 통과 | `./gradlew test` 전체 green |

---

## 6. 트레이드오프

- Auditing 검증 방식
  - 채택: `AuditingHandler` 단위 테스트 + 풀 컨텍스트 기동 확인. (장) H2/실DB 불필요, 기존 H2 미도입 방침 유지. (단) 실제 insert/update 시점 주입은 통합 미검증 → 후속 도메인 Task의 @DataJpaTest에서 자연 검증.
  - 미채택: H2 + @DataJpaTest 도입 → 방침 위배·과도, 본 Task 범위 초과.
- Security 우회 방식
  - 채택: 슬라이스에서 SecurityAutoConfiguration 제외(필요 시 addFilters=false). (장) SecurityConfig 미신설로 범위 최소. (단) 운영 보안 정책 미결 → 별도 Security Task 필요(언급만).
- Advice 분리 방식
  - 채택: 셀렉터(annotations) 차이 + @Order. (장) 단순·명확. (단) View basePackages 한정은 도메인 컨트롤러 등장 후 재조정(주석 표기).
- 에러 뷰 vs 기본 /error
  - 채택: 커스텀 ViewExceptionHandler + `error/error` 뷰(기본 폴백 경로 재사용). (장) 도메인 의미 분기 + 기본 폴백 호환. (단) 마크업은 view-implementor 분담 필요.
- JpaAuditingConfig 가드
  - 기본: 가드 없이 별도 @Configuration. 풀 컨텍스트 충돌 발견 시에만 조건/프로파일 가드 추가(YAGNI).

---

## Spring Boot 컨벤션
- 패키지: `com.shop.shop.common.{domain|config|exception}`.
- 어노테이션: `@MappedSuperclass`, `@EntityListeners`, `@CreatedDate`/`@LastModifiedDate`, `@EnableJpaAuditing`, `@RestControllerAdvice`, `@ControllerAdvice`, `@ExceptionHandler`, `@Order`, Lombok `@Getter`.
- 예외 처리: `RuntimeException` 상속 `BusinessException` 베이스로 변환, REST만 `ErrorResponse` 공통 포맷.
- Entity 미노출: BaseEntity는 @MappedSuperclass, 응답은 ErrorResponse DTO, View 모델은 원시값만.

## 완료 조건
- [ ] BaseEntity(@MappedSuperclass + auditing 필드) 생성
- [ ] JpaAuditingConfig(@EnableJpaAuditing) 생성, 풀 컨텍스트 기동 깨지지 않음
- [ ] BusinessException 베이스 생성(RuntimeException 상속, status 보유)
- [ ] ErrorResponse DTO 생성(Entity 아님)
- [ ] RestExceptionHandler(@RestControllerAdvice, annotations=RestController) — JSON 반환
- [ ] ViewExceptionHandler(@ControllerAdvice, View 한정 + @Order) — 에러 뷰 반환
- [ ] error/error 뷰 placeholder 또는 view-implementor 분담 확정(모델 키 status/message)
- [ ] test 더미 컨트롤러(REST/View) + 핸들러 슬라이스 테스트, 시큐리티 우회 적용
- [ ] BaseEntity auditing 단위 테스트
- [ ] `./gradlew test` 전체 통과
- [ ] REST advice가 View 요청에, View advice가 REST 요청에 교차 매칭되지 않음을 테스트로 확인

## view-implementor 분담 표기
- 본 backend Task는 `error/error` 뷰의 모델 키 계약(status, message)과 뷰 이름만 확정한다.
- 실제 `templates/error/error.html` 마크업/레이아웃은 view-implementor 담당. (테스트는 view name + model attribute까지만 검증하여 backend 단독으로 green 달성 가능)
