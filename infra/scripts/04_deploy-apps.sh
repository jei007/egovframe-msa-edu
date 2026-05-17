#!/usr/bin/env bash
# 세 서비스(order, inventory-latest/risky, payment) Deployment·Service 와 Istio 라우팅·복원력
# 매니페스트를 일괄 적용하고 롤아웃을 기다린다.
# 흐름: ingressgateway → order → inventory(라운드로빈: latest|risky) → payment.
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

# 이전 실습에서 만든 latest/risky order Deployment 가 남아 있을 수 있어 정리한다.
kubectl delete deployment order-service-latest order-service-risky -n msaedu --ignore-not-found=true 2>/dev/null || true
# 단일 inventory Deployment(이전 구조) 도 정리.
kubectl delete deployment inventory-service -n msaedu --ignore-not-found=true 2>/dev/null || true
# 이전 destinationrule(payment-service-dr / order-service-dr) 정리(현 구성에는 없다).
kubectl delete destinationrule order-service-dr payment-service-dr -n msaedu --ignore-not-found=true 2>/dev/null || true

echo "[1/3] 워크로드 배포"
kubectl apply -f <(sed "s|your-registry/order-service:1.0.0|${REGISTRY}/order-service:${TAG}|g" infra/k8s/02-order-service.yaml)
kubectl apply -f <(sed "s|your-registry/payment-service:1.0.0|${REGISTRY}/payment-service:${TAG}|g" infra/k8s/03-payment-service.yaml)
kubectl apply -f <(sed "s|your-registry/inventory-service:1.0.0|${REGISTRY}/inventory-service:${TAG}|g" infra/k8s/04-inventory-service.yaml)

echo "[2/3] Istio 라우팅·복원력·메쉬 외부 호출 정책"
kubectl apply -f infra/k8s/05-istio-ingress-and-routing.yaml
kubectl apply -f infra/k8s/06-istio-resilience.yaml
kubectl apply -f infra/k8s/10-inventory-circuit-breaking.yaml
kubectl apply -f infra/k8s/11-mesh-egress-to-observe.yaml

echo "[3/3] 롤아웃 대기"
kubectl rollout status deployment/order-service -n msaedu --timeout=5m
kubectl rollout status deployment/payment-service -n msaedu --timeout=5m
kubectl rollout status deployment/inventory-service-latest -n msaedu --timeout=5m
kubectl rollout status deployment/inventory-service-risky -n msaedu --timeout=5m

echo
echo "Application deployment completed."
echo "  진입점:   POST http://localhost:18088/api/orders   (./infra/scripts/05_start-lab-access.sh start 후)"
echo "  서킷BR 데모: ./infra/scripts/09_demo-inventory-circuit-break.sh"
echo "  트레이스 데모: ./infra/scripts/10_demo-kiali-traces.sh"
echo "  Kiali:    http://localhost:13001/kiali/"
