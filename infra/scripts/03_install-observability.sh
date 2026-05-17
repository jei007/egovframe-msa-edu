#!/usr/bin/env bash
# Helm 으로 Prometheus 스택·Loki·Jaeger·Kiali 를 observe 네임스페이스에 설치한다.
# observe 는 Istio 사이드카 없이 동작한다(02 에서 라벨 제거 보장).
# msaedu → observe 호출은 11-mesh-egress-to-observe.yaml 의 DR 로 TLS DISABLE 처리(04 에서 적용).
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
if ! command -v helm >/dev/null 2>&1; then
  echo "helm 이 PATH 에 없습니다." >&2
  exit 1
fi
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "Kubernetes API 서버에 연결할 수 없습니다." >&2
  exit 1
fi

# observe 네임스페이스 보장 + 인젝션 라벨이 남아있다면 제거.
kubectl apply -f infra/k8s/01-namespaces.yaml
kubectl label namespace observe istio-injection- --overwrite >/dev/null 2>&1 || true

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts >/dev/null
helm repo add kiali https://kiali.org/helm-charts >/dev/null
helm repo update >/dev/null

echo "[1/6] kube-prometheus-stack (Prometheus + Grafana)"
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n observe \
  -f infra/helm/kube-prometheus-stack.yaml

echo "[2/6] Grafana Istio 대시보드 (Kiali Metrics → Grafana 링크용)"
# shellcheck source=lib/install-grafana-istio-dashboards.sh
source "${_script_dir}/lib/install-grafana-istio-dashboards.sh"

echo "[3/6] Loki"
helm upgrade --install loki grafana/loki \
  -n observe \
  -f infra/helm/loki.yaml

echo "[4/6] Jaeger"
helm upgrade --install jaeger jaegertracing/jaeger \
  -n observe \
  -f infra/helm/jaeger.yaml
kubectl apply -f infra/k8s/08-jaeger-ui-nodeport.yaml

echo "[5/6] Kiali"
helm upgrade --install kiali-server kiali/kiali-server \
  -n observe \
  -f infra/helm/kiali.yaml

echo "[6/6] OpenTelemetry Collector + Istio Envoy PodMonitor (msaedu 만)"
kubectl apply -f infra/k8s/07-otel-collector.yaml
kubectl apply -f infra/k8s/09-istio-envoy-podmonitor.yaml

echo
echo "Observability 설치 완료. observe 네임스페이스에는 Istio 사이드카가 없습니다."
echo "다음: ./infra/scripts/04_deploy-apps.sh → ./infra/scripts/05_start-lab-access.sh"
echo "      ./infra/scripts/10_demo-kiali-traces.sh  (Kiali Traces 확인)"
