# 021 — 배송 완료(delivered) deliver 상태 재검증 순서 정정 (Revision 2)

- 대상 Task: `docs/tasks/backend/021-backend-shop-core-order-shipment-delivery-completion-with-view.md`
- 대상 Plan: `docs/plans/backend/021-backend-shop-core-order-shipment-delivery-completion-with-view-plan.md`
- 선행 Revision: `docs/plans/revisions/backend/021-backend-shop-core-order-shipment-delivery-completion-revision-1.md`(정합1~5 + §6 추가 명확화)
- 결정 일자: 2026-06-12
- 결정자: 사용자(Task 021 재리뷰 — 문서 정합성 3자 모순 점검 지시)
- 목적: plan-reviewer 재리뷰에서 발견된 **3자(task SSOT / revision-1 / plan) 순서 모순**을 정정한다. plan §3.1 step 2의 deliver 상태 재검증 순서는 Acceptance Criteria(멱등 200)에 맞게 옳게 수렴했으나, **SSOT인 task §Requirements step 2(line 47)와 revision-1 §6은 여전히 옛 순서(방어 가드 → 멱등)**를 명문으로 유지해 정합이 깨졌다. 본 revision으로 **확정 순서를 못박고**, task line 47과 revision-1 §6의 옛 순서를 **supersede**한다.

---

## 결정 요약

| # | 항목 | 옛 서술(task line 47 / revision-1 §6) | 변경 결정 | 심각도 |
|---|---|---|---|---|
| 정합6 | deliver 상태 재검증 순서 | 방어 가드(`order != shipping` → 409)를 멱등 `delivered` 체크보다 **앞**에 평가 | 멱등 `delivered`(200)를 방어 가드보다 **앞**에 평가 — 아래 확정 순서로 supersede | MAJOR |

---

## 6. 정합6 — deliver 상태 재검증 순서 정정(멱등 delivered 우선) (MAJOR)

### 확정 순서

deliver 상태 권위 재검증(주문 row 락 보유 상태)은 다음 순서로 **확정**한다:

1. 주문이 `cancelled`/`refunded` → `409`(`OrderFulfillmentConflictException`).
2. **shipment가 이미 `delivered` → 멱등 200**(`markDelivered` 호출 없이 현재 `DeliverResponse` 반환, 상태 불변). **방어 가드보다 앞**에 평가.
3. **방어 가드(020 계승)**: `order.status != "shipping"` → `409`. (이 지점 도달 시 shipment는 `delivered`가 아님 — 2에서 걸러짐.)
4. shipment가 `shipping`이 아님(`preparing`/역방향) → `409`.
5. shipment가 `shipping`이면 진행(`markDelivered` + rollup 판정).

이 순서는 task §Requirements step 2(line 47)와 revision-1 §6의 옛 순서(**방어 가드 → 멱등**)를 **supersede**한다.

### 근거

- **① Acceptance(멱등 200)가 더 강한 계약**: 단일 배송 또는 마지막 배송 rollup으로 **주문이 이미 `delivered`로 전이된** 배송을 재-deliver하면, 방어 가드(`order.status != "shipping"` → 409)를 멱등 체크보다 앞에 두는 옛 순서에서는 주문이 `delivered`라 가드가 먼저 `409`를 던진다. 이는 Acceptance Criteria line 120("같은 배송 deliver 중복 → 멱등 200, 상태 불변")을 위반한다. 즉 task는 자기모순이었다(line 47 방어가드-우선 prose ↔ line 120 멱등 200). plan은 더 강한 계약인 Acceptance(line 120)로 옳게 수렴했고, 본 revision은 그 방향을 SSOT에 못박는다.
- **② 020 `ship`과의 비대칭**: 020 `ship`에선 멱등 상태(shipment=`shipping`)가 **항상** 주문 `shipping`과 일치해, 방어 가드를 멱등 체크보다 앞에 둬도 무해했다(가드가 멱등 케이스를 절대 가로채지 않음). 그러나 021 `deliver`에선 멱등 상태(shipment=`delivered`)가 단일/마지막 배송 rollup으로 **주문 `delivered`와 일치할 수 있다**. 이 비대칭 때문에 021에선 멱등 `delivered`를 방어 가드보다 **반드시 앞**에 둬야 한다.
- **③ cancelled/refunded 체크를 멱등보다 앞에 둔 것은 관측상 무해**: `delivered` 상태의 shipment를 가진 주문은 018 가드상 `cancelled`/`refunded`로 전이 불가하다(delivered ⇒ 취소·환불 불가). 따라서 멱등 케이스(shipment=`delivered`)에서 주문이 `cancelled`/`refunded`일 수 없으므로, cancelled/refunded 체크를 멱등(step 2)보다 앞(step 1)에 두어도 멱등 200 도달을 가로막지 않는다 — 관측상 안전하다.

### 적용

- **task §Requirements step 2(line 47)**: 상태 재검증 서술 순서를 위 확정 순서로 재배열(본 revision이 정정 근거).
- **revision-1 §6**: 옛 순서(방어 가드 → 멱등) 서술에 "revision-2에서 순서 정정 — 멱등 delivered 우선" supersede 주석.
- **plan**: §0 근거 문서 줄·§1.3 비대칭 서술·§3.1 step 2에 본 revision 인용 보강(plan의 동작 순서는 이미 옳으므로 인용만 추가).

---

## 7. 파급 정리

| 정합 | 후속 영향 |
|---|---|
| 정합6 | task/revision-1/plan 3자가 동일 순서(`cancelled/refunded → 멱등 delivered 200 → 방어 가드 → 그 외 409 → 진행`)로 정합. **동작 로직 변경 없음**(plan은 이미 이 순서) — 문서 정합 정정만. 소스 코드 무영향(아직 미구현, plan대로 구현하면 됨). |

- 본 revision은 **plan 동작/Acceptance를 바꾸지 않는다**. plan §3.1 step 2는 이미 확정 순서로 작성돼 있었고, task line 47·revision-1 §6의 옛 서술만 그 순서에 맞춰 정정한다.
- 정합1~5(revision-1)·§6 추가 명확화는 그대로 유효하다 — 본 revision은 상태 재검증 **순서**만 supersede한다.
