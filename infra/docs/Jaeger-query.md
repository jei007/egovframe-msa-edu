# Jaeger / Kiali 트레이스 가이드

**Kiali Traces 탭**에서 분산 트레이스를 확인하는 교육용 설정·데모·검색 조건 정리이다.

## 빠른 시작 (Kiali 트레이스 데모)

```bash
./infra/scripts/03_install-observability.sh
./infra/scripts/04_deploy-apps.sh
./infra/scripts/05_start-lab-access.sh start
./infra/scripts/10_demo-kiali-traces.sh
```

| 케이스 | 스크립트 / 조건 | Kiali에서 볼 것 |
|--------|-----------------|-----------------|
| **A 정상 3단 스팬** | `10_demo-kiali-traces.sh` | order → inventory → payment |
| **B inventory 503** | `09_demo` Phase 1 직후 | payment 스팬 없음, 503 |
| 파이프라인 점검 | `06_verify-observability.sh` [8/8] | OTLP 200, Jaeger services |

---

## 전제

| 항목 | 내용 |
|------|------|
| 트레이스 데모 | `./infra/scripts/10_demo-kiali-traces.sh` |
| 서킷브레이커 데모 | `./infra/scripts/09_demo-inventory-circuit-break.sh` |
| 트래픽 진입점 | `POST http://localhost:18088/api/orders` (Istio Ingress) |
| Jaeger UI | `http://localhost:13003` (`05_start-lab-access.sh start` 후) |
| Kiali → Jaeger | `http://localhost:13001/kiali/` → Workload/Graph에서 **View in Traces** |
| 트레이스 저장 | Jaeger all-in-one, **memory** (Pod 재시작 시 소실) |
| 샘플링 | `management.tracing.sampling.probability: 1.0` (100%) |

**호출 흐름 (애플리케이션 스팬)**

```text
POST /api/orders          [order-service]
  └─ POST /api/inventories/reserve   [inventory-service — latest | risky]
       └─ POST /api/payments         [payment-service]  ← latest 정상 경로만
```

| Deployment | `spring.application.name` (Jaeger Service) | 비고 |
|------------|---------------------------------------------|------|
| `order-service` | `order-service` | 진입 스팬 |
| `inventory-service-latest` | `inventory-service` | 정상 + payment 연쇄 |
| `inventory-service-risky` | `inventory-service` | `always-5xx` → 503, payment 없음 |
| `payment-service` | `payment-service` | inventory(latest)에서만 호출 |

`latest` / `risky`는 Jaeger **Service** 이름이 같고(`inventory-service`), **Pod 이름**·응답 코드·하위 스팬 유무로 구분한다.

---

## 1. 트레이스 파이프라인 (설정 요약)

애플리케이션 OTLP → Collector → Jaeger 로 이어지는 구성이다.

```text
[msaedu Pod]
  Spring Boot Micrometer Tracing
  OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
    http://otel-collector.observe:4318/v1/traces
        │
        ▼
[observe] otel-collector (DaemonSet)
  receivers: otlp (grpc 4317, http 4318)
  processors: k8sattributes, batch
  exporters: otlp/jaeger → jaeger.observe:4317
        │
        ▼
[observe] jaeger (all-in-one, storage.type: memory)
  Query / UI :16686
```

### 1.1 애플리케이션 (Spring Boot)

각 서비스 `application.yml` 공통:

| 설정 | 값 | 설명 |
|------|-----|------|
| `spring.application.name` | `order-service` 등 | Jaeger **Service** 드롭다운 이름 |
| `management.tracing.sampling.probability` | `1.0` | 데모용 전량 샘플링 |
| `management.otlp.tracing.endpoint` | `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | OTLP HTTP |
| `management.observations.key-values.service` | 앱 이름 | 관측 태그 보강 |

Kubernetes Deployment 환경변수 (`02-order-service.yaml`, `04-inventory-service.yaml`, `03-payment-service.yaml`):

```yaml
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: http://otel-collector.observe:4318/v1/traces
```

`RestTemplate` 호출은 Micrometer가 **클라이언트 스팬**을 만들고 W3C `traceparent`로 연쇄 전파한다.

### 1.2 OpenTelemetry Collector

파일: `infra/k8s/07-otel-collector.yaml`

| 구성 | 내용 |
|------|------|
| OTLP 수신 | `:4317`(gRPC), `:4318`(HTTP) |
| `k8sattributes` | Pod/Namespace 메타데이터를 스팬에 부착 (`k8s.pod.name` 등) |
| `batch` | 5s 배치 전송 |
| Jaeger exporter | `jaeger.observe:4317`, `tls.insecure: true` |

### 1.3 Jaeger Helm

파일: `infra/helm/jaeger.yaml`

```yaml
storage:
  type: memory
```

교육용. 장시간·대량 트레이스는 메모리 한도에 걸릴 수 있다.

### 1.4 Istio → observe (OTLP 503 방지)

파일: `infra/k8s/11-mesh-egress-to-observe.yaml`

`msaedu` 사이드카가 `otel-collector.observe` 등으로 나갈 때 **TLS DISABLE**.  
미적용 시 OTLP 전송 실패 → Jaeger에 스팬이 안 쌓일 수 있다.

### 1.5 UI 접속 (lab-access)

| 경로 | 포트 | 설정 위치 |
|------|------|-----------|
| 브라우저 Jaeger UI | `localhost:13003` → Pod `16686` | `infra/lab-access.env` `LAB_PORT_JAEGER` |
| NodePort (선택) | 호스트 `30003` | `infra/k8s/08-jaeger-ui-nodeport.yaml` |
| Kiali 외부 Jaeger 링크 | `13003` | `05_start-lab-access.sh` → `external_services.tracing.external_url` |

Kiali tracing (`infra/helm/kiali.yaml`):

```yaml
external_services:
  tracing:
    provider: jaeger
    # Spring 은 Jaeger service 이름을 order-service 로만 보냄. 기본 true 면 Kiali 가 order-service.msaedu 로 조회해 Traces 가 비어 보임.
    namespace_selector: false
    internal_url: http://jaeger.observe:16686
    use_grpc: false
```

---

## 2. Jaeger UI 기본 설정 (Search)

데모 직후 **Search** 탭에서 아래를 맞춘다.

| 필드 | 권장 값 |
|------|---------|
| **Service** | `order-service` (진입점 기준) 또는 `inventory-service` |
| **Operation** | 아래 [§3](#3-서비스별-operation-이름) 참고 (없으면 All) |
| **Tags** | 단계별 [§5](#5-단계별-검색-설정-tags) |
| **Lookback** | `Last 15 Minutes` (또는 Custom → 데모 종료 시각 포함) |
| **Limit** | `20` ~ `100` (Phase 3까지면 100 권장) |
| **Min Duration** | (비움) HPA 구간 긴 스팬만 볼 때 `> 50ms` 등 실험 |
| **Max Duration** | (비움) |

**Trace Timeline**에서 확인할 것:

- 스팬 개수·깊이 (정상: order → inventory → payment **3단**)
- `inventory-service` 스팬의 `http.status_code`
- `error` 태그 유무
- `k8s.pod.name` (`inventory-service-latest-*` vs `inventory-service-risky-*`)

---

## 3. 서비스별 Operation 이름

Spring Boot 3 + Micrometer 관측 기준 **대표 Operation** (UI 표기는 버전에 따라 소문자/대문자 차이 있을 수 있음).

| Service | Operation (예) | HTTP |
|---------|----------------|------|
| `order-service` | `http post /api/orders` 또는 `POST /api/orders` | 진입 |
| `inventory-service` | `http post /api/inventories/reserve` | order → inventory |
| `payment-service` | `http post /api/payments` | inventory(latest) → payment |

Operation 목록이 비어 있으면 **Service만 선택**하고 Lookback을 넓힌 뒤, 임의 Trace를 열어 실제 Operation 문자열을 확인한다.

---

## 4. 대표 Trace 구조

### 4.1 정상 경로 (latest, HTTP 201)

```text
order-service          [server] POST /api/orders           http.status_code=201
  └─ inventory-service [client] .../reserve
       └─ inventory-service [server] POST .../reserve   http.status_code=200
            └─ payment-service [client] ...
                 └─ payment-service [server] POST /api/payments  http.status_code=200
```

### 4.2 장애 경로 (risky, HTTP 503 → order 502)

```text
order-service          [server] POST /api/orders           http.status_code=201 또는 502
  └─ inventory-service [client/server] POST .../reserve     http.status_code=503, error=true
       (payment-service 스팬 없음)
```

### 4.3 서킷브레이크 이후 (risky 격리, latest만)

- `inventory-service` 스팬의 `k8s.pod.name`이 `inventory-service-latest-*`만 반복
- 하위에 `payment-service` 스팬 존재
- Phase 3 HPA 후에는 **동일 Service**에 Pod 이름만 `latest` 레플리카 여러 개로 분산

---

## 5. 단계별 검색 설정 (Tags)

### Phase 1 — 서킷브레이크 유도 (502/201 교차)

| 목적 | Service | Tags (Jaeger UI) |
|------|---------|------------------|
| inventory 503만 | `inventory-service` | `http.status_code=503` |
| order 쪽 실패 | `order-service` | `http.status_code=502` |
| 에러 스팬만 | `inventory-service` | `error=true` |

여러 Trace를 열어 **payment 스팬이 있는 것 / 없는 것**을 비교하면 latest vs risky 구분에 유리하다.

### Phase 2 — 격리 확인 (201만)

| 목적 | Service | Tags |
|------|---------|------|
| 성공 주문 | `order-service` | `http.status_code=201` |
| inventory 정상 | `inventory-service` | `http.status_code=200` |
| payment 포함 | `payment-service` | `http.status_code=200` |

기대: Phase 2 구간 Trace는 **503/502 없음**, inventory Pod가 `inventory-service-latest-*`만 보임.

### Phase 3 — HPA 부하

| 목적 | 설정 |
|------|------|
| 트래픽량 | Service `order-service`, Limit `100`, Lookback 15m |
| Pod 분산 | Trace 상세 → `inventory-service` 스팬 → Tag `k8s.pod.name` 값이 여러 `inventory-service-latest-*`로 나뉘는지 확인 |

---

## 6. 유용한 Tags (스팬 상세)

Jaeger Trace 화면에서 스팬을 클릭해 **Tags** 를 본다.

| Tag | 설명 |
|-----|------|
| `http.status_code` | `200`, `201`, `502`, `503` 등 |
| `http.route` | `/api/orders`, `/api/inventories/reserve`, `/api/payments` |
| `http.url` | 전체 URL (클라이언트 스팬) |
| `error` | `true`면 실패 스팬 |
| `exception.message` | RestTemplate 5xx 등 |
| `k8s.namespace.name` | `msaedu` |
| `k8s.pod.name` | `inventory-service-risky-...` / `inventory-service-latest-...` |
| `service` | `order-service` 등 (`management.observations.key-values`) |

로그 상관:

```text
[%X{traceId},%X{spanId}]
```

애플리케이션 로그의 `traceId`로 Jaeger에서 **Trace ID** 검색(지원 UI 버전) 또는 Kiali Traces 탭 연동.

---

## 7. Jaeger Query API (선택)

UI와 동일 백엔드(`16686`)에 HTTP API가 있다. port-forward 후 `localhost:13003` 기준 예시.

### 서비스 목록

```bash
curl -s "http://localhost:13003/api/services" | jq .
```

기대: `order-service`, `inventory-service`, `payment-service` 포함.

### 최근 트레이스 (order-service)

```bash
curl -sG "http://localhost:13003/api/traces" \
  --data-urlencode "service=order-service" \
  --data-urlencode "limit=20" \
  --data-urlencode "lookback=15m" | jq '.data | length'
```

### 태그로 필터 (inventory 503)

```bash
curl -sG "http://localhost:13003/api/traces" \
  --data-urlencode "service=inventory-service" \
  --data-urlencode 'tags={"http.status_code":"503"}' \
  --data-urlencode "limit=10" \
  --data-urlencode "lookback=15m" | jq '.data[0].traceID'
```

### Trace ID 상세

```bash
TRACE_ID="<위에서 받은 traceID>"
curl -s "http://localhost:13003/api/traces/${TRACE_ID}" | jq '.data[0].spans | length'
```

---

## 8. Kiali에서 트레이스 보기

1. `http://localhost:13001/kiali/`
2. **Graph**: Namespace `msaedu`, **Versioned app graph**, **Response Code**, Last 5m
3. `order-service` → `inventory-service` 엣지 클릭 → **Traffic**, **Traces**
4. **View in Traces** / Jaeger 링크 → `external_url`이 `05`로 설정된 `http://localhost:13003`

Kiali는 `internal_url: http://jaeger.observe:16686` 로 Query API를 호출한다. 브라우저 직접 접속은 lab-access port-forward를 쓴다.

---

## 9. 데모 단계별 확인 체크리스트

| 단계 | Jaeger에서 볼 것 |
|------|------------------|
| Phase 1 | `inventory-service` + `http.status_code=503` Trace 존재; payment 스팬 없는 Trace 혼재 |
| Phase 2 | `order-service` + `http.status_code=201`; inventory 200 + payment 200 연쇄 |
| Phase 3 | `k8s.pod.name`에 `inventory-service-latest` Pod 여러 개; payment 스팬 지속 |

---

## 10. 트러블슈팅

### 앱 로그: `Failed to export spans ... HTTP 503` (가장 흔함)

**증상:** `order-service` 등 로그에 `HttpExporter ... 503 Service Unavailable`, Jaeger Service 목록 비어 있음.

**원인 (Collector 0.108+):** OTLP receiver 기본 바인딩이 `localhost:4318` 이라 **Pod IP·ClusterIP** 로는 `Connection refused` → Istio Envoy가 **503** 으로 응답.

**확인:**

```bash
kubectl logs -n observe -l app=otel-collector | grep 'Starting HTTP server'
# 잘못된 예: endpoint": "localhost:4318"
# 올바른 예: endpoint": "0.0.0.0:4318"
```

**해결:** `infra/k8s/07-otel-collector.yaml` 에 `0.0.0.0:4317` / `0.0.0.0:4318` 명시 후 재배포:

```bash
kubectl apply -f infra/k8s/07-otel-collector.yaml
kubectl rollout restart ds/otel-collector -n observe
```

**연결 테스트 (msaedu Pod):**

```bash
kubectl exec -n msaedu deploy/order-service -c order-service -- \
  curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  http://otel-collector.observe:4318/v1/traces \
  -H 'Content-Type: application/json' -d '{}'
# 기대: 200
```

`11-mesh-egress-to-observe.yaml`(TLS DISABLE)은 별도 이슈. 503 이 **connection refused** 이면 위 바인딩 문제를 먼저 본다.

### Jaeger Service 목록이 비어 있음

1. 위 OTLP 503 / localhost 바인딩 해결
2. `kubectl get pods -n observe -l app=otel-collector`
3. `kubectl get pods -n msaedu` — 앱 Running
4. `11-mesh-egress-to-observe.yaml` 적용 여부
5. Ingress `18088`으로 데모 트래픽 발생 여부
6. 앱 로그에 `traceId` 출력되는지 확인

### `inventory-service`만 있고 `payment-service`가 없음

- **risky** 경로(503)이거나 서킷브레이크 직전 실패 Trace일 수 있음 → `http.status_code`·`k8s.pod.name` 확인

### Trace는 있는데 Kiali Traces 탭이 비어 있음

- **원인 1 — 서비스명:** Kiali 기본값 `tracing.namespace_selector: true` → `order-service.msaedu` 로 조회. Spring OTLP 는 `order-service` 만 저장.
- **원인 2 — 클러스터 태그(흔함):** Kiali 는 Jaeger 조회 시 `tags.istio.cluster_id=Kubernetes` 를 **항상** 붙인다. 스팬에 해당 태그가 없으면 API·UI 모두 빈 배열.
- **해결 (서비스명):** `infra/helm/kiali.yaml` 에 `namespace_selector: false` 후 Kiali 재설치:
  ```bash
  helm upgrade kiali-server kiali/kiali-server -n observe -f infra/helm/kiali.yaml --reuse-values
  ./infra/scripts/05_start-lab-access.sh start   # external_url·web_fqdn 재적용
  ```
- **해결 (클러스터 태그):** `infra/k8s/07-otel-collector.yaml` 의 `attributes/kiali` 가 스팬에 `istio.cluster_id: Kubernetes` 를 붙인다. 적용 후 Collector 재시작·**새 트래픽** 필요:
  ```bash
  kubectl apply -f infra/k8s/07-otel-collector.yaml
  kubectl rollout restart ds/otel-collector -n observe
  ./infra/scripts/10_demo-kiali-traces.sh
  ```
- 클러스터에서 확인: `curl -s "http://kiali.observe:20001/kiali/api/namespaces/msaedu/apps/order-service/traces?limit=1"` → `data` 배열에 항목이 있어야 함.
- 그 외: `internal_url`·`use_grpc: false` 확인, `./infra/scripts/05_start-lab-access.sh start` 재실행.

### Overview 에서 otel-collector 100% 오류

- **Traces 탭과 무관**할 수 있음. Jaeger에 trace가 있고 위 `namespace_selector` 가 맞으면 Workload → **Traces** 에서 확인.
- 과거 OTLP 503(수집기 `localhost` 바인딩) 시 메시 메트릭이 실패해 표시되기도 함 → `07-otel-collector.yaml` 의 `0.0.0.0:4318` 적용 여부 확인.

### 데모 전에 Jaeger를 재시작함

- `storage.type: memory` 이므로 **이전 Trace는 사라짐** → 데모 후 다시 검색

### Istio ingress 스팬이 안 보임

- 본 프로젝트는 **애플리케이션 OTLP** 위주. Envoy 스팬은 Jaeger에 없을 수 있음(정상).

---

## 11. 관련 파일

| 파일 | 설명 |
|------|------|
| `infra/scripts/09_demo-inventory-circuit-break.sh` | 데모 실행 |
| `infra/k8s/07-otel-collector.yaml` | OTLP → Jaeger 파이프라인 |
| `infra/k8s/11-mesh-egress-to-observe.yaml` | OTLP egress TLS DISABLE |
| `infra/helm/jaeger.yaml` | memory 스토리지 |
| `infra/helm/kiali.yaml` | Jaeger Query 연동 |
| `infra/lab-access.env` | Jaeger UI 포트 13003 |
| `infra/Prometheus-query.md` | 메트릭(서킷브레이크·HPA) PromQL |
| `order-service/.../application.yml` | 트레이싱·OTLP 설정 |
| `inventory-service/.../application.yml` | 동일 + `inventory.version` / fault |
