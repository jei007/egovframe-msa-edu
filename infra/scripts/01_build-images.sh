#!/usr/bin/env bash
# Maven 패키징 후 각 서비스 디렉터리의 Dockerfile 로 이미지를 만든다.
# REGISTRY/TAG 는 infra/k8s 의 image 필드와 맞출 것(기본 TAG=1.0.0). 클러스터가 로컬 데몬을 못 보면 push 필요.
# minikube: MINIKUBE_DOCKER=true 이면 minikube docker-env 로 노드에 보이는 데몬에 빌드한다(MINIKUBE_PROFILE 기본 minikube).
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

REGISTRY="${REGISTRY:-your-registry}"
TAG="${TAG:-1.0.0}"

# Minikube: 호스트 Docker 에만 이미지가 있으면 Pod 가 your-registry 를 당겨오려다 실패한다.
# MINIKUBE_DOCKER=true 로 minikube 노드용 Docker 데몬에 빌드하면 imagePullPolicy=IfNotPresent 로 로컬 태그를 쓴다.
if [[ "${MINIKUBE_DOCKER:-}" == "true" ]]; then
  if ! command -v minikube >/dev/null 2>&1; then
    echo "MINIKUBE_DOCKER=true 인데 minikube 가 PATH 에 없습니다." >&2
    exit 1
  fi
  eval "$(minikube -p "${MINIKUBE_PROFILE:-minikube}" docker-env)"
fi

mvn clean package -DskipTests

docker build -t "${REGISTRY}/order-service:${TAG}" order-service
docker build -t "${REGISTRY}/payment-service:${TAG}" payment-service
docker build -t "${REGISTRY}/inventory-service:${TAG}" inventory-service

echo "Built images:"
echo "  ${REGISTRY}/order-service:${TAG}"
echo "  ${REGISTRY}/payment-service:${TAG}"
echo "  ${REGISTRY}/inventory-service:${TAG}"
echo "Push images manually if your cluster cannot access local Docker daemon."

_is_minikube_context=false
if command -v kubectl >/dev/null 2>&1; then
  _ctx="$(kubectl config current-context 2>/dev/null || true)"
  case "${_ctx}" in
    *minikube*) _is_minikube_context=true ;;
  esac
fi

if [[ "${MINIKUBE_DOCKER:-}" == "true" ]]; then
  : # 이미지는 이미 minikube 노드가 보는 Docker 데몬에 있습니다.
elif [[ "${_is_minikube_context}" == "true" ]] && command -v minikube >/dev/null 2>&1; then
  if [[ "${SKIP_MINIKUBE_IMAGE_LOAD:-}" == "true" ]]; then
    echo "SKIP_MINIKUBE_IMAGE_LOAD=true — minikube 로 이미지를 올리지 않았습니다. 노드에 없으면 04 배포 시 ImagePullBackOff 가 납니다."
  else
    echo "kubectl 컨텍스트가 minikube 입니다. 호스트 Docker 이미지를 minikube 노드로 불러옵니다 (건너뛰려면 SKIP_MINIKUBE_IMAGE_LOAD=true)."
    minikube -p "${MINIKUBE_PROFILE:-minikube}" image load "${REGISTRY}/order-service:${TAG}"
    minikube -p "${MINIKUBE_PROFILE:-minikube}" image load "${REGISTRY}/payment-service:${TAG}"
    minikube -p "${MINIKUBE_PROFILE:-minikube}" image load "${REGISTRY}/inventory-service:${TAG}"
  fi
elif command -v minikube >/dev/null 2>&1; then
  echo "Tip (minikube): MINIKUBE_DOCKER=true ./infra/scripts/01_build-images.sh 로 노드용 데몬에 빌드하거나,"
  echo "  kubectl 컨텍스트를 minikube 로 맞춘 뒤 빌드하면 minikube image load 가 자동 실행됩니다."
fi
