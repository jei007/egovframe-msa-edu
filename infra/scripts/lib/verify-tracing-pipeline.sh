#!/usr/bin/env bash
# OTLP → otel-collector → Jaeger 파이프라인 점검 (Kiali Traces 탭·Jaeger UI 공통).
# 다른 스크립트에서 source 하여 사용한다. 단독 실행 가능.
set -euo pipefail

verify_tracing_bootstrap() {
  local _scripts_dir="${1:?scripts_dir required}"
  local _infra_dir
  _infra_dir="$(cd "${_scripts_dir}/.." && pwd)"
  REPO_ROOT_DEFAULT="$(cd "${_infra_dir}/.." && pwd)"

  local _from_env=false
  if [[ "${EGOVFRAME_MSA_ROOT+set}" == "set" ]]; then
    _from_env=true
    local _saved_root="${EGOVFRAME_MSA_ROOT}"
  fi
  if [[ -f "${_infra_dir}/config.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${_infra_dir}/config.env"
    set +a
  fi
  if [[ -f "${_infra_dir}/lab-access.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${_infra_dir}/lab-access.env"
    set +a
  fi
  if [[ "${_from_env}" == "true" ]]; then
    EGOVFRAME_MSA_ROOT="${_saved_root}"
  fi
  REPO_ROOT="${EGOVFRAME_MSA_ROOT:-${REPO_ROOT_DEFAULT}}"
  export REPO_ROOT

  LAB_ACCESS_HOST="${LAB_ACCESS_HOST:-localhost}"
  LAB_PORT_JAEGER="${LAB_PORT_JAEGER:-13003}"
  LAB_PORT_KIALI="${LAB_PORT_KIALI:-13001}"
  export LAB_ACCESS_HOST LAB_PORT_JAEGER LAB_PORT_KIALI
}

# stdout: Jaeger Query base URL (localhost port-forward 우선, 실패 시 in-cluster)
verify_tracing_jaeger_url() {
  local _local="http://${LAB_ACCESS_HOST}:${LAB_PORT_JAEGER}"
  if curl -s -o /dev/null --connect-timeout 2 "${_local}/" 2>/dev/null; then
    printf '%s' "${_local}"
    return 0
  fi
  printf '%s' "http://jaeger.observe:16686"
}

verify_tracing_otlp_from_order() {
  local _code
  _code="$(kubectl exec -n msaedu deploy/order-service -c order-service -- \
    curl -s -o /dev/null -w '%{http_code}' -X POST \
    http://otel-collector.observe:4318/v1/traces \
    -H 'Content-Type: application/json' -d '{}' 2>/dev/null || echo "000")"
  echo "  order-service → otel-collector OTLP HTTP: ${_code} (기대 200)"
  [[ "${_code}" == "200" ]]
}

verify_tracing_jaeger_services() {
  local _base="$1"
  local _out
  _out="$(curl -s "${_base}/api/services" 2>/dev/null || echo '{}')"
  printf '%s\n' "${_out}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
svcs = d.get('data') or []
need = {'order-service', 'inventory-service', 'payment-service'}
have = set(svcs)
missing = sorted(need - have)
print('  Jaeger services:', ', '.join(svcs) if svcs else '(none)')
if missing:
    print('  missing:', ', '.join(missing))
    sys.exit(1)
" || return 1
  return 0
}

verify_tracing_jaeger_trace_count() {
  local _base="$1"
  local _service="$2"
  local _lookback="${3:-15m}"
  local _operation="${4:-}"
  local _n
  if [[ -n "${_operation}" ]]; then
    _n="$(curl -sG "${_base}/api/traces" \
      --data-urlencode "service=${_service}" \
      --data-urlencode "operation=${_operation}" \
      --data-urlencode "limit=50" \
      --data-urlencode "lookback=${_lookback}" 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(len(d.get('data') or []))
" 2>/dev/null || echo "0")"
  else
    _n="$(curl -sG "${_base}/api/traces" \
      --data-urlencode "service=${_service}" \
      --data-urlencode "limit=50" \
      --data-urlencode "lookback=${_lookback}" 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(len(d.get('data') or []))
" 2>/dev/null || echo "0")"
  fi
  echo "${_n}"
}

# Jaeger operation 필터(권장) 또는 최근 N건 스캔으로 비즈니스 trace 건수
verify_tracing_jaeger_business_trace_count() {
  local _base="$1"
  local _service="$2"
  local _needle="${3:-/api/orders}"
  local _lookback="${4:-15m}"
  local _operation=""
  case "${_service}" in
    order-service) _operation="http post /api/orders" ;;
    inventory-service) _operation="http post /api/inventories/reserve" ;;
    payment-service) _operation="http post /api/payments" ;;
  esac
  if [[ -n "${_operation}" ]]; then
    verify_tracing_jaeger_trace_count "${_base}" "${_service}" "${_lookback}" "${_operation}"
    return 0
  fi
  curl -sG "${_base}/api/traces" \
    --data-urlencode "service=${_service}" \
    --data-urlencode "limit=50" \
    --data-urlencode "lookback=${_lookback}" 2>/dev/null | python3 -c "
import json, sys
needle = sys.argv[1]
d = json.load(sys.stdin)
n = 0
for t in d.get('data') or []:
    for s in t.get('spans') or []:
        if needle in (s.get('operationName') or ''):
            n += 1
            break
print(n)
" "${_needle}" 2>/dev/null || echo "0"
}

# Kiali Traces API — istio.cluster_id 태그가 스팬에 있어야 data 가 채워짐
verify_tracing_kiali_app_traces() {
  local _ns="${1:-msaedu}"
  local _app="${2:-order-service}"
  local _out _count _tsn _err _kiali_api
  _kiali_api="http://${LAB_ACCESS_HOST}:${LAB_PORT_KIALI}/kiali/api/namespaces/${_ns}/apps/${_app}/traces?limit=5"
  if curl -s -o /dev/null --connect-timeout 2 "http://${LAB_ACCESS_HOST}:${LAB_PORT_KIALI}/kiali/" 2>/dev/null; then
    _out="$(curl -s "${_kiali_api}" 2>/dev/null || echo '{}')"
  else
    _out="$(kubectl run "kiali-trace-$$" --rm -i --restart=Never -n observe \
      --image=curlimages/curl:latest -- \
      curl -s "http://kiali.observe:20001/kiali/api/namespaces/${_ns}/apps/${_app}/traces?limit=5" \
      2>/dev/null || echo '{}')"
  fi
  _parsed="$(printf '%s' "${_out}" | python3 -c "
import json, sys
raw = sys.stdin.read()
start = raw.find('{')
end = raw.rfind('}')
if start < 0 or end < start:
    print('0')
    print('')
    print('')
    sys.exit(0)
d = json.loads(raw[start:end + 1])
errs = d.get('errors') or []
print(len(d.get('data') or []))
print(d.get('tracingServiceName') or '')
print(errs[0] if errs else '')
" 2>/dev/null || printf '0\n\n\n')"
  _count="$(printf '%s' "${_parsed}" | sed -n '1p')"
  _tsn="$(printf '%s' "${_parsed}" | sed -n '2p')"
  _err="$(printf '%s' "${_parsed}" | sed -n '3p')"
  echo "  Kiali apps/${_app}/traces: ${_count}건 (tracingServiceName=${_tsn:-?})"
  [[ -n "${_err}" ]] && echo "  Kiali errors: ${_err}" >&2
  [[ "${_count}" -gt 0 ]]
}

# 최근 trace 1건 요약. _operation 이 있으면 Jaeger operation 필터 사용.
verify_tracing_latest_trace_summary() {
  local _base="$1"
  local _service="${2:-order-service}"
  local _operation="${3:-}"
  local _url="${_base}/api/traces"
  local _args=(
    -sG "${_url}"
    --data-urlencode "service=${_service}"
    --data-urlencode "limit=5"
    --data-urlencode "lookback=15m"
  )
  if [[ -n "${_operation}" ]]; then
    _args+=(--data-urlencode "operation=${_operation}")
  elif [[ "${_service}" == "order-service" ]]; then
    _args+=(--data-urlencode "operation=http post /api/orders")
  fi
  curl "${_args[@]}" 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
traces = d.get('data') or []
if not traces:
    print('0')
    sys.exit(0)
t = traces[0]
spans = t.get('spans') or []
processes = t.get('processes') or {}
svcs = []
ops = []
for s in spans:
    pid = s.get('processID')
    p = processes.get(pid) or {}
    svc = (p.get('serviceName') or '?')
    if svc not in svcs:
        svcs.append(svc)
    op = s.get('operationName') or ''
    if op and op not in ops:
        ops.append(op)
print(len(spans))
print('traceID:', t.get('traceID', ''))
print('services:', ' -> '.join(svcs))
print('operations:', ', '.join(ops[:6]))
" 2>/dev/null || echo "0"
}
