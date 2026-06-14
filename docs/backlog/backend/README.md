# Backend Backlog

작업 중 "후속 Task"로 명시적으로 미뤄둔 백엔드 항목 모음. 각 문서는 미뤄진 출처(어느 Task/plan)를 기록한다.
정식 착수 시 `docs/tasks/backend/`로 승격해 Task 명세를 작성한다. 우선순위/번호는 등록 순일 뿐 실행 순서가 아니다.

| # | 항목 | 영역 | 출처 |
|---|---|---|---|
| 001 | `/me` 엔드포인트 중복 정리 (auth/me ↔ members/me) | shop-core | Task 007 §1.7 |
| 002 | 판매자/관리자 가입·권한 관리 (관리자 Task) | shop-core | Task 006/007 |
| 003 | Kakao OAuth2 / 소셜 로그인 | shop-core | Task 006/007 |
| 004 | 계정 관리 (비밀번호 재설정/변경, 정보수정/탈퇴) **(→ 승격: Task 029 self-service + 030 재설정)** | shop-core (+notification) | Task 007 |
| 005 | 회원가입 Welcome 알림 이벤트 발행 **(→ 승격: Task 028)** | shop-core → notification | Task 007 |
| 006 | JWT refresh token 회전(rotation)/token family | shop-core | Task 006 |
| 007 | 분산락 실제 구현 (Redisson 재검토) | shop-core | Task 005/006 |
| 008 | notification RedisConfig @ConditionalOnBean 선제 정리 **(→ 승격: Task 026)** | notification | P1 버그수정 보고 |
| 009 | notification 알림 dedup 적용 + 발송 이력/DLQ 테이블 | notification | Task 004/005 |
| 010 | 상품 이미지 개수 상한의 동시성 엄격 보장 (race 방지) | shop-core | Task 012 |
| 011 | notification SMTP CircuitBreaker 메트릭/헬스 노출 (resilience4j-spring-boot3 + Actuator) | notification | Task 025 plan |

> 의존 관계 참고: 005는 notification 발송 핸들러와, 009는 008과 함께 진행 권장. 007은 재고/쿠폰 도메인 Task와 함께 적용. 010은 엄격 보장에 분산락(007) 방식 선택 시 007 선행. 011은 Task 025 완료 후 관측성 요구 발생 시(선측정·후도입).
