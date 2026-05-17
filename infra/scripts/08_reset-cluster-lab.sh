#!/usr/bin/env bash
# 02~04(및 03 관측) 설치로 생긴 클러스터 상태를 지워 처음부터 다시 올릴 수 있게 한다.
# - observe: Helm 릴리스(kube-prometheus-stack, loki, jaeger, kiali-server) 제거 후 네임스페이스 삭제
# - msaedu: 샘플 앱·Istio 라우팅/복원력 리소스가 함께 삭제된다.
# - 07 OTel Collector: 네임스페이스 리소스 + ClusterRole/ClusterRoleBinding 정리
# - 08 Jaeger NodePort Service: 삭제
# 기본은 Istio 제어 플레인(istio-system)은 유지한다. 완전 제거 시 --purge-istio 를 붙인다.
# 01_build-images.sh 가 만든 로컬 Docker 이미지는 건드리지 않는다.
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

if [[ -x "${REPO_ROOT}/infra/scripts/05_start-lab-access.sh" ]]; then
  "${REPO_ROOT}/infra/scripts/05_start-lab-access.sh" stop 2>/dev/null || true
fi

PURGE_ISTIO=false
for _arg in "$@"; do
  case "${_arg}" in
    --purge-istio) PURGE_ISTIO=true ;;
    -h|--help)
      echo "Usage: $0 [--purge-istio]"
      echo "  --purge-istio  istioctl uninstall --purge 로 istio-system 제어 플레인까지 제거한다."
      exit 0
      ;;
  esac
done

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl 이 PATH 에 없습니다." >&2
  exit 1
fi
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "Kubernetes API 에 연결할 수 없습니다. 클러스터를 기동한 뒤 다시 실행하세요." >&2
  exit 1
fi

echo "[1/4] Helm 릴리스 제거 (observe)"
if kubectl get namespace observe >/dev/null 2>&1; then
  for _rel in kiali-server jaeger loki kube-prometheus-stack; do
    if helm list -n observe -q 2>/dev/null | grep -qx "${_rel}"; then
      echo "  - uninstall ${_rel}"
      helm uninstall "${_rel}" -n observe --wait --timeout 10m
    else
      echo "  - skip ${_rel} (없음)"
    fi
  done
else
  echo "  - observe 네임스페이스 없음, Helm 단계 생략"
fi

echo "[2/4] kubectl 로 적용했던 리소스 삭제"
kubectl delete -f infra/k8s/11-mesh-egress-to-observe.yaml --ignore-not-found=true --wait=false 2>/dev/null || true
kubectl delete -f infra/k8s/10-inventory-circuit-breaking.yaml --ignore-not-found=true --wait=false 2>/dev/null || true
kubectl delete -f infra/k8s/09-istio-envoy-podmonitor.yaml --ignore-not-found=true --wait=false 2>/dev/null || true
kubectl delete -f infra/k8s/08-jaeger-ui-nodeport.yaml --ignore-not-found=true --wait=false 2>/dev/null || true
kubectl delete -f infra/k8s/07-otel-collector.yaml --ignore-not-found=true --wait=false 2>/dev/null || true

echo "[3/4] 네임스페이스 삭제 (observe, msaedu)"
kubectl delete namespace observe --ignore-not-found=true --wait=true --timeout=5m 2>/dev/null || true
kubectl delete namespace msaedu --ignore-not-found=true --wait=true --timeout=5m 2>/dev/null || true

echo "[4/4] Istio 제어 플레인(선택)"
if [[ "${PURGE_ISTIO}" == "true" ]]; then
  if command -v istioctl >/dev/null 2>&1; then
    istioctl uninstall --purge -y
  else
    echo "  경고: istioctl 이 없어 Istio 제거를 건너뜁니다." >&2
  fi
else
  echo "  - 유지 (다시 제거하려면: $0 --purge-istio)"
fi

echo "클러스터 실습 리셋 완료. 이후 ./infra/scripts/02_install-istio.sh 부터 순서대로 다시 실행하면 된다."
echo "  (port-forward: 05_start-lab-access.sh 는 stop 으로 이미 중지했을 수 있음)"
