# Static Asset Rule

## 정적 자산 / 이미지 저장 규칙
- 도메인 코드는 `ObjectStorage` 인터페이스에만 의존한다.
- 현재 구현은 `LocalObjectStorage`이며, 이후 `R2ObjectStorage`로 교체할 수 있어야 한다.
- DB에는 호스트를 포함하지 않은 storage key만 저장한다. 예: `products/{uuid}.jpg`
- DB에 절대 URL을 저장하지 않는다.
- URL 합성(`cdnBaseUrl + storageKey`)은 설정값과 뷰 헬퍼 한 곳에서만 수행한다.
- 컨트롤러, 서비스, 템플릿에 base URL을 하드코딩하지 않는다.
- 파일은 항상 새 키(UUID 또는 해시)로 저장한다.
- 동일 키를 덮어쓰지 않는다. CDN 캐시 무효화 비용을 피하기 위함이다.
- 멀티파트 업로드는 컨트롤러에서 받고, Service가 `ObjectStorage.put()`을 호출한다.
- Repository는 storage key만 저장한다.

