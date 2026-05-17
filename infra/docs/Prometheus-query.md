# Prometheus 쿼리 가이드 — inventory 서킷브레이커 데모

`09_demo-inventory-circuit-break.sh` 실행 후 **Prometheus**에서 msaedu 서비스 트래픽·서킷브레이크·HPA를 확인할 때 쓰는 PromQL 모음이다.

## 전제

| 항목 | 내용 |
|------|------|
| 데모 스크립트 | `./infra/scripts/09_demo-inventory-circuit-break.sh` |
| 트래픽 진입점 | `POST http://localhost:18088/api/orders` (Ingress) |
| Prometheus UI | `http://localhost:13004` (`05_start-lab-access.sh start` 후) |
| 메트릭 소스 | Istio Envoy (`istio_requests_total` 등) — `infra/k8s/09-istio-envoy-podmonitor.yaml` |
| 네임스페이스 | 애플리케이션 `msaedu`, 관측 `observe` |

**흐름:** `ingressgateway` → `order-service` → `inventory-service` (ROUND_ROBIN: `latest` \| `risky`) → `payment-service`

**데모 단계 요약**

| 단계 | 내용 | 기대 |
|------|------|------|
| Phase 1 | 서킷브레이크 유도 (기본 25회) | 502/201 교차, risky 5xx 누적 |
| Phase 2 | 격리 확인 (10회) | 201만 (risky 격리) |
| Phase 3 | HPA 부하 (기본 80회) | latest만 트래픽, replica 증가 |

데모 직후 Prometheus 시간 범위: **Last 15 minutes** 권장.

---

## 0. 라벨·메트릭 확인 (최초 1회)

클러스터마다 라벨 값이 조금 다를 수 있으므로, 먼저 실제 라벨을 확인한다.

```promql
topk(20, count by (destination_service_name, destination_workload, destination_version, response_code) (
  istio_requests_total{destination_service_namespace="msaedu"}
))
```

```promql
topk(20, count by (source_workload, destination_service_name, destination_version, response_code) (
  istio_requests_total{source_workload="order-service", destination_service_namespace="msaedu"}
))
```

`destination_version`에 `latest` / `risky`가 보이면 아래 쿼리를 그대로 사용할 수 있다.

---

## 1. 전체 트래픽 개요 (서비스별 RPS)

### Ingress → order

```promql
sum(rate(istio_requests_total{
  destination_service_namespace="msaedu",
  destination_workload="order-service",
  reporter="destination"
}[1m]))
```

### order → inventory (버전·응답코드별)

```promql
sum by (destination_version, response_code) (
  rate(istio_requests_total{
    source_workload="order-service",
    destination_service_name="inventory-service",
    reporter="source"
  }[1m])
)
```

### inventory → payment

```promql
sum by (source_workload, response_code) (
  rate(istio_requests_total{
    source_workload=~"inventory-service-.*",
    destination_service_name="payment-service",
    reporter="source"
  }[1m])
)
```

---

## 2. 서킷브레이커 (Phase 1·2)

### risky 로 가는 5xx 비율 (CB 유도 구간)

```promql
sum(rate(istio_requests_total{
  destination_service_name="inventory-service",
  destination_version="risky",
  response_code=~"5..",
  reporter="source"
}[1m]))
```

### latest vs risky 요청 비율

라운드로빈 → CB 발동 후에는 `risky`가 0에 가깝고 `latest`만 남는다.

```promql
sum by (destination_version) (
  rate(istio_requests_total{
    source_workload="order-service",
    destination_service_name="inventory-service",
    reporter="source"
  }[1m])
)
```

### Ingress 기준 order 응답 코드 (502 / 201)

```promql
sum by (response_code) (
  rate(istio_requests_total{
    destination_workload="order-service",
    reporter="destination"
  }[1m])
)
```

### order 성공률 (2xx / 전체)

```promql
sum(rate(istio_requests_total{
  destination_workload="order-service",
  response_code=~"2..",
  reporter="destination"
}[5m]))
/
sum(rate(istio_requests_total{
  destination_workload="order-service",
  reporter="destination"
}[5m]))
```

### 데모 구간 누적 요청 수 (Phase 1+2+3, 약 115회)

```promql
sum(increase(istio_requests_total{
  destination_workload="order-service",
  reporter="destination"
}[15m]))
```

---

## 3. Outlier Detection (Envoy 격리)

`10-inventory-circuit-breaking.yaml`의 `outlierDetection`은 Envoy 클러스터 메트릭으로도 확인할 수 있다.

### risky 관련 클러스터 이름 확인

```promql
topk(10, sum by (cluster_name) (
  increase(envoy_cluster_outlier_detection_ejections_total{namespace="msaedu"}[15m])
))
```

### 격리(ejection) 누적 횟수

`cluster_name`에 `risky`가 포함된 이름으로 필터 (위 쿼리 결과에 맞게 수정).

```promql
sum(increase(envoy_cluster_outlier_detection_ejections_total{
  namespace="msaedu",
  cluster_name=~".*risky.*"
}[15m]))
```

### 현재 active 격리 endpoint 수

```promql
sum(envoy_cluster_outlier_detection_ejections_active{
  namespace="msaedu",
  cluster_name=~".*risky.*"
})
```

---

## 4. HPA 스케일아웃 (Phase 3)

### inventory-service-latest Pod 수

```promql
count(kube_pod_info{
  namespace="msaedu",
  pod=~"inventory-service-latest-.*"
})
```

### HPA current / desired replicas

```promql
kube_horizontalpodautoscaler_status_current_replicas{
  namespace="msaedu",
  horizontalpodautoscaler="inventory-service-latest-hpa"
}
```

```promql
kube_horizontalpodautoscaler_status_desired_replicas{
  namespace="msaedu",
  horizontalpodautoscaler="inventory-service-latest-hpa"
}
```

### inventory-latest 컨테이너 CPU 사용량 (합계)

```promql
sum(rate(container_cpu_usage_seconds_total{
  namespace="msaedu",
  pod=~"inventory-service-latest-.*",
  container="inventory-service"
}[1m]))
```

### CPU utilization 근사 (교육용, requests.cpu=20m 기준)

HPA는 `ContainerResource`로 `inventory-service` 컨테이너를 본다. 아래는 Prometheus에서 대략적인 utilization(%) 참고용이다.

```promql
sum(rate(container_cpu_usage_seconds_total{
  namespace="msaedu",
  pod=~"inventory-service-latest-.*",
  container="inventory-service"
}[1m]))
/ 0.02
* 100
```

(`0.02` = Kubernetes `requests.cpu: 20m`)

### Phase 3: latest 로만 몰린 트래픽

```promql
sum(rate(istio_requests_total{
  source_workload="order-service",
  destination_service_name="inventory-service",
  destination_version="latest",
  reporter="source"
}[1m]))
```

---

## 5. 서비스별 요약 (Table / Grafana)

### 서비스·버전·응답코드별 누적 (15분)

```promql
sum by (destination_service_name, destination_version, response_code) (
  increase(istio_requests_total{
    destination_service_namespace="msaedu",
    destination_service_name=~"order-service|inventory-service|payment-service",
    reporter="destination"
  }[15m])
)
```

### 워크로드(Deployment)별 누적

```promql
sum by (destination_workload, response_code) (
  increase(istio_requests_total{
    destination_service_namespace="msaedu",
    reporter="destination"
  }[15m])
)
```

---

## 6. Grafana 패널 예시

| 패널 제목 | 쿼리 섹션 | 해석 |
|-----------|-----------|------|
| Order RPS by response code | [§2 Ingress 응답 코드](#ingress-기준-order-응답-코드-502--201) | 502 → 201 전환 |
| Inventory by version | [§2 latest vs risky](#latest-vs-risky-요청-비율) | risky 0, latest만 |
| Risky 5xx rate | [§2 risky 5xx](#risky-로-가는-5xx-비율-cb-유도-구간) | Phase 1 스파이크 |
| Latest pod count | [§4 Pod 수](#inventory-service-latest-pod-수) | HPA 1→2→3 |
| Outlier ejections | [§3 ejections_total](#격리ejection-누적-횟수) | CB 발동 시점 |

---

## 7. 데모 단계별 추천 쿼리

| 단계 | 확인할 쿼리 |
|------|-------------|
| Phase 1 (25회, 502/201 교차) | risky 5xx rate, order `response_code`별 rate |
| Phase 2 (10회, 전부 201) | latest vs risky 비율, order 성공률 ≈ 1 |
| Phase 3 (80회, HPA) | latest RPS, latest Pod 수, container CPU |

---

## 8. 트러블슈팅

### `istio_requests_total`이 비어 있음

1. Prometheus **Status → Targets**에서 `istio-envoy-stats` job, endpoint **`:15020`** 스크랩 UP 여부 확인  
2. `infra/k8s/09-istio-envoy-podmonitor.yaml` 적용 여부  
3. 트래픽이 **Ingress `:18088`** 경로인지 확인 (Pod 직접 port-forward만 하면 일부 시리즈가 비어 있을 수 있음)

### HPA·CPU 메트릭이 없음

- `metrics-server` 설치 여부 (`02_install-istio.sh`)  
- `kube-state-metrics`는 kube-prometheus-stack 기본 포함

### Kiali Graph와 수치가 다름

- Kiali도 동일 Prometheus의 `istio_requests_total`을 사용한다. 시간 범위·집계 구간(`rate` window)을 맞춘다.

---

## 관련 문서·파일

| 파일 | 설명 |
|------|------|
| `infra/scripts/09_demo-inventory-circuit-break.sh` | 데모 실행 |
| `infra/k8s/10-inventory-circuit-breaking.yaml` | ROUND_ROBIN, outlierDetection |
| `infra/k8s/09-istio-envoy-podmonitor.yaml` | Envoy 메트릭 수집 |
| `infra/helm/helm.md` | Prometheus·Grafana Helm 설정 |
| `infra/lab-access.env` | localhost 포트 (Prometheus 13004) |
