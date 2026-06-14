# 030 — shop-core 비밀번호 재설정(비로그인·이메일 토큰) + notification 발송 (with View) 구현 plan

- 대상 Task: docs/tasks/backend/030-backend-shop-core-password-reset-with-notification-and-view.md (범위 SSOT)
- 전제 결정(필독): docs/plans/revisions/backend/030-backend-shop-core-password-reset-outbox-token-retention-revision-1.md
  - 재설정 토큰의 Outbox(event_publication) 잔존에 대해 전역 completion-mode/purge 변경을 도입하지 않는다(무변경 + 위험 한정 문서화). 본 plan은 이 결정을 전제로 하며 전역 Outbox 정책 변경을 일절 포함하지 않는다.
- 관련 규칙: architecture-rule, api-authorization-rule, error-response-rule, event-contract-rule, package-structure-rule, testing-rule, task-rule
- 작성일: 2026-06-14

---

## 0. 핵심 결정 요약 (Task가 plan 확정으로 위임한 6+1개 — 코드 확인 결과로 단정)

| # | 결정 항목 | 확정 내용 | 근거(실제 코드) |
|---|---|---|---|
| K0 | 029 선후 | 029 선행 완료 — 산출물 전부 재사용. fallback 불필요. | User.changePassword(String) 존재(member/domain/User.java:115), MemberRepository.findActiveByEmail(member/repository/MemberRepository.java:36), MemberStatus/status/deletedAt/isActive()/V6 마이그레이션 존재. AccountService(029)·AccountFacade(029)도 존재. → Task Context fallback(changePassword 직접 추가 / 탈퇴 판정 생략)은 적용하지 않는다. |
| K1 | baseUrl 설정 위치 | 신규 config record common/config/AppUrlProperties.java(prefix shop.app, 키 base-url) 신설 + application.yml에 shop.app.base-url 추가. | 기존 shop.storage.asset-base-url(StorageProperties)이 있으나 정적 자산 도메인 전용 의미라 재사용 시 의미 결합. RedisProperties/StorageProperties 선례대로 도메인 분리 신규 record가 관행에 부합. |
| K2 | 토큰 스토어 포트 메서드 | store(token, userId, ttl) / Optional<Long> peek(token)(비소비) / Optional<Long> consume(token)(원자 GETDEL — 1회용 소비). 모두 내부 SHA-256, 원문 미저장. | RefreshTokenStore/RedisRefreshTokenStore/FakeRefreshTokenStore 3분할 + SHA-256 패턴 계승. Task가 비소비/소비 분리 명시. GET=peek, POST 성공=consume. |
| K3 | 동일 이메일 연속 요청 | 각 요청마다 새 토큰 발급, 모든 미만료 토큰 redeem 가능(토큰단위 키 독립, 자연 TTL 만료). per-user 단일화/이전 토큰 폐기 미도입. | 키가 {hash}->userId(토큰단위)라 per-user 최신화는 역인덱스 필요 -> 과설계. 단기 30분·1회용·해시로 충분 보호. rate limit은 범위 밖(YAGNI). |
| K4 | confirm 삭제 순서/실패 | (1) consume(token) 원자 소비(없으면 거부). (2) 비번 검증 -> encode -> user.changePassword (트랜잭션 본문). (3) refreshTokenStore.deleteRefresh(userId)는 afterCommit. consume은 트랜잭션 진입 직후 1회. consume 후 DB 롤백 시 토큰은 죽은 값(재요청)이라 benign. | Redis 비트랜잭셔널 — AccountService.invalidateRefresh afterCommit 선례 계승. GETDEL 원자성으로 동시 confirm 1회만 성공. |
| K5 | REST 응답 코드 | request: 항상 200(존재/미존재 동일 본문 — enumeration 방지). confirm: 성공 200, 무효/만료/사용 토큰 또는 비번 정책 위반 400(ErrorResponse). | api-authorization-rule + error-response-rule. 비로그인 + 메일 발송 안내 본문 필요 -> 200 + 메시지 바디. |
| K6 | 계약 문서 우선순서 | docs/event-catalog.md(스키마+예시 JSON) + docs/architecture.md §5 토픽 행 추가를 코드보다 먼저. 이후 record/DTO를 계약에 정합. | event-contract-rule(계약 SSOT 우선·가산 변경). |

> 위 K0~K6은 본 plan 전체에서 단일 진실로 사용한다. 구현 에이전트는 이 표를 우선 따른다.

---

## 1. 설계 방식 및 이유

### 1.1 전체 그림
비로그인 사용자의 비밀번호 재설정을 capability(토큰 소지) 기반으로 구현한다. 인증 회원 식별이 아니라 1회용·단기·해시 저장 토큰을 소지하는 것 자체가 권한 증명이다. 흐름은 두 단계로 분리한다.

1. 요청(request): 이메일을 받아 활성 사용자면 랜덤 토큰을 발급(Redis에 SHA-256(token)->userId, TTL 30분)하고 PasswordResetRequestedEvent를 Transactional Outbox로 발행한다. notification이 토픽 password-reset-requested를 구독해 재설정 링크 메일을 보낸다. 이메일 존재 여부와 무관하게 응답은 동일(enumeration 방지).
2. 확정(confirm): 토큰 + 새 비밀번호를 받아 토큰을 원자 소비(consume)해 userId를 확보하고, 새 비밀번호 정책 검증 후 User.changePassword로 교체, 커밋 후 기존 refresh를 무효화한다.

### 1.2 채택한 설계 원칙과 이유
- 단방향·비동기 발송 계승(아키텍처 불변): shop-core는 메일을 직접 보내지 않는다. 신규 이벤트 발행 -> notification 소비 구조(028 Welcome 동일 패턴)로만 보낸다. 발송 실패가 토큰 발급/응답을 막지 않는다(at-least-once + 멱등).
- 토큰 저장은 refresh 패턴 계승: 원문 Redis 미저장, SHA-256(token)만 저장, 단기 TTL. 신규 namespace shopcore:auth:reset:로 분리. 포트+Redis 구현+테스트 Fake 3분할로 단위 테스트가 Redis 없이 동작.
- 비소비/소비 분리(Task 명시): GET confirm 화면은 토큰을 소비하면 안 되므로 비소비 peek로 유효성만 확인하고, 실제 1회용 소비는 POST 성공 시 consume(원자 GETDEL)으로만 수행한다. 새로고침으로 토큰이 죽는 사고를 막는다.
- enumeration 방지를 인가의 일부로: request는 존재/미존재 모두 동일 200·동일 본문·동일 안내. 존재할 때만 토큰·이벤트, 미존재/탈퇴면 조용히 no-op. 차별 응답·차별 분기 금지.
- 레이어 규칙 엄수: REST RestController -> ServiceResponse -> Service -> Repository, View Controller(web) -> spi facade -> Service. web은 member Entity/Service/Role을 직접 참조하지 않는다(facade 경유, scalar/DTO만). 토큰 발급/검증은 Service + Redis 어댑터 경계.
- DB 스키마 무변경: 토큰은 Redis가 권위. users 변경 없음 -> V_ 추가 없음. notification processed_event 재사용.
- Outbox 토큰 잔존은 무변경(revision 전제): resetUrl에 평문 토큰이 담겨 event_publication에 직렬화·잔존하나, 유효성은 Redis 키로만 판정되어 만료/사용 시 redeem 불가한 죽은 값이 된다. 동일 DB의 BCrypt 해시·PII보다 덜 민감하므로 한계 위험 무시 가능. 전역 completion-mode/purge/정리 스케줄러를 도입하지 않는다.

### 1.3 명시적으로 하지 않는 것 (범위 가드)
- 전역 Outbox 보존 정책 변경(completion-mode/archive/purge/정리 스케줄러) — revision에서 배제. 절대 포함 금지.
- per-user 토큰 단일화 인덱스, rate limit/스로틀, captcha — 범위 밖(K3).
- 토큰을 페이로드 밖으로 빼는 별도 전달 채널 — 범위 밖(단방향 아키텍처상 불가, revision §7).
- User.changePassword 신규 추가 — 이미 029에 존재(K0). 재추가 금지.

---

## 2. 구성 요소 (정확 패키지·경로·시그니처)

> 영역 구분: [BE]=backend-implementor, [VIEW]=view-implementor, [DOC]=계약 문서(코드 선행). 구현은 [DOC] -> [BE] -> [VIEW] 순서 권장.

### 2.1 계약 문서 (코드보다 먼저) — [DOC]
- (수정) docs/event-catalog.md — PasswordResetRequestedEvent (topic: password-reset-requested) 절 신설. 필드 표 + 예시 JSON. 필드: eventId(UUID,필수), occurredAt(ISO-8601,필수), memberId(long,필수), memberEmail(string,필수), memberName(string,필수), resetUrl(string,필수), expiresAt(ISO-8601,필수). 예시 JSON resetUrl은 http://localhost:8080/password-reset/confirm?token=... 형태.
- (수정) docs/architecture.md §5 토픽 표 행 추가: password-reset-requested | PasswordResetRequestedEvent | 비밀번호 재설정 요청 | member | notification.

### 2.2 shop-core backend — [BE]

#### 이벤트
- (신규) member/event/PasswordResetRequestedEvent.java
  - @Externalized("password-reset-requested") record.
  - public record PasswordResetRequestedEvent(UUID eventId, Instant occurredAt, long memberId, String memberEmail, String memberName, String resetUrl, Instant expiresAt)
  - public static final String TOPIC = "password-reset-requested"; (MemberRegisteredEvent 선례).
  - Javadoc: 토큰 잔존 한계 위험(revision 근거 1줄) + 민감정보(비번/해시) 금지, resetUrl은 메일 전달 목적 예외 명시.

#### 토큰 스토어 (3분할)
- (신규) security/PasswordResetTokenStore.java — 포트 인터페이스
  - void store(String token, long userId, Duration ttl);  (내부 SHA-256, 원문 미저장)
  - Optional of Long peek(String token);  (비소비 — GET confirm 유효성 확인, 삭제 안 함)
  - Optional of Long consume(String token);  (소비 — 원자 GETDEL, POST 성공 시 1회용 삭제)
- (신규) security/RedisPasswordResetTokenStore.java — @Component 운영 구현
  - StringRedisTemplate + RedisProperties 주입. 키 = redisProperties.auth().resetPrefix() + sha256(token).
  - store: opsForValue().set(key, String.valueOf(userId), ttl).
  - peek: opsForValue().get(key)(String) -> Optional.map(Long::parseLong) 반환 Optional of Long. 파싱 실패는 일반 예외 전파(500 범주, §4.1).
  - consume: opsForValue().getAndDelete(key) (Redis GETDEL 원자)(String) -> Optional.map(Long::parseLong) 반환 Optional of Long. 파싱 실패는 일반 예외 전파(500 범주, §4.1).
  - sha256 헬퍼는 RedisRefreshTokenStore와 동일(HexFormat). 토큰 원문 로그 금지(userId/만료만).
- (신규, test) security/support/FakePasswordResetTokenStore.java — @Primary, 인메모리 Map(키=sha256(token), 값=userId), @Import 전용(@Component 미부착). consume=remove 반환. TTL 미시뮬레이션(FakeRefreshTokenStore 선례).

#### 설정 프로퍼티
- (수정) common/config/RedisProperties.java — Auth record에 resetPrefix, resetTtl 추가 + 폴백:
  - resetPrefix 기본 "shopcore:auth:reset:", resetTtl 기본 Duration.ofMinutes(30).
  - Auth(...) 생성자 시그니처 확장 -> new Auth(null, null, null, null) 폴백 호출부에 null 2개 추가.
  - resetTtl은 코드에서 실제 참조(store TTL 출처) — 주석에 SSOT 명시(refreshTtl/blacklistTtl과 달리 미참조 아님).
- (신규) common/config/AppUrlProperties.java — @ConfigurationProperties(prefix = "shop.app")(StorageProperties 선례 @Getter/@Setter 또는 record). 필드 baseUrl(base-url), 기본 http://localhost:8080. resetUrl 조립 전용. 하드코딩 금지.
- (수정) 부트스트랩 @EnableConfigurationProperties(또는 @ConfigurationPropertiesScan) 등록 지점에 AppUrlProperties 추가(RedisProperties/StorageProperties 등록 방식 동형 — 구현 시 기존 위치 확인).

#### DTO
- (신규) member/dto/PasswordResetRequest.java — REST request 바디 record { @NotBlank @Email String email }.
- (신규) member/dto/PasswordResetConfirmRequest.java — REST confirm 바디 record { @NotBlank String token, @NotBlank @Size(min=MemberPasswordPolicy.MIN_LENGTH) String newPassword, @NotBlank String newPasswordConfirm } + @PasswordMatches(field="newPassword", confirmField="newPasswordConfirm").
  - (@PasswordMatches 필드 속성 필수) 기본값은 field="password"/confirmField="passwordConfirm"(PasswordMatches.java:37·44)이므로 newPassword/newPasswordConfirm를 못 찾아 validator가 null==null로 조용히 통과(PasswordMatchesValidator.java:42-44 — 무음 통과 보안 결함). 029가 도입한 field/confirmField 일반화(PasswordMatches.java javadoc·validator javadoc)를 그대로 활용해 양쪽 속성을 명시한다.
  - (@Size 정책 상수 재사용) newPassword 최소 길이는 007 가입(SignupRequest)이 쓰는 MemberPasswordPolicy.MIN_LENGTH를 재사용(리터럴 하드코딩 금지, SignupRequest.java:23·MemberPasswordPolicy import 선례 동형). 정확한 상수명은 구현 시 SignupRequest 확인.
- (신규) web/auth/PasswordResetForm.java — View 요청 폼(@Getter/@Setter) { @NotBlank @Email String email }. 모델 키 passwordResetForm.
- (신규) web/auth/PasswordResetConfirmForm.java — View 확정 폼 { String token(hidden), @NotBlank @Size(min=MemberPasswordPolicy.MIN_LENGTH) newPassword, @NotBlank newPasswordConfirm } + @PasswordMatches(field="newPassword", confirmField="newPasswordConfirm"). 모델 키 passwordResetConfirmForm.
  - (@PasswordMatches 필드 속성 필수) REST DTO와 동일 — 기본값(password/passwordConfirm)을 그대로 쓰면 newPassword/newPasswordConfirm 미탐지로 validator가 무음 통과(PasswordMatchesValidator.java:42-44). 029 일반화를 활용해 양쪽 속성 명시.
  - (@Size 정책 상수 재사용) MemberPasswordPolicy.MIN_LENGTH 재사용(SignupForm/SignupRequest 동일 출처, 리터럴 하드코딩 금지).
  - (위치) View 폼은 web/auth(web 책임), REST DTO는 member/dto(member 책임).

#### 서비스 (도메인)
- (신규) member/service/PasswordResetService.java — @Service
  - 의존: MemberRepository, PasswordEncoder, PasswordResetTokenStore, RefreshTokenStore, ApplicationEventPublisher, RedisProperties(resetTtl), AppUrlProperties(baseUrl).
  - @Transactional public void requestReset(String email):
    1. findActiveByEmail(email.trim()) — 없으면 즉시 return(no-op, 동일 응답; 탈퇴/미존재 동일, K0/enumeration).
    2. 존재 시: token=generateToken()(SecureRandom 32바이트 -> HexFormat.of().formatHex(...)로 인코딩, 64자 hex, 충분 엔트로피). ttl=redisProperties.auth().resetTtl(). expiresAt=Instant.now().plus(ttl). (인코딩 단일 확정: 기존 RedisRefreshTokenStore.sha256이 HexFormat을 사용하므로[RedisRefreshTokenStore.java:97] 토큰 생성도 동일 Hex로 일관 — hex는 URL-safe하여 resetUrl 쿼리파라미터에 그대로 안전. Base64URL은 미채택.)
    3. tokenStore.store(token, user.getId(), ttl).
    4. resetUrl = appUrlProperties.getBaseUrl() + "/password-reset/confirm?token=" + token.
    5. eventPublisher.publishEvent(new PasswordResetRequestedEvent(UUID.randomUUID(), Instant.now(), user.getId(), user.getEmail(), user.getName(), resetUrl, expiresAt)).
    6. 로그: userId/expiresAt만. 토큰·resetUrl 로그 금지.
  - @Transactional public void confirmReset(String token, String newPassword):
    1. long userId = tokenStore.consume(token).orElseThrow(InvalidPasswordResetTokenException::new) (원자 소비 — 없음/만료/사용됨 거부 400).
    2. User user = memberRepository.findById(userId).orElseThrow(() -> new MemberNotFoundException(userId)) — 토큰은 유효하나 그 사이 회원이 삭제된 극단 케이스. 기존 MemberNotFoundException(common/exception/MemberNotFoundException.java, HTTP 404) 재사용(AccountService.findById(userId).orElseThrow(() -> new MemberNotFoundException(userId)) 선례 동형, AccountService.java:54·82·101). 이는 토큰 거부(InvalidPasswordResetTokenException=400)와 구분되는 별개 경로(404).
    3. user.changePassword(passwordEncoder.encode(newPassword)) (029 도메인 메서드 재사용).
    4. refresh 무효화 — AccountService.invalidateRefresh와 동일: 동기화 활성 시 afterCommit()에서 refreshTokenStore.deleteRefresh(userId), 비활성 시 직접 호출.
    5. 로그: userId만.
  - @Transactional(readOnly=true) public boolean isTokenValid(String token) 반환 tokenStore.peek(token).isPresent() (비소비 — facade가 호출).
  - generateToken() private(SecureRandom). consume은 트랜잭션 진입 직후 1회(K4 재사용 차단).
- (신규) member/service/PasswordResetServiceResponse.java — @Service(REST 조합, AccountServiceResponse 선례)
  - void request(PasswordResetRequest req) -> passwordResetService.requestReset(req.email()) (항상 정상 반환).
  - void confirm(PasswordResetConfirmRequest req) -> passwordResetService.confirmReset(req.token(), req.newPassword()).

#### 예외
- (신규) common/exception/InvalidPasswordResetTokenException.java — extends BusinessException, HTTP 400, 메시지 "유효하지 않거나 만료된 토큰입니다." (RestExceptionHandler가 400 ErrorResponse 변환). 토큰 값 비포함.

#### REST 컨트롤러
- (신규) member/controller/PasswordResetRestController.java — @RestController, @RequestMapping("/api/v1/auth/password-reset")
  - @PostMapping("/request") request(@Valid @RequestBody PasswordResetRequest req) -> 위임 -> 항상 200 { message:"비밀번호 재설정 메일을 보냈습니다(계정이 존재하는 경우)." }(존재/미존재 동일). 비즈니스 로직 없음.
  - @PostMapping("/confirm") confirm(@Valid @RequestBody PasswordResetConfirmRequest req) -> 위임 -> 성공 200. 무효 토큰 -> InvalidPasswordResetTokenException(400). 비번 confirm 불일치 -> @PasswordMatches 400.

#### View facade (spi)
- (신규) member/spi/PasswordResetFacade.java — published port 인터페이스(AccountFacade 선례)
  - void requestReset(String email);
  - boolean isTokenValid(String token);  (GET confirm — 비소비 peek 위임, scalar)
  - void confirmReset(String token, String newPassword);
  - 시그니처는 web 타입(폼) 미수신, scalar만(architecture-rule).
- (신규) member/service/PasswordResetFacadeImpl.java — @Service package-private(AccountFacadeImpl 선례), PasswordResetService에만 위임(requestReset/isTokenValid/confirmReset). web에서 member.spi 단방향.

#### Security
- (수정) security/SecurityConfig.java
  - REST 체인(@Order(1)): anyRequest().authenticated() 앞에 requestMatchers(HttpMethod.POST, "/api/v1/auth/password-reset/request", "/api/v1/auth/password-reset/confirm").permitAll().
  - View 체인(@Order(2)): anyRequest().authenticated() 앞에 "/password-reset", "/password-reset/**" GET/POST permitAll(login/signup permitAll 선례 동형). CSRF View 기본 활성 유지(th:action 자동 _csrf 주입).

### 2.3 shop-core View — [VIEW]

- (신규) web/auth/PasswordResetViewController.java — @Controller
  - @GetMapping("/password-reset") -> 빈 passwordResetForm -> view auth/password-reset-request. param.sent 안내 분기는 template.
  - @PostMapping("/password-reset") (@Valid @ModelAttribute("passwordResetForm") PasswordResetForm form, BindingResult br, RedirectAttributes ra):
    - 검증 실패 -> 재렌더 auth/password-reset-request.
    - 성공 -> passwordResetFacade.requestReset(form.getEmail()) -> 항상 redirect:/password-reset?sent (존재/미존재 동일 — enumeration).
  - @GetMapping("/password-reset/confirm") (@RequestParam(required=false) String token, Model model):
    - boolean valid = (token != null) 그리고 passwordResetFacade.isTokenValid(token) (비소비 peek).
    - model resetTokenValid(scalar boolean), passwordResetConfirmForm(token 프리필 hidden), view auth/password-reset-confirm. invalid면 폼 숨김 안내(template 분기).
  - @PostMapping("/password-reset/confirm") (@Valid @ModelAttribute("passwordResetConfirmForm") PasswordResetConfirmForm form, BindingResult br, Model model):
    - 검증 실패(@Size/@PasswordMatches) -> 비번 필드 clear(echo 금지) -> resetTokenValid=true 재설정 -> 재렌더.
    - 성공 -> passwordResetFacade.confirmReset(form.getToken(), form.getNewPassword()). InvalidPasswordResetTokenException 캐치 -> resetTokenValid=false + 안내 -> 비번 clear -> 재렌더. 성공 시 redirect:/login?reset.
  - 비번 echo 차단 헬퍼(AccountViewController.clearPasswordFields 선례). web은 member Entity/Service/Role 직접 참조 금지 — facade만.
- (신규) templates/auth/password-reset-request.html — layout/blank 기반(login.html 선례). 이메일 입력 폼(th:action=/password-reset, method=post) + passwordResetForm. param.sent 동일 안내. CSRF 자동 주입(수동 금지).
- (신규) templates/auth/password-reset-confirm.html — layout/blank 기반. resetTokenValid 참이면 새 비번 폼(token hidden, newPassword/newPasswordConfirm), 아니면 "유효하지 않거나 만료된 링크" 안내 + 재요청 링크. 폼(th:action=/password-reset/confirm, method=post). 비번 echo 금지(value 미바인딩).
- (수정) templates/auth/login.html — 회원가입 링크 영역(62~64행 인근)에 "비밀번호를 잊으셨나요?" + /password-reset 링크 추가. param.reset(재설정 완료) 안내 분기 추가(withdraw/logout 분기 선례 동형).

### 2.4 notification — [BE]

- (신규) dto/PasswordResetRequestedEvent.java — 계약 미러 record implements EventEnvelope. 필드/순서 = shop-core record와 정확히 동일(eventId, occurredAt, memberId, memberEmail, memberName, resetUrl, expiresAt). JSON 필드명 기반 정합(공유 라이브러리 없음).
- (수정) consumer/NotificationEventConsumer.java — @KafkaListener(topics=password-reset-requested, groupId=notification, containerFactory=kafkaListenerContainerFactory) onPasswordResetRequested(PasswordResetRequestedEvent event){ processingService.process(event); } (기존 5개 리스너 미러, 로직 없음).
- (수정) service/NotificationMessageRenderer.java — render switch에 case PasswordResetRequestedEvent e -> renderPasswordReset(e). renderPasswordReset:
  - requireEmail(...) + resetUrl blank/expiresAt null -> NonRetryableNotificationException(필수값 결손, ShippingStarted 선례 동형).
  - 제목 "[비밀번호 재설정] 안내", 본문: memberName 인사 + 재설정 링크(resetUrl) + 만료 안내(expiresAt) + 본인 아니면 무시 안내.
- (수정) service/DlqReprocessingService.java — DLQ_TOPICS에 "password-reset-requested.DLQ" 추가 + TOPIC_TYPE_MAP에 "password-reset-requested.DLQ" -> PasswordResetRequestedEvent.class 추가.
- (재사용·무변경) EventProcessingService/EmailSender/processed_event/CircuitBreaker/멱등.

### 2.5 재사용·무변경 (명시)
- shop-core: User.changePassword(029), PasswordEncoder(BCrypt) 빈, @PasswordMatches/@Size(007), RefreshTokenStore.deleteRefresh, RestExceptionHandler(BusinessException 변환 400), ViewExceptionHandler, RedisRefreshTokenStore.sha256 패턴(HexFormat), MemberNotFoundException(common/exception, confirm의 findById empty 분기 재사용), findActiveByEmail(029).
- notification: EventEnvelope, NonRetryableNotificationException, 발송 인프라 전체.
- DB: V1~V6(shop-core), notification Flyway — 무변경. event_publication/processed_event 재사용.

---

## 3. 데이터 흐름

### 3.1 request — REST 경로
```
POST /api/v1/auth/password-reset/request {email}
 => SecurityConfig REST 체인 permitAll
 => PasswordResetRestController.request(@Valid PasswordResetRequest)
 => PasswordResetServiceResponse.request
 => PasswordResetService.requestReset(email)  @Transactional
     - findActiveByEmail(email)
         - empty(미존재/탈퇴) => return (no-op)
         - present => token=SecureRandom; tokenStore.store(SHA256(token)=>userId, ttl=30m)
                      resetUrl = appUrl.baseUrl + "/password-reset/confirm?token="+token
                      publishEvent(PasswordResetRequestedEvent{...resetUrl, expiresAt}) => Outbox(event_publication INCOMPLETE)
 => (commit) Outbox 외부화 => Kafka topic password-reset-requested
 => 200 {message:"...메일을 보냈습니다..."}   (존재/미존재 동일 200, 동일 본문)
```

### 3.2 request — View 경로
```
GET  /password-reset => auth/password-reset-request (빈 passwordResetForm)
POST /password-reset {email}
 => PasswordResetViewController (@Valid)
     - 검증 실패 => 재렌더 auth/password-reset-request
     - 성공 => PasswordResetFacade.requestReset(email) => PasswordResetService.requestReset
 => 항상 redirect:/password-reset?sent   (enumeration-safe 동일 안내)
```

### 3.3 confirm — REST 경로
```
POST /api/v1/auth/password-reset/confirm {token, newPassword, newPasswordConfirm}
 => @Valid (@PasswordMatches/@Size 1차 검증; 실패 400)
 => PasswordResetService.confirmReset(token, newPassword)  @Transactional
     - tokenStore.consume(token)  (원자 GETDEL)
         - empty(없음/만료/이미사용) => InvalidPasswordResetTokenException(400)
         - userId
     - user = findById(userId).orElseThrow(MemberNotFoundException::new[404, 토큰 유효·회원 삭제 극단 케이스])
     - user.changePassword(encode(newPassword))   (JPA dirty checking)
     - afterCommit: refreshTokenStore.deleteRefresh(userId)   (기존 세션 무효화)
 => (commit) 200
```

### 3.4 confirm — View 경로
```
GET  /password-reset/confirm?token=...
 => isTokenValid = PasswordResetFacade.isTokenValid(token)  (비소비 peek, 삭제 안 함)
 => model: resetTokenValid(scalar), passwordResetConfirmForm(token hidden)
 => auth/password-reset-confirm  (invalid면 폼 숨김 + 안내)
POST /password-reset/confirm {token, newPassword, newPasswordConfirm}
 => @Valid (@Size/@PasswordMatches) 실패 => 비번 clear + resetTokenValid=true 재렌더
 => PasswordResetFacade.confirmReset => PasswordResetService.confirmReset (consume 경유)
     - InvalidPasswordResetTokenException => resetTokenValid=false + 안내, 비번 clear, 재렌더
 => 성공 => redirect:/login?reset
```

### 3.5 notification 소비
```
Kafka topic password-reset-requested
 => NotificationEventConsumer.onPasswordResetRequested(PasswordResetRequestedEvent)
 => EventProcessingService.process(event)  (멱등 eventId: 이미 SENT면 skip)
 => NotificationMessageRenderer.render => renderPasswordReset
     - memberEmail blank / resetUrl blank / expiresAt null => NonRetryableNotificationException
     - RenderedMessage(to=memberEmail, subject="[비밀번호 재설정] 안내", body= 인사+resetUrl 링크+만료 안내)
 => EmailSender (log mode 또는 smtp) => processed_event SENT
 (실패 시 재시도 => 소진 시 password-reset-requested.DLQ => DlqReprocessingService 수동 재투입)
```

---

## 4. 예외 처리 전략 (error-response-rule 준수)

### 4.1 REST (/api/v1/**) — ErrorResponse JSON
- request는 어떤 경우에도 예외를 던지지 않는다. 미존재/탈퇴 = no-op + 200. 입력 형식 오류(@Email/@NotBlank)만 400(검증 실패). => enumeration 방지: 존재 여부로 분기/예외 차이 없음.
- confirm 무효/만료/사용 토큰 => InvalidPasswordResetTokenException(BusinessException, 400) => RestExceptionHandler가 ErrorResponse(status 400, message "유효하지 않거나 만료된 토큰입니다.", 토큰 값 미포함)로 변환.
- 새 비번 정책 위반(@Size/@PasswordMatches) => MethodArgumentNotValidException => 400 ErrorResponse(기존 핸들러). 메시지에 비번 원문 비포함.
- Redis 실패(연결 불가 등) => request: 토큰 저장 실패면 트랜잭션 롤백·500(이벤트 미발행, 일관). confirm: consume 실패면 500. 토큰/비번 원문 로그·응답 노출 금지. (Redis 장애는 일반 500 — 별도 커스텀 처리 과설계, 범위 밖.)
- value 파싱 실패: Redis value는 String.valueOf(userId)로 저장되므로 peek/consume이 String -> Long 변환 시 NumberFormatException 가능(이론상 외부 오염/손상 데이터). 이 파싱 예외도 Redis 실패와 동일한 서버 오류(500) 범주로 처리한다 — 별도 추상화·커스텀 예외 없이 일반 예외 전파로 충분(과설계 금지).
- 비번 원문/해시/토큰을 응답 본문·로그·스택트레이스에 노출 금지(error-response-rule 금지절).

### 4.2 View (Thymeleaf) — 재렌더/flash, JSON 미사용
- 요청 폼 형식 오류 => 폼 재렌더(auth/password-reset-request), BindingResult 필드 에러.
- 요청 제출 성공/대상부재 무관 => redirect:/password-reset?sent 동일 안내(enumeration-safe).
- GET confirm 무효/만료 토큰 => resetTokenValid=false => 안내 화면(폼 숨김) + 재요청 링크. 예외 없이 정상 렌더.
- POST confirm:
  - 비번 검증 실패 => 비번 필드 clear(echo 금지) + 재렌더.
  - 무효/만료/사용 토큰(InvalidPasswordResetTokenException 캐치) => resetTokenValid=false + 안내 + 비번 clear 재렌더(AccountViewController BusinessException 캐치 선례 동형).
  - 성공 => redirect:/login?reset (PRG).
- View는 ErrorResponse JSON을 쓰지 않는다(error-response-rule 적용 범위). 예기치 못한 예외는 기존 ViewExceptionHandler => error 뷰.

### 4.3 notification
- memberEmail/resetUrl/expiresAt(필수) 결손 => NonRetryableNotificationException(재시도 안 함 => DLQ). ShippingStarted 필수필드 가드 선례 동형.
- 알 수 없는 타입은 기존 default 분기 NonRetryable 유지.
- 멱등: 동일 eventId 재수신 SENT skip(기존 인프라). 토큰 값 로그 금지(렌더러는 resetUrl을 본문에만, 로그 미기록).

### 4.4 enumeration 방지 일관성 점검표 (구현 필수)
- request: 응답 코드(200) 동일 / 응답 본문 동일 / 예외 없음 / 분기 로그도 대상부재를 외부 신호로 노출 안 함 / 소요시간 차이 최소(존재 시 추가 작업 — OTP성 허용, Task 명시).

---

## 5. 검증 방법 (Task Test 섹션을 구체 테스트 클래스/케이스로 분해)

### 5.1 shop-core 단위 (Mockito) — [BE]
- member/service/PasswordResetServiceTest
  - request_존재이메일_토큰저장_이벤트발행1회: findActiveByEmail present => tokenStore.store 1회 + eventPublisher.publishEvent(any(PasswordResetRequestedEvent.class)) 1회. ArgumentCaptor로 resetUrl(baseUrl 접두 + token 포함), expiresAt(now+ttl 근사), memberEmail/memberName/memberId 정합.
  - request_미존재이메일_무저장_무발행_동일반환: empty => verifyNoInteractions(tokenStore), verify(eventPublisher, never()), 예외 없이 정상 반환(enumeration).
  - request_탈퇴는 findActiveByEmail empty로 동일 경로(K0).
  - confirm_유효토큰_비번교체_토큰소비_refresh삭제: consume present => encode + user.changePassword(hash) + deleteRefresh 1회(비트랜잭션 단위는 직접 호출 분기).
  - confirm_없는·만료·사용토큰_거부: consume empty => InvalidPasswordResetTokenException(verify no encode/changePassword/deleteRefresh).
  - confirm_consume은 1회만 호출(재사용 차단 단언).
  - isTokenValid_peek위임_비소비: peek 호출, consume 미호출 단언.
  - (페이로드 record에 비번/해시 필드 부재 — 타입 레벨, 런타임 단언 대상 아님. resetUrl 토큰만 단언.)
- security/RedisPasswordResetTokenStoreTest(단위, mock StringRedisTemplate): store/peek/consume이 resetPrefix + sha256(token) 키 사용, consume이 getAndDelete 호출, value=userId만(원문 미저장) 단언.

### 5.2 shop-core 통합 (Testcontainers + Redis) — [BE]
- member/service/PasswordResetRedisIntegrationTest(기존 Redis 통합 베이스 재사용)
  - 토큰이 shopcore:auth:reset: namespace에 SHA-256 키로 저장 + TTL(0 초과, 약 30m).
  - confirm 성공 후 키 삭제(consume) => 동일 토큰 재confirm => InvalidPasswordResetTokenException.
  - TTL 경과(짧은 TTL 주입 또는 expire 강제) 후 peek/consume empty.
  - peek는 키 삭제 안 함(GET 안전) — peek 후 키 존속 단언.
- member/service/PasswordResetOutboxIntegrationTest: request 커밋 시 event_publication에 PasswordResetRequestedEvent 1행 적재(externalization 비활성 환경 INCOMPLETE 카운트 — 기존 Outbox 통합 선례 동형). completion-mode/잔존 회귀 항목 추가 안 함(revision).

### 5.3 Security / REST (MockMvc) — [BE]
- member/controller/PasswordResetRestControllerTest(또는 SecurityConfig 통합)
  - /request·/confirm 둘 다 비로그인 허용(permitAll) — 401/403 아님.
  - request: 존재/미존재 이메일 모두 200 + 동일 본문(enumeration — 두 응답 동일 단언).
  - confirm: 잘못된/없는 토큰 => 400 ErrorResponse(JSON status 400). 토큰 값 본문 미포함.
  - confirm: 비번 confirm 불일치 => 400(@PasswordMatches). ErrorResponse 필드 에러가 newPasswordConfirm 필드에 보고되는지 단언(일반화가 실제 동작 — 무음 통과 아님 회귀 차단, 029 동형). 추가로 newPassword/newPasswordConfirm 모두 채운 불일치 케이스로 확인(둘 다 null이면 validator가 통과하는 무음 경로를 테스트가 우회하지 않도록 실값 주입).
  - confirm 성공 후: 변경된 비번으로 로그인(/api/v1/auth/login) 성공(가능 범위 통합).

### 5.4 notification 단위/통합 — [BE]
- service/NotificationMessageRendererTest: PasswordResetRequestedEvent => 제목/본문에 resetUrl 링크·expiresAt 만료 안내·memberName 인사 포함. memberEmail blank => NonRetryable. resetUrl blank => NonRetryable. expiresAt null => NonRetryable.
- consumer 위임: onPasswordResetRequested => processingService.process 1회 위임.
- DLQ 매핑: DlqReprocessingService TOPIC_TYPE_MAP에 password-reset-requested.DLQ => PasswordResetRequestedEvent.class 포함 단언.
- EventProcessingService 멱등: 동일 eventId 재처리 SENT skip(기존 패턴 확장).

### 5.5 notification 역직렬화 parity (중요) — [BE]
- dto/EventDeserializationTest에 추가:
  - passwordResetRequestedEvent_deserialization_maps_all_required_fields: JSON(eventId/occurredAt/memberId/memberEmail/memberName/resetUrl/expiresAt 전수) => record 매핑, 7필드 assert(특히 신규 resetUrl/expiresAt 필드명 누락 회귀 차단).
  - passwordResetRequestedEvent_implements_eventEnvelope.
- (계약 drift 차단: record-DTO 필드명 동일성은 이 테스트가 SSOT JSON으로 회귀 보장.)

### 5.6 View 렌더링 — [VIEW]
- web/auth/PasswordResetViewControllerTest(MockMvc 슬라이스/통합)
  - GET /password-reset => 200 + view auth/password-reset-request + 모델 passwordResetForm.
  - POST /password-reset(존재/미존재 무관) => redirect:/password-reset?sent 동일(enumeration-safe).
  - POST /password-reset 이메일 형식 오류 => 재렌더 + BindingResult 에러.
  - GET /password-reset/confirm?token=valid => resetTokenValid=true + 폼; token=invalid => resetTokenValid=false 안내. peek 호출(consume 미호출) 단언.
  - POST /password-reset/confirm 성공 => redirect:/login?reset. 무효 토큰 => 재렌더 안내. 검증 실패 => 비번 echo 없음(응답 본문 비번 미포함) 단언.
  - POST /password-reset/confirm 비번 불일치(newPassword≠newPasswordConfirm, 둘 다 실값) => 재렌더 + BindingResult가 newPasswordConfirm 필드에 에러 보고(@PasswordMatches 일반화 실동작 — 무음 통과 아님 회귀 차단, 029 동형). 비번 clear도 함께 단언.
  - login.html에 /password-reset 링크 렌더 단언.
  - (E2E 권장: MEMORY "조건부 폼은 실제 브라우저 E2E로 검증" — 토큰 유효/무효 폼 가시성은 Playwright 스모크로 보강 가능, 범위 허용 시.)

### 5.7 종단 스모크 (testing-rule 종단 스모크) — [BE]
- 라이브 연계: request 호출 => Kafka => notification 로그(또는 log-mode EmailSender) 재설정 메일 1건 => 로그 본문 토큰 추출 => confirm 호출 => 변경된 비번으로 로그인 성공.

### 5.8 회귀 — [BE]/[VIEW]
- 006 로그인·007 가입·008 로그아웃·029 계정 self-service 그린 유지(SecurityConfig 변경·RedisProperties.Auth 시그니처 확장 영향 확인 — new Auth(null,...) 폴백 호출부, RefreshTokenStore 무변경).
- RedisProperties.Auth에 resetPrefix/resetTtl 기본값 추가에 맞춰, 기존 shop-core/src/test/java/com/shop/shop/common/config/RedisPropertiesTest.java의 기본값 단언 테스트(defaultValues_fallback)에 resetPrefix 기본값("shopcore:auth:reset:")·resetTtl 기본값(Duration.ofMinutes(30)) 단언을 보강한다(refreshPrefix/blacklistTtl 단언과 동형). namespace 격리 테스트(allPrefixes_startWithShopcore)에도 resetPrefix.startsWith("shopcore:") 단언 추가 권장.
- shop-core·notification gradlew test 풀 그린.

---

## 6. 트레이드오프

| 결정 | 채택안 | 대안 | 채택 이유 / 한계 |
|---|---|---|---|
| Outbox 토큰 잔존 | 무변경 + 위험 한정 문서화 | 전역 completion-mode delete/archive, 타입한정 purge 스케줄러 | revision §3~4: 전역은 blast radius 과다(전 이벤트 감사기록 소실), 타입한정은 프레임워크 테이블 직격(레이어 위반). 토큰은 TTL·1회용·만료후 죽은 값 + 동일 DB 해시보다 덜 민감 => 한계 위험 무시 가능. |
| 토큰 노출 한계위험 | resetUrl에 평문 토큰(메일 전달 유일 경로) | 별도 채널/토큰 외부화 | 단방향·비동기 아키텍처상 페이로드가 유일 경로. 위험은 TTL 30분·1회용·미로그·Redis 키 판정으로 한정. |
| 동일 이메일 연속 요청 | 다중 미만료 토큰 허용(토큰단위 키, 자연 만료) | per-user 단일 토큰(역인덱스), rate limit | 키가 token에서 userId 방향이라 단일화는 역인덱스 추가 필요 => 과설계. 단기·1회용으로 위험 한정. rate limit 범위 밖(YAGNI). |
| 토큰 소비 | consume=원자 GETDEL | get 후 별도 delete(2-step) | 동시 confirm 경합에서 1회만 성공 보장(원자성). 2-step은 race로 이중 사용 가능. |
| refresh 무효화 시점 | afterCommit | 트랜잭션 내 직접 삭제 | Redis 비트랜잭셔널 — DB 롤백 시 refresh만 삭제되는 불일치 방지(AccountService 선례). |
| baseUrl 위치 | 신규 shop.app.base-url | 기존 shop.storage.asset-base-url 재사용 | 도메인 의미 분리(storage vs app URL). 자산 base 결합 시 향후 CDN 이관 부작용. RedisProperties/StorageProperties 분리 관행. |
| confirm 토큰 무효 응답 | 400 BusinessException | 404 | 토큰은 리소스 식별이 아니라 capability — "유효하지 않음"은 검증 실패(400)가 의미상 적합 + enumeration 무관. |
| 029 선후 | 029 선행 전제(확인됨) | 029 미선행 fallback | 코드 확인 결과 029 산출물 전부 존재(K0). fallback 불필요 — 중복 추가 시 충돌. |

---

## 7. 구현 순서 권장 (오케스트레이션 참고)
1. [DOC] event-catalog.md + architecture.md §5 (계약 우선 — event-contract-rule)
2. [BE] shop-core: 이벤트 record => RedisProperties.Auth 확장 => AppUrlProperties => TokenStore 3분할 => 예외 => PasswordResetService(+Response) => DTO => REST 컨트롤러 => spi facade(+impl) => SecurityConfig => 단위/통합/MockMvc 테스트
3. [BE] notification: DTO => consumer => renderer => DLQ 매핑 => parity 테스트 => 단위
4. [VIEW] ViewController => 템플릿 2종 + login.html 링크 => View 테스트
5. [BE] 종단 스모크 + 회귀(gradlew test 양 레포)

## 8. 완료 조건 (Acceptance 매핑)
- [ ] 존재 이메일 request => 토큰 Redis 저장(SHA-256, TTL) + PasswordResetRequestedEvent 발행 => notification 재설정 메일 1건(log mode 스모크).
- [ ] 미존재/탈퇴 이메일 request => 토큰·이벤트 없음 + 동일 응답(REST 200 단일 / View redirect ?sent).
- [ ] 유효 토큰 confirm => 비번 교체 + 토큰 1회 무효화 + refresh 만료, 새 비번 로그인 가능.
- [ ] 만료·사용·위조 토큰 confirm => 거부(REST 400 / View 안내).
- [ ] 토큰 SHA-256만 저장, 원문/토큰 로그·응답·View 미노출(resetUrl은 메일 페이로드 한정).
- [ ] event-catalog.md + architecture.md §5 신규 이벤트 반영, 코드 record와 정합. users 스키마·기존 이벤트 무변경. 전역 Outbox 정책 무변경.
- [ ] shop-core·notification gradlew test 풀 그린(006/007/008/029 회귀 포함).
