# Helm Values 가이드 (`infra/helm`)

이 디렉터리는 **관측(Observability) 스택**을 `observe` 네임스페이스에 설치할 때 사용하는 **Helm values 파일** 모음이다.  
애플리케이션(`msaedu`)은 `infra/k8s/*.yaml`로 배포하고, Prometheus·Grafana·Loki·Jaeger·Kiali는 여기 Helm 값으로 배포한다.

---

## 목차

1. [전체 구조](#1-전체-구조)
2. [설치 방법](#2-설치-방법)
3. [kube-prometheus-stack.yaml](#3-kube-prometheus-stackyaml)
4. [loki.yaml](#4-lokiyaml)
5. [jaeger.yaml](#5-jaegeryaml)
6. [kiali.yaml](#6-kialiyaml)
7. [런타임 덮어쓰기 (05_start-lab-access)](#7-런타임-덮어쓰기-05_start-lab-access)
8. [Helm 외 연동 매니페스트](#8-helm-외-연동-매니페스트)
9. [트러블슈팅](#9-트러블슈팅)

---

## 1. 전체 구조

```text
observe 네임스페이스 (Istio 사이드카 없음)
├── kube-prometheus-stack  ← kube-prometheus-stack.yaml
│   ├── Prometheus       (메트릭 저장·쿼리)
│   └── Grafana          (대시보드·Loki Explore)
├── loki                 ← loki.yaml
├── jaeger               ← jaeger.yaml
└── kiali-server         ← kiali.yaml

msaedu 네임스페이스 (Istio 사이드카 있음)
├── order / inventory / payment  → OTLP → otel-collector (k8s/07)
└── Envoy 메트릭 → Prometheus    → k8s/09-istio-envoy-podmonitor.yaml

Kiali Traffic Graph
  Prometheus(istio_requests_total) + Jaeger(트레이스) + Istio API(istiod)
```

| 파일 | Helm 차트 | 릴리스 이름 | 주요 역할 |
|------|-----------|-------------|-----------|
| `kube-prometheus-stack.yaml` | [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) | `kube-prometheus-stack` | Prometheus, Grafana, Alertmanager, Operator |
| `loki.yaml` | [grafana/loki](https://github.com/grafana/loki/tree/main/production/helm/loki) | `loki` | 로그 집계·저장 |
| `jaeger.yaml` | [jaegertracing/jaeger](https://github.com/jaegertracing/helm-charts) | `jaeger` | 분산 트레이스 저장·UI |
| `kiali.yaml` | [kiali/kiali-server](https://kiali.io/docs/configuration/kialis.kiali.io/) | `kiali-server` | 서비스 메시 시각화·헬스 |

---

## 2. 설치 방법

`03_install-observability.sh`가 아래 순서로 `helm upgrade --install` 한다.

```bash
./infra/scripts/03_install-observability.sh
```

내부 순서:

1. `kube-prometheus-stack` + `kube-prometheus-stack.yaml`
2. `loki` + `loki.yaml`
3. `jaeger` + `jaeger.yaml`
4. `k8s/08-jaeger-ui-nodeport.yaml` (Jaeger UI NodePort, Helm 외)
5. `kiali-server` + `kiali.yaml`
6. `k8s/07-otel-collector.yaml`, `k8s/09-istio-envoy-podmonitor.yaml` (kubectl apply)

브라우저 접속은 `05_start-lab-access.sh`가 **port-forward**와 **Helm 값 일부 갱신**을 수행한다.

---

## 3. `kube-prometheus-stack.yaml`

### 역할

- **Prometheus**: 메트릭 TSDB, ServiceMonitor/PodMonitor CRD 제공
- **Grafana**: UI, Prometheus·(설정 시) Loki 데이터소스
- **Prometheus Operator**: PodMonitor 등 CRD 기반 스크랩 설정

이 프로젝트에서 Prometheus는 다음을 수집한다.

| 소스 | 설정 위치 |
|------|-----------|
| 클러스터·kube-state 기본 타깃 | 차트 기본값 |
| OpenTelemetry Collector `:8889` | `additionalScrapeConfigs` (본 파일) |
| Istio Envoy (`istio_requests_total` 등) | `infra/k8s/09-istio-envoy-podmonitor.yaml` (PodMonitor) |

### 설정 항목

```yaml
grafana:
  adminPassword: admin
  service:
    type: NodePort
    nodePort: 30002
```

| 항목 | 값 | 설명 |
|------|-----|------|
| `adminPassword` | `admin` | Grafana 로그인 비밀번호(교육용 고정). **운영 환경에서는 Secret·외부 IdP 사용.** |
| `service.type` | `NodePort` | 클러스터 노드 IP로 UI 접속. minikube·교육 환경용. |
| `nodePort` | `30002` | 고정 NodePort. macOS docker minikube에서는 `05`의 localhost:13002 port-forward 권장. |

```yaml
prometheus:
  service:
    enabled: true
    type: NodePort
    nodePort: 30004
    port: 9090
    targetPort: 9090
  prometheusSpec:
    additionalScrapeConfigs:
      - job_name: otel-collector
        static_configs:
          - targets: ["otel-collector.observe.svc.cluster.local:8889"]
```

| 항목 | 설명 |
|------|------|
| `prometheus.service` | Prometheus UI/API를 NodePort로 노출(교육·디버깅). |
| `prometheusSpec.additionalScrapeConfigs` | **중요.** Operator가 관리하는 Prometheus에 **추가 스크랩 job**을 넣는다. |

#### `additionalScrapeConfigs` (OTel 메트릭) — 상세

- **대상**: `otel-collector.observe:8889` — OTel Collector가 앱 OTLP 메트릭을 Prometheus 형식으로 노출하는 포트
- **경로**: `07-otel-collector.yaml`의 `prometheus` exporter
- **용도**: 애플리케이션 커스텀 메트릭·OTel 파이프라인 확인
- **주의**: **Kiali Traffic Graph는 이 job이 아니라** `09-istio-envoy-podmonitor.yaml`의 **Envoy/Istio 메트릭**을 사용한다.

#### PodMonitor와의 관계 — 상세

`09-istio-envoy-podmonitor.yaml`에 다음 라벨이 있어야 Prometheus가 PodMonitor를 선택한다.

```yaml
labels:
  release: kube-prometheus-stack
```

이는 차트 기본값 `prometheus.prometheusSpec.podMonitorSelector`와 맞춘 것이다. 라벨을 바꾸면 **Kiali 그래프가 비어 보일 수 있다.**

PodMonitor는 Envoy 스크랩 포트를 **`:15020`**(pilot-agent 병합 메트릭)으로 relabel 한다. `:15090`만 쓰면 앱 간 `istio_requests_total`이 비어 있는 경우가 있다.

---

## 4. `loki.yaml`

### 역할

중앙 **로그 저장소**. `otel-collector` DaemonSet이 Pod 로그·OTLP 로그를 Loki gateway로 push 한다.

### `deploymentMode: SingleBinary` — 상세 (필수에 가깝음)

```yaml
deploymentMode: SingleBinary
```

| 모드 | 설명 |
|------|------|
| **SimpleScalable** (차트 기본) | read/write/backend 분리, **S3 등 객체 스토리지**·`bucketNames` 설정 필요 |
| **SingleBinary** (본 프로젝트) | 단일 프로세스 + **로컬 filesystem** — minikube·교육용에 적합 |

SimpleScalable을 그대로 쓰면 values에 `loki.storage.bucketNames` 등이 없어 설치가 실패하거나 Pending이 난다.

### `singleBinary` 블록

```yaml
singleBinary:
  replicas: 1
  persistence:
    enabled: true
    size: 10Gi
  resources:
    limits:
      memory: 1Gi
    requests:
      cpu: 100m
      memory: 512Mi
```

| 항목 | 설명 |
|------|------|
| `persistence.enabled` | 로그를 PVC에 유지. Pod 재시작 후에도 로그 보존. |
| `persistence.size` | minikube StorageClass 기준 10Gi. |
| `resources` | Loki는 메모리를 많이 쓸 수 있어 limit 1Gi 권장. |

### `loki` 스토리지·스키마

```yaml
loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: filesystem
        schema: v13
```

| 항목 | 설명 |
|------|------|
| `auth_enabled: false` | 교육용. 멀티테넌트·인증 없이 push/query. |
| `replication_factor: 1` | 단일 복제(로컬 1노드). |
| `storage.type: filesystem` | 디스크 기반 저장(S3 불필요). |
| `schema v13` + `tsdb` | Loki 3.x 계열 권장 스키마. |

### `gateway` — 상세

```yaml
gateway:
  enabled: true
  affinity: {}
```

| 항목 | 설명 |
|------|------|
| `gateway.enabled` | nginx gateway로 Loki API(`/loki/api/v1/push` 등) 노출. OTel·Grafana가 **gateway** 주소로 접근. |
| `affinity: {}` | **중요.** 차트 기본 `podAntiAffinity`(단일 노드 2 Pod 금지)를 끈다. minikube에서 Istio 롤아웃·재배포 시 **gateway Pod Pending** → Kiali `observe` Failure로 보이는 문제를 피한다. |

### SimpleScalable 컴포넌트 비활성화

```yaml
write:
  replicas: 0
read:
  replicas: 0
backend:
  replicas: 0
```

`deploymentMode: SingleBinary`로 바꿀 때 **반드시 0**으로 두어 불필요한 write/read/backend Deployment가 뜨지 않게 한다.

---

## 5. `jaeger.yaml`

### 역할

분산 트레이싱 백엔드(all-in-one). 앱·OTel Collector가 보낸 트레이스를 저장하고 UI로 조회한다.

```yaml
storage:
  type: memory
```

| 항목 | 설명 |
|------|------|
| `storage.type: memory` | 트레이스를 **메모리**에만 저장. Pod 재시작 시 데이터 소실. **교육·데모용.** 운영은 Elasticsearch/Cassandra 등. |

### Helm 외 UI 노출

Jaeger Helm 차트만으로는 교육용 고정 NodePort가 없을 수 있어, 설치 후 다음을 추가 적용한다.

- `infra/k8s/08-jaeger-ui-nodeport.yaml` — UI **NodePort 30003**
- `05_start-lab-access.sh` — localhost **13003** port-forward

Kiali는 `kiali.yaml`의 `external_services.tracing.internal_url: http://jaeger.observe:16686`으로 Query API에 연결한다.

---

## 6. `kiali.yaml`

### 역할

Istio 서비스 메시 **콘솔**: Traffic Graph, Workloads, Istio Config, 분산 트레이스 링크 등.

릴리스 네임스페이스는 `observe`이지만, **제어 플레인·메트릭·트레이스 소스는 다른 네임스페이스**를 가리켜야 한다.

### `auth.strategy: anonymous` — 상세

```yaml
auth:
  strategy: anonymous
```

교육용 **무인증** 접속. 운영 환경에서는 OpenID·token 등으로 변경한다.

### `deployment` — 상세

```yaml
deployment:
  service_type: NodePort
  network_policy:
    enabled: false
```

| 항목 | 설명 |
|------|------|
| `service_type: NodePort` | UI NodePort **30001** (`server.node_port`). |
| `network_policy.enabled: false` | observe↔istio-system·msaedu 간 Kiali API/프록시 통신이 NetworkPolicy에 막히지 않도록(교육 클러스터). |

```yaml
server:
  port: 20001
  node_port: 30001
```

클러스터 내부는 20001, NodePort는 30001. `05`는 **13001 → 20001** port-forward.

### `external_services.istio` — 상세 (Traffic Graph 필수)

```yaml
external_services:
  istio:
    root_namespace: istio-system
    istio_api_enabled: true
    config_map_name: istio
    istiod_deployment_name: istiod
    istiod_pod_monitoring_port: 15014
    ingress_gateway_namespace: istio-system
```

| 항목 | 설명 |
|------|------|
| **`root_namespace`** | **가장 중요.** Istio 제어 플레인이 설치된 네임스페이스. Kiali가 `observe`에 있어도 **반드시 `istio-system`**(istioctl demo 기준). 잘못 넣으면 그래프·config가 비거나 오류. |
| `istio_api_enabled` | Istio API로 VirtualService/DestinationRule 등 조회. |
| `istiod_deployment_name` | istiod Pod/서비스 식별. |
| `ingress_gateway_namespace` | Ingress Gateway 워크로드가 있는 네임스페이스. |

### `external_services.prometheus` — 상세 (Traffic Graph 메트릭)

```yaml
  prometheus:
    url: http://kube-prometheus-stack-prometheus.observe:9090
    cache_duration: 180
```

| 항목 | 설명 |
|------|------|
| `url` | 클러스터 **내부 DNS**. Kiali Pod가 Prometheus에 PromQL 요청. |
| `cache_duration` | 메트릭 캐시(초). 그래프 새로고침 시 지연과 트레이드오프. |

**전제 조건**

1. `09-istio-envoy-podmonitor.yaml`이 적용되어 `istio_requests_total` 등이 수집될 것
2. `msaedu` 등에서 **실제 mesh 트래픽**이 있을 것(Ingress `/api/orders` 등)

### `external_services.grafana`

```yaml
  grafana:
    enabled: true
    auth:
      type: basic
      username: admin
      password: admin
    internal_url: http://kube-prometheus-stack-grafana.observe:80
    external_url: ""
```

| 항목 | 설명 |
|------|------|
| `internal_url` | Kiali → Grafana API(클러스터 내부). |
| `external_url` | Kiali UI에서 “Grafana 열기” 링크용 **브라우저가 접근 가능한 URL**. 빈 문자열이면 링크 비활성. `05`가 `http://localhost:13002` 등으로 **helm upgrade 시 채움**. |

### `external_services.tracing` — 상세

```yaml
  tracing:
    enabled: true
    provider: jaeger
    namespace_selector: false
    internal_url: http://jaeger.observe:16686
    use_grpc: false
    external_url: ""
```

| 항목 | 설명 |
|------|------|
| `provider: jaeger` | Jaeger Query 백엔드 사용. |
| **`namespace_selector: false`** | **중요.** 기본 `true`면 `order-service.msaedu`로 조회. Spring OTLP는 `order-service`만 저장. |
| `internal_url` | Jaeger Query **HTTP** API(16686). |
| **`use_grpc: false`** | **중요.** gRPC(16685) 대신 HTTP JSON API 사용. all-in-one + port-forward 환경에서 gRPC 불일치 오류를 줄인다. |
| `external_url` | 브라우저용 Jaeger UI URL. `05`가 localhost:13003 등으로 설정. |

### `custom_dashboards`

```yaml
  custom_dashboards:
    enabled: true
```

Grafana 대시보드 템플릿 연동(확장용). 기본 실습에서는 Traffic Graph·Jaeger가 중심.

---

## 7. 런타임 덮어쓰기 (`05_start-lab-access`)

`03` 설치만으로는 **NodePort·minikube IP**로 브라우저 접속이 어려운 환경(macOS docker driver 등)을 위해, `05_start-lab-access.sh`가 Helm 값을 **추가로 merge** 한다.

| 대상 | 추가 values | 내용 |
|------|-------------|------|
| `kube-prometheus-stack` | `.lab-access/grafana-lab-values.yaml` (생성) | `grafana.ini.server.root_url` → `http://localhost:13002/` |
| `kiali-server` | `--set-string` | `server.web_fqdn`, `external_services.grafana.external_url`, `external_services.tracing.external_url` |

`lab-access.env` 기본 포트:

| 서비스 | localhost 포트 |
|--------|----------------|
| Kiali | 13001 |
| Grafana | 13002 |
| Jaeger | 13003 |
| Prometheus | 13004 |
| Loki | 13005 |

**port-forward**는 Helm이 아니라 `05`의 kubectl port-forward로 처리한다.

---

## 8. Helm 외 연동 매니페스트

Helm만으로 완결되지 않는 부분은 `infra/k8s`에 있다.

| 파일 | 연관 Helm 차트 | 역할 |
|------|----------------|------|
| `07-otel-collector.yaml` | (독립 DaemonSet) | OTLP 수신 → Jaeger·Prometheus(:8889)·Loki |
| `08-jaeger-ui-nodeport.yaml` | jaeger | Jaeger UI NodePort 30003 |
| `09-istio-envoy-podmonitor.yaml` | kube-prometheus-stack | Envoy 메트릭 → Prometheus → **Kiali Graph** |
| `11-mesh-egress-to-observe.yaml` | (없음) | msaedu 사이드카 → observe plain HTTP(TLS DISABLE) |

**observe 네임스페이스는 Istio injection 없음** (`01-namespaces.yaml`, `02`/`03` 스크립트).  
관측 스택 Pod에 사이드카가 없고, 앱 OTLP는 DestinationRule로 plain HTTP 허용한다.

---

## 9. 트러블슈팅

### Kiali Traffic Graph가 비어 있음

1. `kubectl get podmonitor istio-envoy-stats -n observe` 존재 여부  
2. Prometheus Targets에 `istio-envoy-stats` job·`:15020` 스크랩 확인  
3. Ingress `POST /api/orders` 등으로 **msaedu 트래픽** 발생  
4. Kiali: Namespace `msaedu` + `istio-system`, **Last 5m**, Versioned app graph  

### Grafana/Jaeger 링크가 Kiali에서 깨짐

- `external_url`이 비어 있음 → `./infra/scripts/05_start-lab-access.sh start` 재실행  
- `grafana.ini` `root_url`이 외부 URL과 불일치 → `grafana-lab-values.yaml` 재생성 여부 확인  

### Loki gateway Pending

- `loki.yaml`의 `gateway.affinity: {}` 적용 여부  
- 단일 노드에서 구·신 gateway Pod 동시 스케줄 시 anti-affinity 충돌  

### Overview Applications Failure (otel-collector 100% 등)

- msaedu 앱이 OTLP로 `otel-collector` 호출 시 503 → Kiali health Failure로 표시될 수 있음  
- Traffic Graph·서킷브레이커 실습과는 **별개** (비즈니스 경로는 Ingress `/api/orders`)  
- Jaeger에 trace가 있는데 Kiali **Traces** 만 비면 `tracing.namespace_selector: false` 확인 (`infra/docs/Jaeger-query.md`)  

### Helm values 수정 후 반영

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n observe -f infra/helm/kube-prometheus-stack.yaml

helm upgrade loki grafana/loki -n observe -f infra/helm/loki.yaml

helm upgrade jaeger jaegertracing/jaeger -n observe -f infra/helm/jaeger.yaml

helm upgrade kiali-server kiali/kiali-server -n observe -f infra/helm/kiali.yaml
```

대규모 변경 후에는 해당 Deployment/StatefulSet 롤아웃 상태를 `kubectl get pods -n observe`로 확인한다.

---

## 참고 링크

- [kube-prometheus-stack chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Grafana Loki chart](https://github.com/grafana/loki/tree/main/production/helm/loki)
- [Jaeger Helm charts](https://github.com/jaegertracing/helm-charts)
- [Kiali configuration](https://kiali.io/docs/configuration/kialis.kiali.io/)
