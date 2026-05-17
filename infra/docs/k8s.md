# Kubernetes 매니페스트 가이드 (`infra/k8s`)

이 디렉터리는 **egovframe-msa-edu** 샘플을 Kubernetes·Istio 메시 위에 올리고, 관측 스택과 연동하기 위한 매니페스트 모음이다.

---

## 목차

1. [전체 아키텍처](#1-전체-아키텍처)
2. [적용 순서](#2-적용-순서)
3. [파일별 기능](#3-파일별-기능)
4. [중복·겹침 검토](#4-중복겹침-검토)
5. [서킷브레이커 상세 (inventory)](#5-서킷브레이커-상세-inventory)
6. [관련 문서·스크립트](#6-관련-문서스크립트)

---

## 1. 전체 아키텍처

```text
                    ┌─────────────────────────────────────────┐
                    │  istio-system (istioctl demo)           │
                    │  istio-ingressgateway                   │
                    └──────────────────┬──────────────────────┘
                                       │ 05 Gateway/VS
                                       ▼
┌──────────────────────────────────────────────────────────────────┐
│ namespace: msaedu (istio-injection: enabled)                     │
│                                                                  │
│  order-service ──► inventory-service (Service, 1 host)         │
│       │              ├─ subset latest  (정상 → payment)          │
│       │              └─ subset risky   (503 주입)                │
│       │                    ▲                                       │
│       │                    │ 10-DR: ROUND_ROBIN + outlierDetection│
│       │              inventory-latest ──► payment-service        │
│       │                    │         ▲ 06-VS: timeout/retry      │
│       │                    └── HPA (04)                            │
│       └── OTLP ───────────────────────────────────────────────┐  │
└──────────────────────────────────────────────────────────────│──┘
                                                                │
┌───────────────────────────────────────────────────────────────▼──┐
│ namespace: observe (사이드카 없음)                                │
│  otel-collector ──► Jaeger / Loki / Prometheus(:8889)           │
│  Helm: Prometheus, Grafana, Loki, Jaeger, Kiali                 │
│  09-PodMonitor: Envoy 메트릭 → Prometheus                         │
│  08-jaeger-ui-nodeport (UI NodePort 보조)                         │
└──────────────────────────────────────────────────────────────────┘
         ▲
         │ 11-DR: TLS DISABLE (msaedu → observe)
```

**비즈니스 호출 흐름**

```text
POST /api/orders  →  order-service  →  inventory-service  →  payment-service
                         (02)              (04+10)              (03+06)
```

---

## 2. 적용 순서

| 단계 | 스크립트 / 명령 | k8s 파일 |
|------|-----------------|----------|
| 네임스페이스 | `04_deploy-apps.sh` (앞단) 또는 수동 | `01-namespaces.yaml` |
| 워크로드 | `04_deploy-apps.sh` | `02`, `03`, `04` |
| Istio 라우팅·복원력 | `04_deploy-apps.sh` | `05`, `06`, `10`, `11` |
| 관측(OTel) | `03_install-observability.sh` | `07` |
| Jaeger UI NodePort | `03_install-observability.sh` | `08` |
| Envoy 메트릭 | `03_install-observability.sh` | `09` |

`01`은 `04`에서 함께 적용된다. `07`~`09`는 관측 설치 시점에 적용한다.

---

## 3. 파일별 기능

### `01-namespaces.yaml`

| 리소스 | 이름 | 역할 |
|--------|------|------|
| Namespace | `msaedu` | 앱·Istio Gateway/VS/DR. `istio-injection: enabled` |
| Namespace | `observe` | Prometheus, Grafana, Loki, Jaeger, Kiali, OTel. **사이드카 없음** |

---

### `02-order-service.yaml`

| 리소스 | 역할 |
|--------|------|
| Deployment `order-service` | Ingress 진입 후 **inventory만** 호출 (`INVENTORY_BASE_URL`) |
| Service `order-service:8080` | 클러스터 내부 DNS |

**주요 설정**

- `version: v1` Pod 라벨 (Kiali 버전 그래프용, inventory subset 과 무관)
- OTLP → `otel-collector.observe:4318`
- Actuator probe + `rewriteAppHTTPProbers`

**서킷브레이커:** 이 파일에는 없음. order → inventory 정책은 `10`에서 정의.

---

### `03-payment-service.yaml`

| 리소스 | 역할 |
|--------|------|
| Deployment `payment-service` | **inventory-service**가 `POST /api/payments` 호출 |
| Service `payment-service:8081` | |

**주요 설정**

- `simulate-delay` API (지연 실습, Istio timeout 과 비교)
- OTLP 환경변수 (02·04와 동일 패턴)

**Istio:** `06-istio-resilience.yaml` 이 **payment 호스트**에 timeout/retry 적용.

---

### `04-inventory-service.yaml`

| 리소스 | 역할 |
|--------|------|
| Deployment `inventory-service-latest` | `INVENTORY_FAULT_MODE=none`, payment 연쇄 호출 |
| Deployment `inventory-service-risky` | `INVENTORY_FAULT_MODE=always-5xx` → HTTP **503** |
| Service `inventory-service` | selector `app: inventory-service` → **두 Deployment 모두** 엔드포인트 |
| HPA `inventory-service-latest-hpa` | latest만 스케일 (1~5, CPU 50%, **ContainerResource**) |

**주요 설정**

- 단일 Service + 두 버전 Pod → Istio `10`의 **subset**·**ROUND_ROBIN** 과 짝
- latest: `requests.cpu: 20m` (HPA 데모용), proxy CPU annotation
- risky: fault 주입만 다름, 동일 이미지

**서킷브레이커 로직:** 앱 503 주입 + `10` outlierDetection. HPA는 CB **이후** latest 부하 증가용.

---

### `05-istio-ingress-and-routing.yaml`

| 리소스 | 역할 |
|--------|------|
| Gateway `msaedu-gateway` | `istio: ingressgateway`, HTTP :80, host `*` |
| VirtualService `order-service-vs` | `/api/orders` → `order-service:8080` |

**범위:** 외부 → order **만**. inventory·payment 라우팅은 없음.

---

### `06-istio-resilience.yaml`

| 리소스 | 역할 |
|--------|------|
| VirtualService `payment-service-policy` | host `payment-service` |

```yaml
timeout: 2s
retries:
  attempts: 2
  perTryTimeout: 1s
  retryOn: gateway-error, connect-failure, refused-stream, 5xx
```

**범위:** **inventory → payment** 구간의 지연·일시 오류 대응.  
**서킷브레이커(아웃라이어 격리)와는 별개** — host·목적이 다름 (`10` 참고).

---

### `07-otel-collector.yaml`

| 리소스 | 역할 |
|--------|------|
| ServiceAccount, ClusterRole(Binding) | `k8sattributes` (Pod/RS/Deployment 조회) |
| ConfigMap | OTLP 수신 → Jaeger / Loki / Prometheus exporter |
| DaemonSet `otel-collector` | 노드당 1개, `/var/log/pods` filelog |
| Service | `:4317` gRPC, `:4318` HTTP, `:8889` Prometheus scrape |

**중요:** OTLP receiver `0.0.0.0:4318` (Collector 0.108+ localhost 기본값 이슈 방지).

---

### `08-jaeger-ui-nodeport.yaml`

| 리소스 | 역할 |
|--------|------|
| Service `jaeger-ui-nodeport` | Jaeger Query UI **NodePort 30003** (Helm Service 보완) |

Helm Jaeger와 **중복 Service 가 아님** — UI만 고정 NodePort로 노출.

---

### `09-istio-envoy-podmonitor.yaml`

| 리소스 | 역할 |
|--------|------|
| PodMonitor `istio-envoy-stats` | `msaedu`, `istio-system` 의 Envoy 메트릭 |

**스크랩:** Pod IP **`:15020`** (병합 메트릭). Kiali Traffic Graph용 `istio_requests_total`.

---

### `10-inventory-circuit-breaking.yaml`

| 리소스 | 역할 |
|--------|------|
| DestinationRule `inventory-service-dr` | host `inventory-service` — **서킷브레이커·LB·subset 핵심** |

→ [§5 서킷브레이커 상세](#5-서킷브레이커-상세-inventory)

---

### `11-mesh-egress-to-observe.yaml`

| 리소스 | host | 역할 |
|--------|------|------|
| DR `otel-collector-egress` | `otel-collector.observe.svc.cluster.local` | OTLP plain HTTP |
| DR `prometheus-egress` | `kube-prometheus-stack-prometheus.observe...` | (직접 호출 거의 없음, Kiali/메시 헬스용 여유) |
| DR `jaeger-egress` | `jaeger.observe.svc.cluster.local` | 앱은 OTel 경유, DR은 mesh 호출 시 TLS 해제 |
| DR `loki-gateway-egress` | `loki-gateway.observe...` | |

각 DR은 **서로 다른 host** — 동일 host 에 DR 이 두 개 있지 않음.

---

## 4. 중복·겹침 검토

### 4.1 결론 요약

| 구분 | 결과 |
|------|------|
| **동일 host 에 충돌하는 Istio 규칙** | 없음 (`inventory-service` DR 은 `10` 하나) |
| **서킷브레이커 이중 정의** | 없음 (`10` outlierDetection 만 해당) |
| **의도적 반복(보일러플레이트)** | OTLP env·probe·sidecar annotation 이 02/03/04 에 반복 |
| **역할이 겹쳐 보이는 조합** | `06` retry vs `10` outlier — **다른 hop** (payment vs inventory) |
| **불필요할 수 있는 DR** | `11` 의 jaeger/prometheus — 현재 앱은 **otel-collector 만** 직접 호출. 충돌은 없고 Kiali 헬스·확장 여지 |

### 4.2 보일러플레이트 중복 (충돌 아님)

다음은 **네 Deployment 에 동일 패턴**이 반복된다. 기능 중복이 아니라 **파일별 독립 배포**를 위한 복사다.

| 항목 | 위치 | 비고 |
|------|------|------|
| `OTEL_EXPORTER_OTLP_*` | 02, 03, 04(latest/risky) | 통합하려면 Helm/Kustomize 권장 |
| Actuator probe 3종 | 02, 03, 04 | 포트만 8080/8081/8082 차이 |
| `sidecar.istio.io/rewriteAppHTTPProbers` | 모든 앱 Pod | Istio probe 리다이렉트 |

### 4.3 Istio 정책 — 겹치지 않는 이유

| 파일 | 리소스 | 대상 host / 경로 |
|------|--------|------------------|
| `05` | Gateway + VS | Ingress → **order-service** |
| `06` | VS | **payment-service** (mesh 내부) |
| `10` | DR | **inventory-service** (subset + outlier) |
| `11` | DR ×4 | **observe** 외부 서비스 egress TLS |

`04_deploy-apps.sh` 는 **삭제된 구조** 잔재만 정리한다.

```bash
kubectl delete destinationrule order-service-dr payment-service-dr -n msaedu ...
```

현재 저장소에는 `order-service-dr` / `payment-service-dr` YAML 이 **없음** — 과거 실습과의 충돌 방지용.

### 4.4 “비슷해 보이는” 설정 구분

| 설정 | 파일 | 실제 동작 |
|------|------|-----------|
| **Outlier detection (서킷브레이크)** | `10` | inventory **endpoint** 5xx 연속 시 **격리** |
| **Connection pool limit** | `10` `connectionPool` | 동시 연결·pending 상한 (혼잡 제어, CB 와 별개) |
| **HTTP retry** | `06` | payment 호출 **재시도** (inventory CB 와 무관) |
| **앱 503 주입** | `04` risky env | risky Pod 가 **의도적 5xx** → outlier 카운트 유발 |
| **HPA** | `04` | latest Pod 수 평준화 (Kubernetes, Istio 아님) |

### 4.5 개선 여지 (필수 수정 아님)

1. **`03-payment-service.yaml` 주석** — “주문 서비스에서 호출” → 실제는 **inventory** 가 호출.
2. **`11` jaeger/prometheus DR** — 앱 직접 호출 없으면 문서·헬스 목적; 제거해도 OTLP 경로는 `otel-collector-egress` 만으로 동작 가능.
3. **OTEL env** — Kustomize `configMapRef` 등으로 한곳 관리 가능.

---

## 5. 서킷브레이커 상세 (inventory)

### 5.1 실습에서 말하는 “서킷브레이크”의 구성

이 프로젝트의 서킷브레이크는 **Spring Cloud Circuit Breaker가 아니라 Istio Envoy Outlier Detection** 이다.

```text
┌─────────────┐     ┌──────────────────────────────────────────────┐
│ order-svc   │     │  inventory-service (K8s Service 1개)         │
│  RestTemplate────►│  DR: inventory-service-dr (10)               │
└─────────────┘     │    loadBalancer: ROUND_ROBIN                   │
                    │    subsets: latest | risky                     │
                    │    outlierDetection → risky endpoint 격리      │
                    └──────────┬─────────────────┬───────────────────┘
                               │                 │
                    ┌──────────▼──┐   ┌──────────▼──┐
                    │ latest Pod  │   │ risky Pod   │
                    │ fault: none │   │ always-5xx  │
                    │ → payment   │   │ HTTP 503    │
                    └─────────────┘   └─────────────┘
```

관련 파일:

| 계층 | 파일 | 역할 |
|------|------|------|
| 장애 주입 | `04` risky Deployment | `INVENTORY_FAULT_MODE=always-5xx` |
| 트래픽 분산 | `04` Service + `10` ROUND_ROBIN | 요청을 latest/risky 에 번갈아 분배 |
| 격리 정책 | `10` outlierDetection | risky 가 5xx 를 내면 endpoint ejection |
| 부하 증가 | `04` HPA | latest 로만 몰린 뒤 CPU↑ → replica 증가 |
| 관측 | `09` PodMonitor | Kiali / Prometheus 메트릭 |
| 데모 | `09_demo-inventory-circuit-break.sh` | Ingress 로 부하 |

### 5.2 `10-inventory-circuit-breaking.yaml` 전체 해설

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: inventory-service-dr
  namespace: msaedu
spec:
  host: inventory-service          # K8s Service 이름과 일치 (짧은 이름)
```

#### Subsets (Kiali Versioned graph)

```yaml
  subsets:
    - name: latest
      labels:
        version: latest
    - name: risky
      labels:
        version: risky
```

| subset | Pod 라벨 (`04`) | 동작 |
|--------|-----------------|------|
| `latest` | `version: latest` | 정상 예약 + payment 호출 |
| `risky` | `version: risky` | 항상 503 |

VirtualService 에 subset 을 명시하지 않아도, DR subset 은 **outlier detection 단위**·Kiali **버전 노드 분리**에 사용된다. 라우팅은 단일 host `inventory-service` 로 가고 Envoy 가 endpoint 단위로 LB·격리한다.

#### Load balancer — ROUND_ROBIN

```yaml
  trafficPolicy:
    loadBalancer:
      simple: ROUND_ROBIN
```

| 항목 | 설명 |
|------|------|
| 효과 | healthy endpoint 간 **순환** 분배 |
| 데모 | 요청 2번마다 대략 latest / risky 교차 → risky 5xx 누적 속도 예측 가능 |
| CB 전 | 502/201 이 섞여 보임 (order 가 upstream 5xx 를 502 로 반환) |
| CB 후 | risky endpoint ejection → **latest 100%** |

#### Connection pool (서킷브레이크 보조, 별도 메커니즘)

```yaml
    connectionPool:
      tcp:
        maxConnections: 100
      http:
        http1MaxPendingRequests: 50
        maxRequestsPerConnection: 10
```

| 필드 | 의미 |
|------|------|
| `maxConnections` | upstream TCP 연결 상한 |
| `http1MaxPendingRequests` | pending HTTP1 요청 큐 상한 (초과 시 503/reset 가능 — **outlier 와 다른 트리거**) |
| `maxRequestsPerConnection` | 연결당 요청 수 제한 |

교육 데모의 “회로 차단” 체감은 주로 **outlierDetection** 에서 온다.

#### Outlier detection — 핵심

```yaml
    outlierDetection:
      consecutive5xxErrors: 10
      interval: 10s
      baseEjectionTime: 50s
      maxEjectionPercent: 100
      minHealthPercent: 0
```

| 필드 | 값 | 상세 |
|------|-----|------|
| **`consecutive5xxErrors`** | `10` | 한 **endpoint**(Pod IP)에 대해 **연속** 5xx 가 10번이면 ejection. ROUND_ROBIN 이면 “risky 로 간 요청”에서만 risky 카운트 증가 → 대략 **전체 20요청 중 risky 10회** 후 격리. |
| **`interval`** | `10s` | outlier 검사·카운터 갱신 주기 |
| **`baseEjectionTime`** | `50s` | 격리 **최소** 유지 시간. 이 동안 해당 endpoint 로 트래픽 안 감 |
| **`maxEjectionPercent`** | `100` | host 의 최대 100% endpoint 를 동시에 격리 가능 → risky 1개만 있으면 **전부 격리 가능** |
| **`minHealthPercent`** | `0` | healthy 로 요구되는 최소 비율 0% — risky 만 있어도 정책 적용(교육용 관대 설정) |

**Envoy 동작 요약**

1. order 가 `inventory-service` 호출
2. ROUND_ROBIN → latest 또는 risky Pod
3. risky 는 앱이 **503** 반환 → consecutive 5xx 카운트 증가
4. 10회 도달 → risky **ejection** (약 50초)
5. 이후 트래픽은 **latest endpoint 만** 사용 → order 응답 **201** 안정
6. latest CPU 상승 → `04` HPA 가 replica 증가 (`09_demo` Phase 3)

#### 격리 확인 방법

```bash
# 데모
./infra/scripts/09_demo-inventory-circuit-break.sh

# order Pod 의 Envoy cluster outlier 메트릭
kubectl exec -n msaedu deploy/order-service -c istio-proxy -- \
  pilot-agent request GET 'stats?filter=outlier' 2>/dev/null | head -30

# Prometheus (infra/Prometheus-query.md)
# envoy_cluster_outlier_detection_ejections_total{cluster_name=~".*risky.*"}
```

### 5.3 `06` 과의 관계 (payment)

서킷브레이크 데모 **직후** latest 가 `payment-service` 를 호출할 때:

- `06` 의 **2s timeout**, **2회 retry** 가 적용됨
- payment 는 기본적으로 빠르게 200 응답 → CB 데모 Phase 1~2 와 **간섭 거의 없음**
- `simulate-delay?millis=2500` 호출 시 timeout/retry 체험은 **별도 실습**

### 5.4 order / ingress 쪽에는 CB 없음

- `05` 는 order 로만 라우팅, **timeout·outlier 없음**
- order 가 inventory 5xx 를 받으면 **502 BAD_GATEWAY** (애플리케이션 코드) — mesh 가 order endpoint 를 eject 하지는 않음

### 5.5 타임라인 예시 (Phase 1, 25회)

| 구간 | 현상 | 이유 |
|------|------|------|
| 요청 1~20 | 201 / 502 혼재 | ROUND_ROBIN + risky 503 |
| risky 5xx 10회 도달 | outlier ejection | `consecutive5xxErrors: 10` |
| 이후 ~50s | 201 만 | latest 100% |
| Phase 3 부하 | HPA replica ↑ | latest CPU·ContainerResource HPA |

---

## 6. 관련 문서·스크립트

| 문서 / 스크립트 | 내용 |
|-----------------|------|
| `infra/scripts/04_deploy-apps.sh` | 01~06, 10, 11 적용 |
| `infra/scripts/03_install-observability.sh` | 07, 08, 09 적용 |
| `infra/scripts/09_demo-inventory-circuit-break.sh` | CB + HPA 데모 |
| `infra/Prometheus-query.md` | CB·HPA PromQL |
| `infra/Jaeger-query.md` | 분산 트레이스 조회 |
| `infra/helm/helm.md` | 관측 Helm values |

---

## 부록: 리소스 빠른 참조

| 파일 | Kind (요약) |
|------|-------------|
| 01 | Namespace ×2 |
| 02 | Deployment, Service |
| 03 | Deployment, Service |
| 04 | Deployment ×2, Service, HPA |
| 05 | Gateway, VirtualService |
| 06 | VirtualService |
| 07 | SA, ClusterRole, Binding, ConfigMap, DaemonSet, Service |
| 08 | Service (NodePort) |
| 09 | PodMonitor |
| 10 | DestinationRule |
| 11 | DestinationRule ×4 |
