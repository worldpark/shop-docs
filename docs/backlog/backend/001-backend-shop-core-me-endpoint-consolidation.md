# (backlog) shop-core /me 엔드포인트 중복 정리

> 상태: backlog (미착수)
> 영역: shop-core (backend / member·security)
> 출처: Task 007 plan §1.7 (member signup) — `members/me` 신규 추가하며 `auth/me`와의 중복을 후속으로 미룸

## 배경 / 동기
- Task 006에서 `GET /api/v1/auth/me`를 추가했고, Task 007에서 Task 요구에 따라 `GET /api/v1/members/me`를 별도 추가했다.
- 두 엔드포인트는 동일하게 `MeResponse.from(User)`를 반환하고 principal(userId) 추출 로직도 같다 → 의도된 일시적 중복.

## 범위 (할 것)
- 두 엔드포인트 중 하나로 일원화(권장: 도메인 의미상 `GET /api/v1/members/me` 유지, `auth/me` 제거 또는 deprecate).
- 제거 시 `AuthServiceResponse.me`/`AuthRestController`의 me 부분 및 관련 테스트 정리.
- API 사용처(있다면 프론트/문서)와 `docs/rules/api-authorization-rule.md` 표 정합.

## 범위 밖 / 주의
- 인증/JWT 로직 변경 없음(엔드포인트 표면만 정리).
- 제거 방향이면 호환성 고려해 한 사이클 deprecate 후 제거 가능.

## 선행 의존
- Task 006, 007 완료.

## 참고
- `docs/plans/backend/006-...-plan.md`, `docs/plans/backend/007-...-plan.md` §1.7
