#!/usr/bin/env bash
# observe·msaedu 관련 리소스가 눈에 보이는지 kubectl 로 점검한다(교육 중 상태 확인용).
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

echo "[1/8] observe Pod (사이드카 없어야 정상)"
kubectl get pods -n observe

echo
echo "[2/8] observe 네임스페이스 라벨 (istio-injection 이 없어야 한다)"
kubectl get namespace observe --show-labels

echo
echo "[3/8] msaedu 워크로드 (order, inventory-latest/risky, payment)"
kubectl get deploy,svc,hpa -n msaedu

echo
echo "[4/8] inventory Pod 라벨(version=latest|risky) 확인"
kubectl get pods -n msaedu -l app=inventory-service \
  -o custom-columns='NAME:.metadata.name,VERSION:.metadata.labels.version,READY:.status.containerStatuses[*].ready'

echo
echo "[5/8] Istio 라우팅·복원력 리소스"
kubectl get gateway,virtualservice,destinationrule -n msaedu

echo
echo "[6/8] OTel Collector / Istio Envoy PodMonitor"
kubectl get svc otel-collector -n observe 2>/dev/null || true
kubectl get podmonitor istio-envoy-stats -n observe 2>/dev/null || true

echo
echo "[7/8] Prometheus Istio 메트릭 (Grafana 대시보드·Kiali Graph 공통)"
if kubectl get svc kube-prometheus-stack-prometheus -n observe >/dev/null 2>&1; then
  kubectl run prom-istio-check --rm -i --restart=Never -n observe \
    --image=curlimages/curl:latest \
    --command -- sh -c '
      P="http://kube-prometheus-stack-prometheus.observe:9090"
      c=$(curl -sG "${P}/api/v1/query" --data-urlencode "query=count(istio_requests_total)" | \
        python3 -c "import json,sys; d=json.load(sys.stdin); r=d.get(\"data\",{}).get(\"result\",[]); print(r[0][\"value\"][1] if r else 0)" 2>/dev/null || echo 0)
      echo "  istio_requests_total series count: ${c}"
      if [ "${c}" = "0" ]; then
        echo "  → 비어 있음: 09-istio-envoy-podmonitor.yaml 적용·Ingress(18088) 트래픽·Prometheus 재시작 확인"
        exit 1
      fi
      curl -sG "${P}/api/v1/label/destination_workload/values" --data-urlencode "match[]=istio_requests_total{destination_service_namespace=\"msaedu\"}" | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(\"  msaedu workloads:\", \",\".join(d.get(\"data\",[])[:8]))" 2>/dev/null || true
    ' 2>/dev/null || echo "  (prom-istio-check 실행 실패 — observe/Prometheus 확인)"
else
  echo "  kube-prometheus-stack-prometheus Service 없음 — 03_install-observability.sh 먼저 실행"
fi

echo
echo "[8/8] 분산 트레이스 (OTLP → Jaeger, Kiali Traces)"
# shellcheck source=lib/verify-tracing-pipeline.sh
source "${_script_dir}/lib/verify-tracing-pipeline.sh"
verify_tracing_bootstrap "${_script_dir}"
_jaeger_base="$(verify_tracing_jaeger_url)"
if kubectl get deploy/order-service -n msaedu >/dev/null 2>&1; then
  verify_tracing_otlp_from_order || true
  verify_tracing_jaeger_services "${_jaeger_base}" 2>/dev/null || \
    echo "  → Jaeger 서비스 없음: ./infra/scripts/10_demo-kiali-traces.sh 로 트래픽 유도"
else
  echo "  msaedu/order-service 없음 — 04_deploy-apps.sh 후 재실행"
fi

echo
echo "검증 완료."
echo "  Kiali:   http://localhost:13001/kiali/"
echo "  Grafana: http://localhost:13002"
echo "  Jaeger:  http://localhost:13003"
echo "  트레이스 데모: ./infra/scripts/10_demo-kiali-traces.sh"
