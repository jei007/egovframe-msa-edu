#!/usr/bin/env bash
# 04_deploy-apps.sh 이후: localhost port-forward + Kiali/Grafana Helm URL 보정.
# macOS·Windows WSL 동일 포트( infra/lab-access.env ) 사용.
#
# 사용법:
#   ./infra/scripts/05_start-lab-access.sh          # start (기본)
#   ./infra/scripts/05_start-lab-access.sh start
#   ./infra/scripts/05_start-lab-access.sh stop
#   ./infra/scripts/05_start-lab-access.sh status
#   ./infra/scripts/05_start-lab-access.sh urls
set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/lab-access-common.sh
source "${_script_dir}/lib/lab-access-common.sh"
lab_access_bootstrap "${_script_dir}"
cd "${REPO_ROOT}"

_cmd="${1:-start}"

_lab_kill_port() {
  local _port="$1" _pid _pids
  if command -v lsof >/dev/null 2>&1; then
    _pids="$(lsof -ti ":${_port}" 2>/dev/null || true)"
    if [[ -n "${_pids}" ]]; then
      while IFS= read -r _pid; do
        [[ -n "${_pid}" ]] || continue
        kill "${_pid}" 2>/dev/null || true
      done <<<"${_pids}"
    fi
  elif command -v fuser >/dev/null 2>&1; then
    fuser -k "${_port}/tcp" 2>/dev/null || true
  fi
}

_lab_stop_one() {
  local _name="$1"
  local _pid_file="${LAB_ACCESS_PID_DIR}/${_name}.pid"
  if [[ -f "${_pid_file}" ]]; then
    local _pid
    _pid="$(cat "${_pid_file}")"
    if kill -0 "${_pid}" 2>/dev/null; then
      kill "${_pid}" 2>/dev/null || true
    fi
    rm -f "${_pid_file}"
  fi
}

lab_access_stop() {
  echo "[lab-access] port-forward 중지"
  if [[ -d "${LAB_ACCESS_PID_DIR}" ]]; then
    local _pid_file _shopt_nullglob
    _shopt_nullglob="$(shopt -p nullglob 2>/dev/null || true)"
    shopt -s nullglob
    for _pid_file in "${LAB_ACCESS_PID_DIR}"/*.pid; do
      _lab_stop_one "$(basename "${_pid_file}" .pid)"
    done
    if [[ -n "${_shopt_nullglob:-}" ]]; then
      eval "${_shopt_nullglob}"
    else
      shopt -u nullglob 2>/dev/null || true
    fi
  fi
  _lab_kill_port "${LAB_PORT_KIALI}"
  _lab_kill_port "${LAB_PORT_GRAFANA}"
  _lab_kill_port "${LAB_PORT_JAEGER}"
  _lab_kill_port "${LAB_PORT_PROMETHEUS}"
  _lab_kill_port "${LAB_PORT_LOKI}"
  _lab_kill_port "${LAB_PORT_ORDER}"
  _lab_kill_port "${LAB_PORT_PAYMENT}"
  _lab_kill_port "${LAB_PORT_INVENTORY}"
  _lab_kill_port "${LAB_PORT_INGRESS}"
  echo "[lab-access] 중지 완료"
}

_lab_wait_http() {
  local _url="$1"
  local _max="${2:-30}"
  local _i
  for ((_i = 1; _i <= _max; _i++)); do
    if curl -sf -o /dev/null --connect-timeout 1 "${_url}" 2>/dev/null \
      || curl -sf -o /dev/null --connect-timeout 1 -L "${_url}" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

_lab_pf_start() {
  local _name="$1" _ns="$2" _svc="$3" _local="$4" _remote="$5"
  mkdir -p "${LAB_ACCESS_PID_DIR}" "${LAB_ACCESS_DIR}"
  _lab_stop_one "${_name}"
  _lab_kill_port "${_local}"
  if ! kubectl get "svc/${_svc}" -n "${_ns}" >/dev/null 2>&1; then
    echo "[lab-access] 건너뜀: ${_ns}/${_svc} 없음" >&2
    return 0
  fi
  kubectl port-forward -n "${_ns}" "svc/${_svc}" "${_local}:${_remote}" \
    >"${LAB_ACCESS_DIR}/${_name}.log" 2>&1 &
  echo "$!" >"${LAB_ACCESS_PID_DIR}/${_name}.pid"
  sleep 0.3
  if ! kill -0 "$(cat "${LAB_ACCESS_PID_DIR}/${_name}.pid")" 2>/dev/null; then
    echo "[lab-access] 실패: ${_name} port-forward (로그: ${LAB_ACCESS_DIR}/${_name}.log)" >&2
    tail -5 "${LAB_ACCESS_DIR}/${_name}.log" 2>/dev/null >&2 || true
    rm -f "${LAB_ACCESS_PID_DIR}/${_name}.pid"
    return 1
  fi
}

lab_access_ensure_istio_prometheus() {
  if ! kubectl get namespace observe >/dev/null 2>&1; then
    return 0
  fi
  echo "[lab-access] Istio Envoy → Prometheus (Kiali Traffic Graph)"
  kubectl apply -f infra/k8s/09-istio-envoy-podmonitor.yaml >/dev/null

  local _prom_url _i _targets
  _prom_url="$(lab_access_base_url "${LAB_PORT_PROMETHEUS}")"
  for ((_i = 1; _i <= 24; _i++)); do
    _targets="$(curl -sf "${_prom_url}/api/v1/targets" 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(sum(1 for t in d['data']['activeTargets'] if 'istio-envoy-stats' in t.get('scrapePool','')))" 2>/dev/null \
      || echo 0)"
    if [[ "${_targets:-0}" -ge 1 ]]; then
      echo "[lab-access] Prometheus Istio 스크랩 타깃 ${_targets}개 확인"
      return 0
    fi
    sleep 5
  done
  echo "[lab-access] 경고: Prometheus 가 Istio PodMonitor 를 아직 반영하지 않았습니다." >&2
  echo "  statefulset/prometheus-kube-prometheus-stack-prometheus 재시작 후 1분 뒤 Kiali 그래프를 확인하세요." >&2
  kubectl rollout restart statefulset/prometheus-kube-prometheus-stack-prometheus -n observe >/dev/null 2>&1 || true
}

lab_access_apply_helm() {
  local _grafana_url _jaeger_url _kiali_fqdn
  _grafana_url="$(lab_access_base_url "${LAB_PORT_GRAFANA}")"
  _jaeger_url="$(lab_access_base_url "${LAB_PORT_JAEGER}")"
  _kiali_fqdn="${LAB_ACCESS_HOST}:${LAB_PORT_KIALI}"

  mkdir -p "${LAB_ACCESS_DIR}"
  cat >"${LAB_ACCESS_DIR}/grafana-lab-values.yaml" <<EOF
grafana:
  grafana.ini:
    server:
      root_url: ${_grafana_url}/
      domain: ${LAB_ACCESS_HOST}
EOF

  if ! command -v helm >/dev/null 2>&1; then
    echo "helm 이 PATH 에 없습니다. 03_install-observability.sh 를 먼저 실행하세요." >&2
    exit 1
  fi

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add kiali https://kiali.org/helm-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true

  if ! kubectl get namespace observe >/dev/null 2>&1; then
    echo "[lab-access] observe 네임스페이스가 없습니다. 03_install-observability.sh 를 먼저 실행하세요." >&2
    return 1
  fi

  echo "[lab-access] Grafana root_url → ${_grafana_url}/"
  if helm status kube-prometheus-stack -n observe >/dev/null 2>&1; then
    helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
      -n observe \
      -f infra/helm/kube-prometheus-stack.yaml \
      -f "${LAB_ACCESS_DIR}/grafana-lab-values.yaml" \
      --reuse-values \
      --wait --timeout 10m
  else
    echo "[lab-access] 경고: kube-prometheus-stack 릴리스 없음 — Grafana Helm 업데이트 생략" >&2
  fi

  if kubectl get svc kiali -n observe >/dev/null 2>&1; then
    echo "[lab-access] Kiali external_url (Grafana/Jaeger) 및 web_fqdn → ${_kiali_fqdn}"
    if helm status kiali-server -n observe >/dev/null 2>&1; then
      helm upgrade kiali-server kiali/kiali-server \
        -n observe \
        -f infra/helm/kiali.yaml \
        --set-string "server.web_fqdn=${_kiali_fqdn}" \
        --set-string "external_services.grafana.external_url=${_grafana_url}" \
        --set-string "external_services.tracing.external_url=${_jaeger_url}" \
        --reuse-values \
        --wait --timeout 10m
    else
      echo "[lab-access] 경고: kiali-server 릴리스 없음 — Kiali Helm 업데이트 생략" >&2
    fi
  else
    echo "[lab-access] 경고: observe/kiali 가 없어 Kiali Helm 업데이트를 건너뜁니다." >&2
  fi
}

lab_access_start_forwards() {
  local _failed=0
  echo "[lab-access] kubectl port-forward 시작 (${LAB_ACCESS_HOST})"

  _lab_pf_start kiali observe kiali "${LAB_PORT_KIALI}" 20001 || _failed=1
  _lab_pf_start grafana observe kube-prometheus-stack-grafana "${LAB_PORT_GRAFANA}" 80 || _failed=1
  _lab_pf_start jaeger observe jaeger-ui-nodeport "${LAB_PORT_JAEGER}" 16686 || _failed=1
  _lab_pf_start prometheus observe kube-prometheus-stack-prometheus "${LAB_PORT_PROMETHEUS}" 9090 || _failed=1
  _lab_pf_start loki observe loki-gateway "${LAB_PORT_LOKI}" 80 || true

  _lab_pf_start order msaedu order-service "${LAB_PORT_ORDER}" 8080 || _failed=1
  _lab_pf_start payment msaedu payment-service "${LAB_PORT_PAYMENT}" 8081 || _failed=1
  _lab_pf_start inventory msaedu inventory-service "${LAB_PORT_INVENTORY}" 8082 || _failed=1
  _lab_pf_start ingress istio-system istio-ingressgateway "${LAB_PORT_INGRESS}" 80 || _failed=1

  if [[ "${_failed}" -ne 0 ]]; then
    echo "[lab-access] 일부 port-forward 가 실패했습니다. 04_deploy-apps.sh·03_install-observability.sh 실행 여부를 확인하세요." >&2
    return 1
  fi
  sleep 2
}

lab_access_wait_ready() {
  local _ok=true
  echo "[lab-access] HTTP 준비 대기"
  _lab_wait_http "$(lab_access_base_url "${LAB_PORT_KIALI}")/kiali/" 45 || _ok=false
  _lab_wait_http "$(lab_access_base_url "${LAB_PORT_GRAFANA}")/login" 45 || _ok=false
  _lab_wait_http "$(lab_access_base_url "${LAB_PORT_JAEGER}")/" 45 || _ok=false
  _lab_wait_http "$(lab_access_base_url "${LAB_PORT_PROMETHEUS}")/-/ready" 45 || _ok=false
  if [[ -f "${LAB_ACCESS_PID_DIR}/loki.pid" ]]; then
    _lab_wait_http "$(lab_access_base_url "${LAB_PORT_LOKI}")/" 15 || _ok=false
  fi
  if [[ "${_ok}" != "true" ]]; then
    echo "[lab-access] 경고: 일부 URL 이 아직 응답하지 않습니다. 로그: ${LAB_ACCESS_DIR}/*.log" >&2
  fi
}

lab_access_print_urls() {
  local _g _k _j _p _l _o _pay _inv _ing
  _g="$(lab_access_base_url "${LAB_PORT_GRAFANA}")"
  _k="$(lab_access_base_url "${LAB_PORT_KIALI}")"
  _j="$(lab_access_base_url "${LAB_PORT_JAEGER}")"
  _p="$(lab_access_base_url "${LAB_PORT_PROMETHEUS}")"
  _l="$(lab_access_base_url "${LAB_PORT_LOKI}")"
  _o="$(lab_access_base_url "${LAB_PORT_ORDER}")"
  _pay="$(lab_access_base_url "${LAB_PORT_PAYMENT}")"
  _inv="$(lab_access_base_url "${LAB_PORT_INVENTORY}")"
  _ing="$(lab_access_base_url "${LAB_PORT_INGRESS}")"

  cat <<EOF

=== 실습 브라우저 URL (${LAB_ACCESS_HOST} port-forward) ===

[관측]
  Kiali       ${_k}/kiali/
  Grafana     ${_g}  (admin / admin)
  Jaeger      ${_j}
  Prometheus  ${_p}
  Loki        ${_l}  (API; 로그 탐색은 Grafana Explore)

[애플리케이션]   진입점은 Ingress(Order API). 흐름: order → inventory(latest|risky 라운드로빈) → payment
  Order API   POST ${_ing}/api/orders          (curl -X POST 만으로 호출 가능, CB·라운드로빈 적용)
  Order       ${_o}/swagger-ui.html             (단일 Pod 직접 호출, CB 미적용)
  Payment     ${_pay}/swagger-ui.html
  Inventory   ${_inv}/swagger-ui.html           (단일 endpoint 직접 호출 — 라운드로빈 미적용)

중지: ./infra/scripts/05_start-lab-access.sh stop
상태: ./infra/scripts/05_start-lab-access.sh status

EOF
}

lab_access_status() {
  echo "[lab-access] port-forward 프로세스"
  if [[ ! -d "${LAB_ACCESS_PID_DIR}" ]]; then
    echo "  (실행 중인 포워드 없음 — start 로 시작)"
    return 0
  fi
  local _name _pid_file _pid _shopt_nullglob
  _shopt_nullglob="$(shopt -p nullglob 2>/dev/null || true)"
  shopt -s nullglob
  for _pid_file in "${LAB_ACCESS_PID_DIR}"/*.pid; do
    _name="$(basename "${_pid_file}" .pid)"
    _pid="$(cat "${_pid_file}")"
    if kill -0 "${_pid}" 2>/dev/null; then
      echo "  OK  ${_name} (pid ${_pid})"
    else
      echo "  DEAD  ${_name} (stale pid ${_pid})"
    fi
  done
  if [[ -n "${_shopt_nullglob:-}" ]]; then
    eval "${_shopt_nullglob}"
  else
    shopt -u nullglob 2>/dev/null || true
  fi
}

lab_access_start() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "kubectl 이 PATH 에 없습니다." >&2
    exit 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl 이 PATH 에 없습니다." >&2
    exit 1
  fi
  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Kubernetes API 에 연결할 수 없습니다. 클러스터를 기동한 뒤 다시 실행하세요." >&2
    exit 1
  fi

  lab_access_stop
  # Helm 이 Pod 를 재시작하므로 port-forward 보다 먼저 적용한다.
  lab_access_apply_helm || echo "[lab-access] 경고: Helm URL 보정 실패 — port-forward 는 계속 시도" >&2
  if kubectl get deployment kiali -n observe >/dev/null 2>&1; then
    kubectl rollout status deployment/kiali -n observe --timeout=5m >/dev/null 2>&1 || true
  fi
  if kubectl get deployment -n observe -l app.kubernetes.io/name=grafana >/dev/null 2>&1; then
    kubectl rollout status deployment -n observe -l app.kubernetes.io/name=grafana --timeout=5m >/dev/null 2>&1 || true
  fi
  lab_access_start_forwards
  lab_access_wait_ready
  lab_access_ensure_istio_prometheus
  lab_access_print_urls
  echo "[lab-access] Kiali Traffic Graph: 주문 API 로 트래픽 발생 후 Last 5m 으로 확인"
  echo "  예: curl -X POST $(lab_access_base_url "${LAB_PORT_INGRESS}")/api/orders"
  echo "[lab-access] port-forward 는 백그라운드로 유지됩니다. 중지: $0 stop"
}

case "${_cmd}" in
  start) lab_access_start ;;
  stop) lab_access_stop ;;
  status) lab_access_status ;;
  urls) lab_access_print_urls ;;
  -h | --help)
    cat <<EOF
Usage: $0 [start|stop|status|urls]

  start   Helm URL 보정 후 localhost port-forward 시작 (기본)
  stop    port-forward 중지
  status  포워드 프로세스 상태
  urls    브라우저 URL 목록만 출력

포트 변경: infra/lab-access.env
EOF
    ;;
  *)
    echo "알 수 없는 명령: ${_cmd} (start|stop|status|urls)" >&2
    exit 1
    ;;
esac
