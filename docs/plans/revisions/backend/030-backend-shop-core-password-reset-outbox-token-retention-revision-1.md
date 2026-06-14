# 030 — 재설정 토큰의 Outbox(`event_publication`) 잔존 처리: 전역 `completion-mode: delete` 도입 검토 → 미도입 결정 (Revision 1)

- 대상 Task: `docs/tasks/backend/030-backend-shop-core-password-reset-with-notification-and-view.md`
- 대상 Plan: 미작성(본 결정은 Task 문서 단계의 설계 점검에서 발생) — 후속 plan은 본 결정을 전제로 작성
- 결정 일자: 2026-06-14
- 결정자: 사용자(Task 030 설계 모순 점검 + 토큰-in-Outbox 위험 논의 피드백)
- 목적: 비밀번호 재설정 토큰이 `resetUrl`로 Outbox(`event_publication`)에 평문 직렬화되어 잔존하는 점에 대해, 한때 Task에 반영했던 **전역 `spring.modulith.events.completion-mode: delete` 도입을 철회하고, 위험을 한정 문서화하는 방향(무변경)으로 확정한 이유**와 검토 과정·근거·영향 분석을 기록한다.

---

## 결정 요약

| # | 항목 | 1차 반영(철회됨) | 최종 결정 | 근거 |
|---|---|---|---|---|
| D1 | 재설정 토큰의 Outbox 잔존 | "외부화 완료 후 행이 정리되는 전제"로 기술 | **사실과 다른 전제로 정정**(현재 완료 행은 보존됨) | `application.yml`에 정리 설정 없음 + 코드/스케줄러 부재 확인 |
| D2 | 잔존 차단 수단 | 전역 `completion-mode: delete` 신설 | **미도입(무변경)** | 기능 하나 때문에 전역 Outbox 보존 정책을 뒤집는 건 blast radius 과다 |
| D3 | 토큰 위험 평가 | "보안 위험"으로 다소 강하게 기술 | **한계 위험 무시 가능으로 톤다운** | 동일 DB에 이미 BCrypt 해시·PII 영구 저장 + 토큰은 TTL·1회용으로 더 약함 |
| D4 | 위험 한정 근거 | (TTL·1회성·미로그) | (TTL·1회성·미로그) **유지** + "만료/사용 시 redeem 불가한 죽은 값" 명문화 | 토큰 유효성은 저장 위치가 아니라 **Redis 키**로만 판정 |

---

## 1. 문제 정의

비밀번호 재설정은 단방향·비동기 아키텍처상 토큰을 notification에 전달할 유일한 경로가 이벤트 페이로드다. 따라서 `PasswordResetRequestedEvent.resetUrl`에 **평문 토큰**이 담기고, 이 이벤트는 Transactional Outbox(Spring Modulith Event Publication Registry)로 발행되므로 평문 토큰이 `event_publication.serialized_event`에 **직렬화·영속**된다.

Redis에는 `SHA-256(token)`만 단기 TTL로 저장(원문 미저장)하는 설계인데, 정작 **Postgres `event_publication`에는 평문 토큰이 남는다**는 비대칭이 점검에서 드러났다.

## 2. 1차 반영과 그 오류 (D1)

1차 점검에서 Task에 "Outbox 행은 외부화 완료 후 정리되는 전제"라고 적고, 이를 보장하려 **전역 `completion-mode: delete`** 도입을 Task 4곳(Context·Files·Acceptance·Test)에 반영했다.

그러나 코드베이스 확인 결과 이 전제는 **사실이 아니었다**:
- `shop-core/src/main/resources/application.yml`에는 `spring.modulith.events.externalization.enabled: true`만 있고 **완료 행 정리(`completion-mode`/purge 스케줄러)가 없다.**
- Spring Modulith JPA 기본 동작은 외부화 완료 시 행을 **삭제하지 않고 `completion_date`만 기록**한다.
- 따라서 평문 토큰을 담은 완료 행이 **DB에 무기한 잔존**한다.

→ "정리되는 전제"는 거짓 전제였고, 이를 그대로 두는 대신 **정정**했다.

## 3. 전역 `completion-mode: delete` 미도입 결정 (D2)

도입을 철회한 핵심 이유: **전역 설정**이라 password-reset뿐 아니라 모든 이벤트(`member-registered`/`order-completed`/`payment-failed`/`order-cancelled`/`shipping-started`)의 완료-발행 감사 기록까지 삭제된다. 기능 하나의 좁은 우려를 해결하려 시스템 전역 Outbox 보존 정책을 뒤집는 것은 "꼬리가 몸통을 흔드는" 설계다.

검토한 대안과 탈락 이유:

| 대안 | 내용 | 판정 |
|---|---|---|
| A. 전역 `completion-mode: delete` | 완료 행 즉시 삭제 | **탈락** — blast radius 전역, 감사 기록 일괄 소실 |
| B. 전역 `completion-mode: archive` | 완료 행을 archive 테이블로 이동 | **탈락** — 토큰은 archive에 여전히 잔존(목적 미달) + 전역 |
| C. Modulith `CompletedEventPublications.deletePublicationsOlderThan` | 오래된 완료 행 일괄 삭제 | **탈락** — 이것도 **타입 무관 전역**, 시간 지연만 추가 |
| D. password-reset 타입 한정 정리 스케줄러 | `WHERE event_type LIKE '%PasswordResetRequestedEvent%'` raw SQL | **탈락** — 프레임워크 소유 테이블에 raw SQL 직격(레이어링 위반·스키마 결합), 사이드 프로젝트 과설계 |
| **E. 무변경 + 위험 한정 문서화 (채택)** | 전역 정책 불변, 토큰 위험을 TTL·1회용·미로그로 한정 | **채택** — blast radius 0, 위협 모델상 한계 위험 무시 가능 |

> 핵심: "전역을 안 건드리면서 깔끔하게 토큰만 닦는" 방법은 Modulith에 native하게 없다(공식 정리 API도 전역). 타입 한정은 프레임워크 내부 테이블 직격이라 더 더럽다. 그래서 무변경(E)이 가장 깨끗하다.

## 4. 위협 모델 재평가 — 왜 한계 위험이 무시 가능한가 (D3·D4)

토큰 유효성은 **저장 위치가 아니라 Redis 키 존재 여부**로만 판정된다(`SHA-256(token)`→userId, TTL 30분, 1회용).

- **만료/사용 후**: Redis 키 소멸 → `event_publication`에 남은 평문은 confirm이 무조건 거부하는 **죽은 값**. 보안상 의미 0.
- **유효(30분 미만 + 미사용) 구간**: 이때만 이론상 live 토큰. 그러나 이 평문을 읽으려면 **shop-core Postgres read 권한**이 필요하고, 그 권한이면 같은 DB의 **`users` BCrypt 해시·전 PII를 이미 다 읽는다**(전면 침해 상태).

| 자산 | 위치 | 노출 조건 | 민감도 |
|---|---|---|---|
| BCrypt 비번 해시 / 전 PII | `users` (영구) | DB read | 높음 |
| 재설정 토큰(평문) | `event_publication` (transient, 유효 30분) | DB read | **낮음**(TTL·1회용·만료 후 inert) |

토큰은 **이미 영구 저장된 해시보다 엄격히 덜 민감**(TTL·1회용)하다. 해시를 그대로 둔 채 토큰의 일시 잔존만 막겠다고 전역 감사 기록을 날리는 것은 위협 모델 비일관. 삭제가 막아주는 건 "DB가 이미 털린 상태에서, 30분 안에, 토큰 미사용"이라는 교집합뿐인데, 그 전제 자체가 이미 게임 오버다. → **한계(marginal) 위험은 사실상 0**.

남는 가치는 "비밀은 필요 이상 오래 두지 말자"는 일반 위생 원칙뿐이며, 그조차 동일 DB의 영구 해시 앞에서 무력하다. 따라서 능동적 삭제는 **실질 보안 가치 없음** → 미도입.

## 5. 영향 분석 (전역 도입을 가정했을 때 — 미채택이지만 기록)

전역 `completion-mode: delete`를 만약 넣었다면의 영향을 확인했고, "깨지는 것은 없으나 불필요"임을 확인한 결과를 근거 보존용으로 남긴다:

- **스키마/마이그레이션**: 영향 없음. `event_publication`은 Flyway V1 소유(`FlywayMigrationScriptTest`가 단언), `completion-mode`는 런타임 DELETE/UPDATE 동작만 바꿈 → 신규 V_ 불필요.
- **기존 테스트**: `event_publication`을 SQL로 COUNT/조회하는 통합 테스트 7개(`OrderFulfillmentDeliverIntegrationTest`, `OrderFulfillmentIntegrationTest`, `PaymentDeclineOutboxIntegrationTest`, `UnpaidOrderExpiryOutboxIntegrationTest`, `PaymentOutboxIntegrationTest`, `OrderCancellationOutboxIntegrationTest`, `OrderFulfillmentShipOutboxIntegrationTest`)는 **전부 `externalization.enabled=false`로 실행** → 행이 완료되지 않아 `delete`가 건드리지 않음 → 영향 없음. 외부화를 켜는 유일한 테스트(`OutboxKafkaWireFormatTest`)는 Kafka wire만 검사하고 행 카운트를 단언하지 않음.
- **런타임 기능**: 완료 발행 행을 읽는 운영 코드 0건(레지스트리 조회/재발행/모니터링 production 코드 없음) → 기능 회귀 벡터 없음. INCOMPLETE 행은 어느 모드든 보존되므로 at-least-once/재발행 안전망 손상 없음.
- 결론: 도입해도 안전했지만 **이득(토큰 스크럽)이 §4에 따라 무의미**하므로 전역 부작용을 감수할 이유가 없다.

## 6. 최종 적용 (Task 030 문서 반영)

전역 `completion-mode` 관련 1차 반영 4곳을 모두 철회하고 무변경(E) 톤으로 교체:

| 위치 | 변경 |
|---|---|
| Context "토큰 페이로드 노출 주의" | "completion-mode: delete 신설" → "유효성은 Redis 키로만 판정, 만료/사용 시 죽은 값, 동일 DB 해시보다 덜 민감 → 한계 위험 무시 가능, **별도 정리 메커니즘 미도입**(근거 본 revision)" |
| Files | `application.yml`에 `completion-mode: delete` 추가 행 **삭제** |
| Acceptance | "completion-mode: delete로 즉시 삭제되어 잔존하지 않는다" → "Outbox 직렬화에 한하며 만료/사용 시 Redis 키 소멸로 redeem 불가한 죽은 값" |
| Test | "completion-mode 부수효과 회귀(중요)" 항목 **삭제** |

> 함께 유지(본 결정과 무관, 030 설계 점검의 다른 정정 사항): request 응답 200 단일 고정, `findActiveByEmail` 사용, GET confirm 비소비 peek, `baseUrl` 설정 프로퍼티 신설.

## 7. 보류·범위 밖

- 전역 Outbox 보존 정책(테이블 무한 증가 억제 목적의 `completion-mode`/purge)은 **password-reset과 분리된 독립 운영 결정**으로, 필요 시 별도 Task/ADR에서 시스템 전역 관점으로 다룬다(본 Task에 묻어가지 않는다).
- 토큰을 페이로드 밖으로 빼는 별도 전달 채널, 토큰 추가 보수(TTL 추가 단축 등)는 범위 밖(현 TTL 30분·1회용 유지).
