# (backlog) Kakao OAuth2 / 소셜 로그인

> 상태: backlog (미착수)
> 영역: shop-core (backend / member·security)
> 출처: Task 006/007 — "Kakao OAuth2 로그인은 후속 확장 범위. 이번 Task는 이메일/비밀번호 기반만"

## 배경 / 동기
- 현재는 이메일/비밀번호 기반 가입·로그인만 구현.
- Task 007에서 "회원 식별자/인증 방식 모델은 OAuth2 확장을 과도하게 막지 않도록 이름/책임 분리"를 제약으로 두었으므로, 이를 활용해 소셜 로그인을 확장한다.

## 범위 (할 것)
- Kakao OAuth2 인증 연동(Authorization Code), 소셜 계정 ↔ 내부 회원 매핑(provider, providerUserId).
- 신규 소셜 사용자 자동 회원 생성(기본 role `CONSUMER`) 또는 기존 이메일 계정 연동 정책 결정.
- 비밀번호 없는 계정(소셜 전용) 처리 — 기존 BCrypt 흐름과 분리.
- JWT 발급 흐름(006)과 통합.

## 범위 밖 / 주의
- 다중 소셜 provider 일반화는 Kakao 먼저 후 확장.
- 토큰/비밀 키 하드코딩 금지(설정/env).

## 선행 의존
- Task 006(JWT), 007(member 도메인) 완료.

## 참고
- `docs/tasks/backend/007-...md` Context/Constraints (식별자·인증 방식 분리)
