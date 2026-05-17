# shellcheck shell=bash
# 05_start-lab-access.sh 공통: REPO_ROOT·lab-access.env 로드.

lab_access_bootstrap() {
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
  if [[ "${_from_env}" == "true" ]]; then
    EGOVFRAME_MSA_ROOT="${_saved_root}"
  fi
  REPO_ROOT="${EGOVFRAME_MSA_ROOT:-${REPO_ROOT_DEFAULT}}"
  export REPO_ROOT

  if [[ -f "${REPO_ROOT}/infra/lab-access.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/infra/lab-access.env"
    set +a
  fi

  LAB_ACCESS_HOST="${LAB_ACCESS_HOST:-localhost}"
  LAB_PORT_KIALI="${LAB_PORT_KIALI:-13001}"
  LAB_PORT_GRAFANA="${LAB_PORT_GRAFANA:-13002}"
  LAB_PORT_JAEGER="${LAB_PORT_JAEGER:-13003}"
  LAB_PORT_PROMETHEUS="${LAB_PORT_PROMETHEUS:-13004}"
  LAB_PORT_LOKI="${LAB_PORT_LOKI:-13005}"
  LAB_PORT_ORDER="${LAB_PORT_ORDER:-18080}"
  LAB_PORT_PAYMENT="${LAB_PORT_PAYMENT:-18081}"
  LAB_PORT_INVENTORY="${LAB_PORT_INVENTORY:-18082}"
  LAB_PORT_INGRESS="${LAB_PORT_INGRESS:-18088}"

  LAB_ACCESS_DIR="${REPO_ROOT}/.lab-access"
  LAB_ACCESS_PID_DIR="${LAB_ACCESS_DIR}/pids"
  export REPO_ROOT LAB_ACCESS_HOST LAB_ACCESS_DIR LAB_ACCESS_PID_DIR
  export LAB_PORT_KIALI LAB_PORT_GRAFANA LAB_PORT_JAEGER LAB_PORT_PROMETHEUS LAB_PORT_LOKI
  export LAB_PORT_ORDER LAB_PORT_PAYMENT LAB_PORT_INVENTORY LAB_PORT_INGRESS
}

lab_access_base_url() {
  printf 'http://%s:%s' "${LAB_ACCESS_HOST}" "$1"
}
