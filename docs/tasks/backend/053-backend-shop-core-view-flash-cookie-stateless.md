# 053. View 인증 JWT 단일화 Phase 2 — Flash 메시지 세션→쿠키 stateless화

> 출처: 052와 동일(JWT 단일화 phase 분할). 선행 052와 **독립**(병렬 가능), 둘 다 054(인증 cutover)의 선행.
> 본 Phase: PRG 패턴의 Flash 메시지를 세션 저장 → **쿠키 저장**으로 전환. **인증·세션 자체는 무변경**. 054에서 세션 제거 시 Flash가 깨지지 않도록 하는 prep.

## 배경 / 규모
- Flash 메시지(`addFlashAttribute` + redirect, PRG)는 Spring MVC 기본 `SessionFlashMapManager`(세션 저장)를 쓴다.
- 사용 범위: **14개 View 컨트롤러·131곳**(`web/**/*ViewController.java` — cart·order·결제·seller/admin 상품·카테고리·배송 이행·account·review·판매자신청). 성공/실패 알림이 전부 이 메커니즘.
- 054에서 세션을 STATELESS로 바꾸면 **flash 메시지가 전부 소실** → 모든 PRG 알림이 안 보임. 본 Phase에서 미리 쿠키 기반으로 옮긴다.

## 범위
1. **`CookieFlashMapManager`(커스텀) 도입**: `FlashMapManager`를 구현해 `FlashMap`을 **단기 쿠키**(요청-다음요청 1회성, 읽은 뒤 만료)로 직렬화/복원. Spring MVC가 빈 이름 `flashMapManager`(타입 `FlashMapManager`)를 자동 사용하므로, 이 빈 하나만 교체하면 **컨트롤러 131곳 `addFlashAttribute` 코드는 무수정**으로 유지.
2. **직렬화 제약**: flash 값은 짧은 문자열(`flashSuccess`/`flashError` 등)이라 쿠키 크기(4KB) 안전. 직렬화 형식(예 URL-encoded/JSON + base64), 1회성 소비 후 쿠키 즉시 만료, 보안 속성(HttpOnly·SameSite=Lax) 명시. 값이 큰/비문자 flash가 있으면 식별해 처리(감사: 현재 flash는 메시지 문자열 위주인지 확인).
3. 인증·세션 생성 정책 무변경(이 Phase에선 세션 여전히 존재 — flash만 쿠키로).

## Non-goals
- 인증/세션 제거(054), CSRF/SavedRequest(052), 컨트롤러별 flash 호출부 수정(중앙 1빈 교체로 회피).

## 검증
- **Flash 회귀(핵심)**: 대표 PRG 흐름에서 redirect 후 **성공/실패 메시지가 그대로 표시**되는지 E2E/통합 —
  장바구니 담기, 주문/결제, 판매자 배송 ship/deliver(`flashSuccess`/`flashError`), 상품·카테고리 CRUD, account, 판매자 신청.
- **1회성**: flash 쿠키가 다음 요청에서 소비 후 사라짐(중복 표시·잔존 없음).
- **세션 무변경 확인**: 이 Phase에선 로그인 세션 정상.
- 메인: Modulith verify + 풀 스위트 그린.

## 참고
- Flash 사용처(131곳·14파일): `web/{cart,order,product,member,review}/**/*ViewController.java`.
- Spring MVC `FlashMapManager`/`AbstractFlashMapManager`(`SessionFlashMapManager` 대체), `flashMapManager` 빈 컨벤션.
- 선행/후속: 052(독립), 054(인증 cutover — 052·053 선행 필수).
- 감사 근거: `docs/report/architecture/001-multi-instance-readiness-audit.md` #1.
