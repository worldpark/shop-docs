# Error Response Rule

REST API 에러 응답의 공통 포맷과 예외 처리 규칙을 정의한다.
레이어 규칙은 `docs/rules/architecture-rule.md`, 시스템 불변 조건은 `docs/architecture.md`를 따른다.

## 적용 범위
- 공통 에러 포맷은 **REST API(`/api/v1/**`)에만** 적용한다.
- View(Thymeleaf) 진입점은 이 JSON 포맷을 쓰지 않고 에러 페이지로 렌더링한다.
- 따라서 예외 핸들러는 **REST용과 View용을 분리**한다.
  - REST: `@RestControllerAdvice` → 아래 `ErrorResponse` JSON 반환
  - View: `@ControllerAdvice` 또는 `ErrorController` → 에러 뷰(`error/4xx`, `error/5xx`) 반환

## 공통 응답 포맷 (ErrorResponse, 현재 구현 기준)

| 필드 | 타입 | 설명 |
|---|---|---|
| `status` | number | HTTP 상태 코드 |
| `error` | string | HTTP 상태 reason phrase |
| `message` | string | 사람이 읽는 메시지(클라이언트 노출 가능, 내부 정보 노출 금지) |
| `path` | string | 요청 경로 |
| `timestamp` | string(ISO-8601) | 응답 생성 시각 |

```json
{
  "status": 404,
  "error": "Not Found",
  "message": "주문을 찾을 수 없습니다.",
  "path": "/api/v1/orders/1024",
  "timestamp": "2026-06-03T04:30:00Z"
}
```

검증 실패(400) 예시:

```json
{
  "status": 400,
  "error": "Bad Request",
  "message": "이메일 형식이 올바르지 않습니다.",
  "path": "/api/v1/members",
  "timestamp": "2026-06-03T04:31:00Z"
}
```

## 예외 → 응답 변환 규칙
- 모든 예외는 `RuntimeException`을 상속한 커스텀 예외로 변환한다(`docs/rules/architecture-rule.md` 공통 규칙).
- 현재 `BusinessException`은 메시지와 HTTP 상태를 보유한다.
- 변환은 `@RestControllerAdvice` 한 곳에서만 수행한다. Controller/Service에서 직접 `ErrorResponse`를 조립하지 않는다.
- 도메인별 에러 코드 enum과 필드별 검증 오류 배열은 아직 도입하지 않는다. 도입 시 이 문서와 `ErrorResponse` 구현을 함께 변경한다.

## HTTP 상태 매핑(기준)
| 상황 | HTTP |
|---|---|
| 검증 실패 | 400 |
| 인증 실패 | 401 |
| 권한 없음 | 403 |
| 리소스 없음 | 404 |
| 상태 충돌(재고 부족 등) | 409 |
| 처리 불가 | 422 |
| 서버 오류 | 500 |

## 금지
- 스택트레이스·내부 예외 메시지·SQL 등 내부 정보를 응답 본문에 노출하지 않는다.
- Entity나 도메인 객체를 에러 응답에 담지 않는다.
- View 요청에 REST 에러 JSON을, REST 요청에 HTML 에러 페이지를 반환하지 않는다.
