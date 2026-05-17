#!/usr/bin/env bash
# Grafana(sidecar)에 Istio 공식 대시보드 JSON 을 ConfigMap 으로 적재한다.
# Kiali external_services.grafana.dashboards 와 제목이 일치해야 Metrics 탭 링크가 생긴다.
#
# 교육 클러스터 보정:
# - Service 대시보드: destination_service(FQDN) → destination_service_name(Kiali·Prometheus 라벨과 일치)
# - datasource 템플릿 기본값: uid prometheus (kube-prometheus-stack)
set -euo pipefail

_observe_ns="${OBSERVE_NAMESPACE:-observe}"
_istio_ver="${ISTIO_DASHBOARD_VERSION:-}"

if [[ -z "${_istio_ver}" ]]; then
  if command -v istioctl >/dev/null 2>&1; then
    _istio_ver="$(istioctl version --remote=false --short 2>/dev/null | awk '/client version:/{print $3; exit}')"
  fi
  _istio_ver="${_istio_ver:-1.29.2}"
fi

_base="https://raw.githubusercontent.com/istio/istio/${_istio_ver}/manifests/addons/dashboards"

# file_base -> Kiali dashboards[].name (Grafana JSON 의 title 과 동일)
_dashboards=(
  "istio-service-dashboard:Istio Service Dashboard"
  "istio-workload-dashboard:Istio Workload Dashboard"
  "istio-mesh-dashboard.gen:Istio Mesh Dashboard"
  "pilot-dashboard.gen:Istio Control Plane Dashboard"
  "istio-performance-dashboard:Istio Performance Dashboard"
  "istio-extension-dashboard:Istio Wasm Extension Dashboard"
)

_patch_dashboard_json() {
  # 파이프로 넘긴 JSON 은 Python stdin 에서 읽는다.
  # (heredoc 로 Python 스크립트를 넘기면 stdin 이 heredoc 으로 잡혀 JSON 파싱이 실패함)
  local _file="$1"
  python3 -c '
import json, re, sys

file_id = sys.argv[1]
raw = sys.stdin.read()
if not raw.strip():
    sys.stderr.write("empty dashboard JSON on stdin\n")
    sys.exit(1)
doc = json.loads(raw)

_ds_current = {"selected": True, "text": "Prometheus", "value": "prometheus"}

def patch_expr(expr: str) -> str:
    if not expr or "destination_service" not in expr:
        return expr
    expr = re.sub(r"\bdestination_service=~", "destination_service_name=~", expr)
    expr = re.sub(r"\bdestination_service!~", "destination_service_name!~", expr)
    expr = re.sub(r"\bdestination_service=", "destination_service_name=", expr)
    expr = re.sub(r"\bdestination_service!", "destination_service_name!", expr)
    return expr

def walk(obj):
    if isinstance(obj, dict):
        if "expr" in obj and isinstance(obj["expr"], str):
            obj["expr"] = patch_expr(obj["expr"])
        for v in obj.values():
            walk(v)
    elif isinstance(obj, list):
        for v in obj:
            walk(v)

if "service-dashboard" in file_id:
    walk(doc)

for t in doc.get("templating", {}).get("list", []):
    if t.get("name") == "datasource" and t.get("type") == "datasource":
        t["current"] = _ds_current
        t["query"] = "prometheus"

print(json.dumps(doc, separators=(",", ":")))
' "${_file}"
}

echo "[grafana-istio] Istio ${_istio_ver} 대시보드 ConfigMap 적용 (namespace=${_observe_ns})"

for _entry in "${_dashboards[@]}"; do
  _file="${_entry%%:*}"
  _title="${_entry#*:}"
  _url="${_base}/${_file}.json"
  _cm="grafana-dashboard-${_file//./-}"

  if ! _json="$(curl -fsSL "${_url}")"; then
    echo "[grafana-istio] 경고: ${_url} 다운로드 실패 — 건너뜀" >&2
    continue
  fi

  _json="$(printf '%s' "${_json}" | _patch_dashboard_json "${_file}")"

  _got_title="$(printf '%s' "${_json}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('title',''))" 2>/dev/null || true)"
  if [[ -n "${_got_title}" && "${_got_title}" != "${_title}" ]]; then
    echo "[grafana-istio] 참고: ${_file} title='${_got_title}' (Kiali name='${_title}')"
  fi

  kubectl create configmap "${_cm}" \
    --namespace "${_observe_ns}" \
    --from-literal="${_file}.json=${_json}" \
    --dry-run=client -o yaml | \
    kubectl label --local -f - grafana_dashboard=1 --dry-run=client -o yaml | \
    kubectl apply -f - >/dev/null

  echo "  - ${_cm} (${_title})"
done

echo "[grafana-istio] 완료 (Service 대시보드: destination_service_name 패치 적용)."
echo "  Grafana UI에서 데이터가 없으면: infra/scripts/06_verify-observability.sh 의 Prometheus 점검 참고."
