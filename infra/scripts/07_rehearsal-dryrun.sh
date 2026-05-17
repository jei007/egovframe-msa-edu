#!/usr/bin/env bash
# 리허설 전: Maven 빌드·스크립트 문법·필수 경로 존재 여부를 빠르게 검증한다.
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

echo "[1/4] Build check"
mvn -DskipTests package >/dev/null
echo "  - OK"

echo "[2/4] Script syntax check"
bash -n infra/scripts/01_build-images.sh
bash -n infra/scripts/02_install-istio.sh
bash -n infra/scripts/03_install-observability.sh
bash -n infra/scripts/04_deploy-apps.sh
bash -n infra/scripts/05_start-lab-access.sh
bash -n infra/scripts/lib/lab-access-common.sh
bash -n infra/scripts/lib/install-grafana-istio-dashboards.sh
bash -n infra/scripts/06_verify-observability.sh
bash -n infra/scripts/07_rehearsal-dryrun.sh
bash -n infra/scripts/08_reset-cluster-lab.sh
bash -n infra/scripts/09_demo-inventory-circuit-break.sh
bash -n infra/scripts/10_demo-kiali-traces.sh
bash -n infra/scripts/lib/verify-tracing-pipeline.sh
echo "  - OK"

echo "[3/4] Core documents check"
test -f docs/rehearsal-120m.md
test -f docs/project-structure.md
echo "  - OK"

echo "[4/4] Kubernetes manifests check"
test -f infra/k8s/01-namespaces.yaml
test -f infra/k8s/02-order-service.yaml
test -f infra/k8s/03-payment-service.yaml
test -f infra/k8s/04-inventory-service.yaml
test -f infra/k8s/05-istio-ingress-and-routing.yaml
test -f infra/k8s/06-istio-resilience.yaml
test -f infra/k8s/07-otel-collector.yaml
test -f infra/k8s/08-jaeger-ui-nodeport.yaml
test -f infra/k8s/09-istio-envoy-podmonitor.yaml
test -f infra/k8s/10-inventory-circuit-breaking.yaml
test -f infra/k8s/11-mesh-egress-to-observe.yaml
test -x infra/scripts/09_demo-inventory-circuit-break.sh
test -x infra/scripts/10_demo-kiali-traces.sh
echo "  - OK"

echo "Rehearsal dry-run completed."
echo "Run full cluster rehearsal using docs/rehearsal-120m.md checklist."
