#!/usr/bin/env bash
# Kiali / Jaeger 에서 분산 트레이스를 확인하기 위한 교육용 데모.
#
# 전제: 03_install-observability.sh, 04_deploy-apps.sh, 05_start-lab-access.sh start
# 파이프라인: 앱 OTLP → otel-collector → Jaeger ← Kiali (Traces 탭)
#
# 케이스
#   A) 정상(201): order → inventory(latest) → payment (스팬 3단)
#   B) 장애(502): order → inventory(risky 503) — payment 스팬 없음
#
# 사용법:
#   ./infra/scripts/10_demo-kiali-traces.sh
#   ./infra/scripts/10_demo-kiali-traces.sh 15 0.2   # 성공 요청 15회, 간격 0.2s
set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/verify-tracing-pipeline.sh
source "${_script_dir}/lib/verify-tracing-pipeline.sh"
verify_tracing_bootstrap "${_script_dir}"
cd "${REPO_ROOT}"

LAB_PORT_INGRESS="${LAB_PORT_INGRESS:-18088}"
SUCCESS_REQUESTS="${1:-12}"
SLEEP_SEC="${2:-0.25}"
INGRESS_URL="http://${LAB_ACCESS_HOST}:${LAB_PORT_INGRESS}"
KIALI_URL="http://${LAB_ACCESS_HOST}:${LAB_PORT_KIALI}/kiali/"
JAEGER_UI="http://${LAB_ACCESS_HOST}:${LAB_PORT_JAEGER}/"
ORDER_JSON='{"orderId":"TRACE-DEMO-001","itemId":"ITEM-1","quantity":1,"price":100}'

if ! curl -s -o /dev/null --connect-timeout 2 -X POST "${INGRESS_URL}/api/orders" 2>/dev/null; then
  echo "Ingress(${INGRESS_URL}) 에 연결할 수 없습니다." >&2
  echo "  ./infra/scripts/05_start-lab-access.sh start" >&2
  exit 1
fi

_jaeger_base="$(verify_tracing_jaeger_url)"

echo "=== Kiali 트레이스 확인 데모 ==="
echo "  Ingress: ${INGRESS_URL}/api/orders"
echo "  Kiali:   ${KIALI_URL}"
echo "  Jaeger:  ${JAEGER_UI}"
echo

echo ">>> [1/4] 트레이스 파이프라인 점검"
_failed=false
if ! verify_tracing_otlp_from_order; then
  echo "  → OTLP 503: infra/k8s/07-otel-collector.yaml (0.0.0.0:4318) 및 11-mesh-egress-to-observe.yaml 확인" >&2
  _failed=true
fi
if ! verify_tracing_jaeger_services "${_jaeger_base}"; then
  echo "  → Jaeger 에 서비스가 없습니다. 앱 로그의 'Failed to export spans' 확인" >&2
  _failed=true
fi
if [[ "${_failed}" == "true" ]]; then
  exit 1
fi
echo

echo ">>> [2/4] 케이스 A — 정상 트레이스 유도 (${SUCCESS_REQUESTS}회, 201 기대)"
_ok=0
for _i in $(seq 1 "${SUCCESS_REQUESTS}"); do
  _code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${INGRESS_URL}/api/orders" \
    -H 'Content-Type: application/json' -d "${ORDER_JSON}")"
  [[ "${_code}" == "201" ]] && _ok=$((_ok + 1))
  printf '  [A-%02d] HTTP %s\n' "${_i}" "${_code}"
  sleep "${SLEEP_SEC}"
done
echo "  요약: 201=${_ok}/${SUCCESS_REQUESTS}"
if [[ "${_ok}" -lt 3 ]]; then
  echo "  경고: 201 이 적습니다. 서킷브레이크 직후면 09_demo 로 latest 만 몰린 뒤 다시 실행하세요." >&2
fi
echo

echo ">>> [3/4] Jaeger / Kiali API 로 트레이스 확인 (최근 15m)"
sleep 2
for _svc in order-service inventory-service payment-service; do
  _cnt="$(verify_tracing_jaeger_trace_count "${_jaeger_base}" "${_svc}" "15m")"
  _biz="$(verify_tracing_jaeger_business_trace_count "${_jaeger_base}" "${_svc}" "" "15m")"
  echo "  ${_svc}: 전체 ${_cnt}건 / 비즈니스(operation) ${_biz}건 (Jaeger 상한 50)"
done
echo
echo "  최근 order-service 비즈니스 trace (POST /api/orders):"
_summary="$(verify_tracing_latest_trace_summary "${_jaeger_base}" "order-service" "http post /api/orders")"
_span_count="$(echo "${_summary}" | head -1)"
if [[ "${_span_count}" =~ ^[0-9]+$ ]] && [[ "${_span_count}" -gt 0 ]]; then
  echo "${_summary}" | tail -n +2 | sed 's/^/    /'
else
  echo "    (없음 — 트래픽·OTLP·Jaeger 저장소(memory) 확인)"
fi
echo
if ! verify_tracing_kiali_app_traces msaedu order-service; then
  echo "  → Kiali Traces 가 비어 있습니다. 아래를 확인하세요:" >&2
  echo "     1) infra/k8s/07-otel-collector.yaml — attributes/kiali (istio.cluster_id=Kubernetes)" >&2
  echo "        kubectl apply -f infra/k8s/07-otel-collector.yaml && kubectl rollout restart ds/otel-collector -n observe" >&2
  echo "     2) infra/helm/kiali.yaml — tracing.namespace_selector: false, kubernetes_config.cluster_name" >&2
  echo "     3) 데모 트래픽(위 2/4) 후 10~20초 대기 — 기존 스팬에는 태그가 없을 수 있음" >&2
  echo "     Jaeger UI(${JAEGER_UI}) 에서는 order-service 로 조회 가능할 수 있습니다." >&2
  exit 1
fi
echo

echo ">>> [4/4] Kiali UI 확인 절차 (케이스 A — 정상 3단 스팬)"
cat <<EOF

  1) 브라우저: ${KIALI_URL}
  2) Graph: Namespace msaedu + istio-system | Last 5m | Versioned app graph
  3) order-service 노드 클릭 → Traces (Overview 가 아님)
  4) Jaeger 서비스명은 order-service (namespace 접미사 없음) | Last 15 minutes
  ※ Overview 의 otel-collector 100% 는 메시 메트릭 헬스로, Traces 탭과 별개일 수 있음
  5) Trace 선택 → Timeline 에서 스팬 확인:
       order-service (POST /api/orders)
         └ inventory-service (POST /api/inventories/reserve)
              └ payment-service (POST /api/payments)

  Jaeger UI 직접 비교: ${JAEGER_UI}
    Service: order-service → Find Traces

EOF

echo "--- 케이스 B (선택) — inventory 503 / payment 스팬 없음 ---"
echo "  ./infra/scripts/09_demo-inventory-circuit-break.sh 의 Phase 1 직후 Kiali 에서:"
echo "  inventory-service Traces → http.status_code=503, payment-service 자식 스팬 없음"
echo
echo "  order-service Pod 로그 traceId 상관:"
echo "    kubectl logs -n msaedu deploy/order-service -c order-service --tail=5"
echo
echo "완료."
