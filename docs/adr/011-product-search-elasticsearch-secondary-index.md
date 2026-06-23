# ADR-011 — 상품 검색은 Elasticsearch(+Nori) 보조 인덱스로 분리하고 PostgreSQL을 SoT로 유지

- 작성일: 2026-06-22
- 상태: Accepted (방향 확정 — 매핑·벤더·모듈 배치 등 세부는 후속 plan에 위임)
- 범위: shop-core 상품 검색

## 맥락

현재 공개 상품 검색은 `ProductRepository`의 집계 쿼리에서 상품명 단일 컬럼에 대한 선행 와일드카드 LIKE로만 동작한다.

```sql
LOWER(p.name) LIKE LOWER(CONCAT('%', :keyword, '%'))
```

이로 인한 한계:

- 선행 `%` 때문에 B-tree 인덱스를 타지 못해 **풀스캔** — 상품 누적 시 그대로 열화(부하 베이스라인에서 누적 데이터로 인한 쿼리 열화 패턴 관측됨).
- **한국어 형태소 분석 없음** — 어간·합성어 분해·띄어쓰기 정규화 불가("맥북 케이스"↔"맥북케이스" 미스).
- 상품명 단일 컬럼만 검색(설명·카테고리·태그 미포함), **연관도 랭킹·자동완성·패싯·동의어 없음**(정렬은 latest/price 뿐).

두 가지 제약이 선택지를 가른다.

1. **DB의 클라우드 매니지드 이관 가능성** — 향후 RDS/CloudSQL/Supabase 등 매니지드 PostgreSQL로 이관할 수 있다. 매니지드 PG는 임의 확장(PGroonga, mecab-ko 계열 한국어 FTS 사전) 설치가 불가하다.
2. **한국어 형태소 검색 요구** — substring/fuzzy 수준이 아니라 형태소 기반 검색이 제품 요구사항이다.

검토한 대안:

| 대안 | 한국어 품질 | 랭킹/패싯/자동완성 | 신규 인프라 | 동기화 정합성 부담 | 매니지드 PG 호환 |
|---|---|---|---|---|---|
| pg_trgm + GIN | 음절 substring/fuzzy(**형태소 아님**) | 거의 없음 | 0(공식 이미지에 contrib 번들) | 없음(트랜잭션 정합) | **가능(어디서나)** |
| PGroonga | 토큰/형태소 기반 | 일부 | DB 이미지 교체 필요 | 없음(in-DB) | **불가(확장 미제공 → 자체호스팅 락인)** |
| PostgreSQL 네이티브 FTS(tsvector) | 한국어 사전 확장 필요 | 일부 | 한국어는 확장 필요 | 없음(in-DB) | **불가(한국어 사전 확장 미제공)** |
| **Elasticsearch/OpenSearch + Nori** | **형태소(Nori) — 동급 최강** | **풀세트** | **별도 검색 서비스** | **있음(SoT↔사본)** | **DB 무관(독립)** |

두 제약이 동시에 걸리면 in-DB 형태소 옵션(PGroonga·네이티브 FTS+한국어 사전)은 매니지드 이관에서 전부 탈락하고, 매니지드에서 살아남는 in-DB 옵션(pg_trgm)은 형태소 요구를 못 채운다. 결국 **DB 종류와 무관하게 동작하는 외부 검색 엔진**만이 두 제약을 동시에 만족한다.

## 결정

상품 검색을 **Elasticsearch(또는 OpenSearch) + Nori 분석기**로 구성하고, 이를 **PostgreSQL에서 항상 재생성 가능한 보조(secondary) 인덱스**로 둔다. PostgreSQL은 원본(SoT)으로 유지한다.

원칙:

1. **SoT = PostgreSQL, ES = 사본.** 검색 인덱스는 권위가 아니며 언제든 PG에서 전량 재색인으로 복원 가능해야 한다(rebuildable from SoT). 이 속성이 정합성 사고의 안전망이다.
2. **색인은 이벤트 기반(Kafka).** 이미 존재하는 Kafka 이벤트 인프라(ADR-001 비동기 경계, ADR-002 Transactional Outbox)를 따라 product 도메인 이벤트(생성/수정/상태/variant·가격 변경)를 구독하는 indexer가 ES를 갱신한다. dual-write(트랜잭션 내 ES 직접 쓰기)는 금지한다.
3. **풀 재색인·백필 잡을 1급 기능으로** 둔다(초기 적재, 매핑 변경, 드리프트 복구용).
4. **최종 일관성을 전제로 드리프트를 완화한다** — 쿼리 시 status 필터, 클릭스루 시 SoT 재확인. "검색엔 뜨는데 품절/삭제"를 status 변경 색인 + 조회 필터로 닫는다.
5. **장애 폴백** — ES 장애 시 기존 DB 경로(LIKE 또는 pg_trgm)로 graceful degrade하거나 "검색 일시 불가"로 안전 처리한다. 검색 불가가 주문/상세 등 핵심 경로를 막지 않는다.
6. **클라우드 지향과 일관되게 매니지드 검색 서비스를 우선 검토**(OpenSearch Service / Elastic Cloud — 둘 다 Nori 지원). 자체호스팅 클러스터 운영 부담을 피한다.

브리지(선택): indexer·매핑·재색인 구축 리드타임 동안 **pg_trgm + GIN을 임시 브리지 겸 영구 폴백**으로 깔 수 있다(공식 이미지에 번들, 매니지드 호환, 비용 거의 0). ES 도입 후에도 6번 폴백 경로로 재사용 가능하므로 손해가 없다. 도입 여부·시점은 후속 plan에서 결정한다.

본 ADR이 **확정하지 않고 후속 plan에 위임**하는 사항:

- ~~벤더(Elasticsearch vs OpenSearch)·매니지드 vs 자체호스팅 최종 선택.~~ → **벤더 확정(2026-06-23) 참조.**
- 색인 대상 필드·매핑·분석기 설정(이름>설명>태그 부스팅, 동의어·자동완성 범위).
- indexer 모듈 배치(Spring Modulith 모듈 경계 — `product` 내 하위 vs 별도 consumer)와 이벤트 계약(필요 시 `docs/event-catalog.md` 갱신, ADR-004).
- 검색 쿼리 API·읽기 모델 분리 형태, pg_trgm 브리지 채택 여부.

### 벤더 확정 (2026-06-23)

위 위임 항목 중 **벤더는 Elasticsearch로 확정**한다(T1 infra/006 plan에서 결정, 본 ADR에 역반영).

근거:

1. **용도 — 포트폴리오·비상업·자체호스팅.** 본 프로젝트는 포트폴리오 목적이며 상업적 서비스로 운영하지 않고 자체호스팅으로만 사용한다. 따라서 Elasticsearch의 Elastic License v2(ELv2)/SSPL 라이선스가 금지하는 행위(검색을 매니지드/호스티드 서비스로 **재판매**)에 해당하지 않으며, ELv2 허용 범위에 완전히 포함된다 — OpenSearch(Apache 2.0)의 라이선스 우위가 본 용례에서 실질 효익이 없다.
2. **Spring Boot 1급 지원으로 T1 최소 구현.** Spring Boot 3.5는 Elasticsearch Java Client(`co.elastic.clients`)에 대한 자동설정과 actuator health indicator를 1급으로 제공한다. T1(infra/006)의 목표가 "최소 의존으로 연결 + health up"이므로, 추가 코드 거의 0으로 목표를 달성한다. OpenSearch는 Spring Boot 기본 자동설정·health indicator가 없어 커스텀 클라이언트 빈·HealthIndicator를 직접 배선해야 하며, 이는 "과도설계 금지·최소 의존" 원칙과 충돌한다.
3. **Nori 동급.** 한국어 형태소(Nori)는 양쪽 모두 동일한 Lucene Nori 기반 `analysis-nori` 플러그인으로 동급 품질이라 변별 요인이 아니다.

매니지드 이관 여지(원칙 6)는 유지한다 — 향후 필요 시 Elastic Cloud(Nori 지원)로 접속 설정만 교체한다(자체호스팅 compose 노드 → 외부 엔드포인트, 환경별 설정 분리). 즉 본 확정은 **벤더(Elasticsearch)** 결정이며, 자체호스팅 vs 매니지드는 1차 자체호스팅으로 두되 매니지드 이관을 닫지 않는다.

## 결과

긍정적 결과:

- **검색과 DB가 독립적으로 진화한다.** 향후 DB를 클라우드 매니지드로 이관해도 검색 계층은 손대지 않는다(두 제약을 동시에 만족하는 유일한 해).
- Nori로 한국어 형태소·합성어 분해·동의어·연관도 랭킹·자동완성·패싯을 확보한다.
- 검색 부하를 주 PostgreSQL에서 분리해 수평 확장 여지를 얻는다.
- 이미 보유한 Kafka 이벤트 패턴(ADR-001/002)을 그대로 재사용하므로 indexer 설계가 정석적이고 팀에 익숙하다.

부정적 결과와 대응:

- **동기화·정합성이라는 영구 운영 부채가 생긴다(ES는 사본).**
  - SoT=PG + PG에서 전량 재색인 가능 + status 색인/조회 필터 + 클릭스루 재확인으로 드리프트를 닫는다. indexer는 outbox 이벤트 경유로만 갱신(dual-write 금지), 실패는 DLQ로 격리한다.
- **운영 복잡도·비용 추가**(클러스터·매핑·버전 업그레이드).
  - 매니지드 검색 서비스 우선 검토로 클러스터 운영 부담을 덜고, 도입을 요구가 확정된 검색 표면에 한정한다.
- **장애 모드 추가**(ES 다운 시 검색 저하).
  - DB 경로(pg_trgm/LIKE) 폴백 또는 graceful degrade. 검색 장애가 주문/상세/결제 경로를 차단하지 않도록 격리한다.
- 도입까지 리드타임 동안 현재 LIKE 통증이 남는다.
  - 선택적 pg_trgm 브리지로 선행 와일드카드 풀스캔을 즉시 완화하고, 이를 영구 폴백으로 재사용한다.

## 관련 문서

- `docs/architecture.md`
- `docs/event-catalog.md` (ADR-004 — 이벤트 계약 SSOT, 색인 이벤트 추가 시 갱신)
- ADR-001 (shop-core↔notification 비동기 경계 — 동형 indexer 패턴)
- ADR-002 (Transactional Outbox — 색인 이벤트 발행 기반)
- ADR-003 (Spring Modulith — indexer 모듈 경계)
- `docs/rules/event-contract-rule.md`
- (후속) `docs/tasks/backend/<번호>-...-elasticsearch-product-search...`, `docs/plans/backend/<번호>-...-plan.md`
