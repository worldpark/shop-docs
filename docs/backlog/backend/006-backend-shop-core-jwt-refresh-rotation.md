# (backlog) JWT refresh token 회전(rotation) / token family

> 상태: backlog (미착수)
> 영역: shop-core (backend / security)
> 출처: Task 006 plan 범위 밖/트레이드오프 — "refresh 회전·token family·다중 디바이스 세션은 후속, 본 Task는 단일 refresh per user + access만 재발급"

## 배경 / 동기
- 현재 refresh는 사용자당 1개(Redis `shopcore:auth:refresh:{userId}`)이고, refresh 요청 시 access만 재발급(refresh 유지).
- 탈취된 refresh가 만료(P14D)까지 유효한 위험이 있다(logout/blacklist로만 부분 완화).

## 범위 (할 것)
- refresh 회전: refresh 사용 시 새 refresh 발급 + 기존 무효화(재사용 탐지 시 family 전체 폐기).
- token family/다중 디바이스 세션(사용자당 N refresh) 모델 검토 — Redis 키 구조 변경(예: `{userId}:{tokenId}`).
- 재사용 공격 탐지(이미 회전된 refresh 재제시 시 전체 세션 무효화).

## 범위 밖 / 주의
- refresh hash 저장(원문 금지) 유지(006 제약).
- TTL 출처 단일화(JwtProperties) 유지.

## 선행 의존
- Task 006(JWT/RefreshTokenStore) 완료.

## 참고
- `docs/plans/backend/006-...-plan.md` 트레이드오프(refresh 회전)
