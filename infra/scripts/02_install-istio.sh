#!/usr/bin/env bash
# Istio 제어 플레인을 설치하고 msaedu 네임스페이스에만 사이드카 인젝션을 켠다.
# observe 는 사이드카 없이 운영(11-mesh-egress-to-observe.yaml 의 DestinationRule 로 plain HTTP 허용).
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
if [[ "${_from_env}" == "true" ]]; then
  EGOVFRAME_MSA_ROOT="${_saved_root}"
fi
REPO_ROOT="${EGOVFRAME_MSA_ROOT:-${REPO_ROOT_DEFAULT}}"
export REPO_ROOT
cd "${REPO_ROOT}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl 이 PATH 에 없습니다." >&2
  exit 1
fi
if ! command -v istioctl >/dev/null 2>&1; then
  echo "istioctl is required." >&2
  exit 1
fi

# kubeconfig 가 중지된 minikube 를 가리키면 OpenAPI 다운로드 실패가 난다 → 자동 재시작.
_ensure_kubernetes_ready() {
  if kubectl cluster-info >/dev/null 2>&1; then
    return 0
  fi
  local _ctx _profile
  _ctx="$(kubectl config current-context 2>/dev/null || echo '')"
  if [[ "${_ctx}" == *minikube* ]] && command -v minikube >/dev/null 2>&1; then
    _profile="${MINIKUBE_PROFILE:-minikube}"
    echo "Kubernetes API 에 연결할 수 없습니다. minikube(profile=${_profile}) 를 준비합니다..." >&2
    minikube -p "${_profile}" update-context >/dev/null 2>&1 || true
    if [[ -n "${MINIKUBE_START_ARGS:-}" ]]; then
      # shellcheck disable=SC2086
      minikube -p "${_profile}" start ${MINIKUBE_START_ARGS}
    else
      minikube -p "${_profile}" start
    fi
    if kubectl cluster-info >/dev/null 2>&1; then
      return 0
    fi
  fi
  echo "Kubernetes API 서버에 연결할 수 없습니다." >&2
  exit 1
}
_ensure_kubernetes_ready

kubectl apply -f infra/k8s/01-namespaces.yaml
istioctl install -y --set profile=demo

# msaedu 만 사이드카 주입. observe 는 라벨 제거(이전 실습에서 켜져 있었을 수 있음).
kubectl label namespace msaedu istio-injection=enabled --overwrite
kubectl label namespace observe istio-injection- --overwrite >/dev/null 2>&1 || true

# [HPA·스케일아웃] 04-inventory-service-latest-hpa 가 CPU 메트릭을 쓰려면 metrics-server 필요.
# 09_demo-inventory-circuit-break.sh Phase [3/3] replica 증가 관찰 전제.
if command -v minikube >/dev/null 2>&1; then
  _profile="${MINIKUBE_PROFILE:-minikube}"
  if minikube -p "${_profile}" status >/dev/null 2>&1; then
    minikube -p "${_profile}" addons enable metrics-server >/dev/null 2>&1 || true
  fi
fi

echo "Istio installation completed (msaedu 사이드카 인젝션 ON, observe OFF)."
