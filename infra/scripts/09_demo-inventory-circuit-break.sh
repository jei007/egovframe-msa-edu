#!/usr/bin/env bash
# inventory 라운드로빈 → risky 5xx 연속 10회 → 서킷브레이크 → latest 100% → HPA 스케일아웃.
# 진입점: POST http://localhost:18088/api/orders (본문 없이 호출 가능)
#
# 주의: 서킷브레이크까지 최소 약 20회(라운드로빈으로 risky 10회 실패) 필요.
#       20회만 하고 502 가 섞이면 "실패"가 아니라 CB 발동 전 단계일 수 있음.
set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_infra_dir="$(cd "${_script_dir}/.." && pwd)"
REPO_ROOT_DEFAULT="$(cd "${_infra_dir}/.." && pwd)"

_from_env=false
if [[ "${EGOVFRAME_MSA_ROOT+set}" == "set" ]]; then
  _from_env=true
  _saved_root="${EGOVFRAME_MSA_ROOT}"
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
cd "${REPO_ROOT}"

LAB_ACCESS_HOST="${LAB_ACCESS_HOST:-localhost}"
LAB_PORT_INGRESS="${LAB_PORT_INGRESS:-18088}"
LAB_PORT_KIALI="${LAB_PORT_KIALI:-13001}"
PHASE1="${1:-25}"
PHASE2="${2:-80}"
SLEEP_SEC="${3:-0.15}"
INGRESS_URL="http://${LAB_ACCESS_HOST}:${LAB_PORT_INGRESS}"

if ! curl -s -o /dev/null --connect-timeout 2 -X POST "${INGRESS_URL}/api/orders" 2>/dev/null; then
  echo "Ingress(${INGRESS_URL}) 에 연결할 수 없습니다." >&2
  echo "  먼저 ./infra/scripts/05_start-lab-access.sh start" >&2
  exit 1
fi

echo "=== inventory 서킷브레이커 + HPA 데모 ==="
echo "  URL: POST ${INGRESS_URL}/api/orders"
echo
echo "[조건] ROUND_ROBIN → risky 5xx 연속 10회 → 50s 격리 → latest 100%"
echo "[Kiali] http://${LAB_ACCESS_HOST}:${LAB_PORT_KIALI}/kiali/"
echo "        Versioned app graph | msaedu+istio-system | Response Code | Last 5m"
echo

_cb_one() {
  curl -s -o /dev/null -w '%{http_code}' -X POST "${INGRESS_URL}/api/orders"
}

echo ">>> [1/3] 서킷브레이크 유도 (${PHASE1}회) — 초반 502/201 교차는 정상"
_ok=0 _5xx=0
for _i in $(seq 1 "${PHASE1}"); do
  _code="$(_cb_one)"
  case "${_code}" in
    201) _ok=$((_ok + 1)) ;;
    502|503) _5xx=$((_5xx + 1)) ;;
  esac
  printf '  [%02d] HTTP %s\n' "${_i}" "${_code}"
  sleep "${SLEEP_SEC}"
done
echo "  요약: 201=${_ok}, 5xx=${_5xx}"
echo "  이후 구간에서 201 만 나오면 risky 가 격리된 것(서킷브레이크 발동)."
echo

echo ">>> [2/3] 격리 확인 (10회)"
_ok2=0 _5xx2=0
for _i in $(seq 1 10); do
  _code="$(_cb_one)"
  case "${_code}" in 201) _ok2=$((_ok2 + 1)) ;; 502|503) _5xx2=$((_5xx2 + 1)) ;; esac
  printf '  [check-%02d] HTTP %s\n' "${_i}" "${_code}"
  sleep "${SLEEP_SEC}"
done
echo "  check 요약: 201=${_ok2}, 5xx=${_5xx2} (기대: 201=10, 5xx=0)"
echo

echo ">>> [3/3] HPA 스케일아웃 유도 (${PHASE2}회, latest 부하)"
echo "  다른 터미널: kubectl get hpa,deploy -n msaedu -w"
_ok3=0
for _i in $(seq 1 "${PHASE2}"); do
  _code="$(_cb_one)"
  [[ "${_code}" == "201" ]] && _ok3=$((_ok3 + 1))
  # 10회마다 진행 표시
  if (( _i % 10 == 0 )); then
    _hpa="$(kubectl get hpa inventory-service-latest-hpa -n msaedu -o jsonpath='{.status.currentReplicas}/{.spec.maxReplicas} cpu={.status.currentMetrics[0].resource.current.averageUtilization}%' 2>/dev/null || echo '?')"
    printf '  ... %3d회 201=%d  HPA replicas=%s\n' "${_i}" "${_ok3}" "${_hpa}"
  fi
done
echo
kubectl get hpa,deploy -n msaedu -l app=inventory-service 2>/dev/null || kubectl get hpa,deploy -n msaedu
echo
echo "완료. Kiali Graph 를 Refresh 하고 inventory-service 의 latest/risky 비율을 확인하세요."
echo "  트레이스 확인: ./infra/scripts/10_demo-kiali-traces.sh (정상 3단 스팬) 또는 Phase 1 직후 inventory 503 트레이스"
