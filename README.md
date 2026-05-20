# egovframe-msa-edu

**전자정부 MSA·Service Mesh 교육용 샘플** — Spring Boot 3.5 기반 3개 마이크로서비스를 Kubernetes에 배포하고, Istio와 OpenTelemetry·Prometheus·Loki·Jaeger·Grafana·Kiali로 관측·복원력을 실습하는 저장소입니다.

| 항목 | 내용 |
|------|------|
| Maven 프로젝트 | `egovframe-msa-edu` (`pom.xml`) |
| 서비스 | `order-service`, `payment-service`, `inventory-service` |
| 네임스페이스 | `msaedu`(앱·메시), `observe`(관측), `istio-system`(Istio) |

**호출 흐름:** `Ingress(/api/orders)` → `order-service` → `inventory-service`(라운드로빈: `latest` / `risky`) → `payment-service`.  
`risky` 인스턴스는 5xx를 주입하고, `outlierDetection`(5xx 연속 10회 → 50초 격리) 후 `latest`로만 라우팅되면 HPA가 스케일아웃합니다.

---

## 1. 프로젝트 구조

```text
.
├── pom.xml                 # 멀티 모듈 부모 POM
├── order-service/
├── payment-service/
├── inventory-service/
└── infra/                  # Kubernetes · Istio · Helm · 스크립트
    ├── config.env          # (선택) 레지스트리·태그·루트 경로
    ├── lab-access.env      # localhost port-forward 포트
    ├── helm/
    ├── k8s/
    ├── scripts/            # 01~10 배포·데모·검증
    └── docs/               # k8s·Helm·쿼리 참고
```

---

## 2. 사전 요구사항

### 빌드

- Java 17, Maven 3.9+
- Docker (컨테이너 이미지 빌드)

### 클러스터·배포

- docker desktop, `kubectl`, Helm 3, `istioctl`, `minikube`

### minikube로 `01`~`04` 실행 시

- 위 도구에 더해 **로컬 Docker**, **Java/Maven**(`01`에서 JAR 빌드)이 필요합니다.
- 관측 스택이 무거우므로 리소스를 넉넉히 할당하는 것을 권장합니다.  
  예: `minikube start --memory=8192 --cpus=4`
- **`01_build-images.sh`:** 기본은 호스트 Docker 빌드입니다. minikube에 바로 올릴 때는 아래 중 하나를 사용하세요.
  - **권장:** `MINIKUBE_DOCKER=true ./infra/scripts/01_build-images.sh` — minikube 노드 Docker에 동일 태그로 빌드
  - 또는 호스트 빌드 후 `minikube image load`로 이미지 적재
- Loki 등이 PVC를 사용하므로 클러스터에 **기본 StorageClass**가 있어야 합니다.

| 환경 변수 | 스크립트 | 설명 |
|-----------|----------|------|
| `MINIKUBE_PROFILE` | `01`, `02` | 기본 `minikube` |
| `MINIKUBE_START_ARGS` | `02` | API 연결 실패 시 `minikube start` 추가 인자 |
| `SKIP_MINIKUBE_IMAGE_LOAD` | `01` | `true`이면 `minikube image load` 생략 |
| `MINIKUBE_DOCKER` | `01` | `true` — `minikube docker-env`로 빌드 |

값은 셸에서 export하거나, `infra/config.env`에 `KEY=value` 형태로 두면 스크립트가 자동으로 읽습니다.

### 설정 파일

| 파일 | 용도 |
|------|------|
| [`infra/config.env`](infra/config.env) | `REGISTRY`, `TAG`, (Windows 환경에서는 필수) `EGOVFRAME_MSA_ROOT`, |
| [`infra/lab-access.env`](infra/lab-access.env) | `LAB_ACCESS_HOST`, `LAB_PORT_*` — `05` port-forward·데모 URL |

`config.env`에 루트 경로를 넣지 않으면 clone 위치 기준으로 자동 계산됩니다.

---

## 3. 빠른 시작

저장소 루트에서 아래 순서로 실행합니다.

### 3-1. 이미지 빌드

```bash
# 일반 레지스트리
REGISTRY=<your-registry> TAG=1.0.0 ./infra/scripts/01_build-images.sh

# minikube (권장)
MINIKUBE_DOCKER=true ./infra/scripts/01_build-images.sh
```

`infra/k8s/*.yaml`의 `your-registry/...` 이미지 경로를 사용 환경에 맞게 수정하거나, 배포 전 `sed`로 치환합니다.

### 3-2. Istio 설치

```bash
./infra/scripts/02_install-istio.sh
```

### 3-3. 관측 스택 설치

```bash
./infra/scripts/03_install-observability.sh
```

### 3-4. 애플리케이션 배포

```bash
./infra/scripts/04_deploy-apps.sh
```

### 3-5. localhost 접속 (port-forward)

macOS(minikube docker)·Windows WSL 등에서 NodePort/`minikube ip`가 브라우저에서 열리지 않을 때 사용합니다.

```bash
./infra/scripts/05_start-lab-access.sh
./infra/scripts/05_start-lab-access.sh status   # 상태
./infra/scripts/05_start-lab-access.sh urls     # URL 목록
./infra/scripts/05_start-lab-access.sh stop     # 중지
```

| 구분 | URL (기본) |
|------|------------|
| Kiali | http://localhost:13001/kiali/ |
| Grafana | http://localhost:13002 (admin/admin) |
| Jaeger | http://localhost:13003 |
| Prometheus | http://localhost:13004 |
| Loki | http://localhost:13005 |
| Order API | `POST http://localhost:18088/api/orders` |
| Order Swagger | http://localhost:18080/swagger-ui.html |

**Kiali 트레이스 데모:**

```bash
./infra/scripts/10_demo-kiali-traces.sh
```

상세: [`infra/docs/Jaeger-query.md`](infra/docs/Jaeger-query.md)

**Kiali Traffic Graph:** Prometheus가 Istio(Envoy) 메트릭을 수집해야 표시됩니다(`infra/k8s/09-istio-envoy-podmonitor.yaml`). 그래프가 비어 있으면 `05` 실행 후 Ingress Order API(`18088`)로 트래픽을 보내고, Kiali에서 **Last 5m**, 네임스페이스 **msaedu**·**istio-system**을 선택하세요.

### 3-6. 실습 초기화 (`02`~`04` 재시도)

```bash
./infra/scripts/08_reset-cluster-lab.sh
./infra/scripts/08_reset-cluster-lab.sh --purge-istio   # Istio 제어 플레인까지 제거
```

로컬 Docker 이미지(`01`에서 빌드한 것)는 삭제하지 않습니다.

---

## 4. 실습 확인 포인트

### 4-1. Gateway 주소

```bash
kubectl get svc istio-ingressgateway -n istio-system
```

`EXTERNAL-IP` 또는 NodePort를 `GATEWAY_HOST`에 설정한 뒤 API를 호출합니다.

### 4-2. 주문 API

```bash
curl -X POST "http://${GATEWAY_HOST}/api/orders" \
  -H "Content-Type: application/json" \
  -d '{"orderId":"ORD-1001","itemId":"ITEM-1","quantity":2,"price":1500}'
```

port-forward 사용 시: `curl -X POST http://localhost:18088/api/orders`

### 4-3. inventory 서킷브레이커·HPA (Kiali)

| 리소스 | 파일 |
|--------|------|
| latest / risky Deployment + HPA | `infra/k8s/04-inventory-service.yaml` |
| Ingress·라우팅 | `infra/k8s/05-istio-ingress-and-routing.yaml` |
| DestinationRule·outlierDetection | `infra/k8s/10-inventory-circuit-breaking.yaml` |
| observe 호출(TLS DISABLE) | `infra/k8s/11-mesh-egress-to-observe.yaml` |

```bash
./infra/scripts/09_demo-inventory-circuit-break.sh   # 기본 60회 호출
kubectl get hpa,deploy -n msaedu -w
```

Kiali: **Versioned app graph**, **Response Code**·**Traffic Distribution**, Namespace **msaedu** + **istio-system**.

### 4-4. Payment 지연 시뮬레이션

```bash
curl "http://localhost:18081/api/payments/simulate-delay?millis=2500"
```

`infra/k8s/06-istio-resilience.yaml`의 timeout·retry 정책 전후를 비교합니다.

### 4-5. Swagger UI (springdoc-openapi)

| 서비스 | URL (`05` port-forward 기준) |
|--------|------------------------------|
| order-service | http://localhost:18080/swagger-ui.html |
| payment-service | http://localhost:18081/swagger-ui.html |
| inventory-service | http://localhost:18082/swagger-ui.html |

---

## 5. 관측 도구

**권장:** `./infra/scripts/05_start-lab-access.sh` — localhost 고정 포트·Kiali/Grafana URL 일괄 설정 (3-5절 표).

애플리케이션 Pod는 **`http://otel-collector.observe:4318`** 로 OTLP(HTTP) 트레이스·메트릭을 전송합니다. 로그·메트릭·트레이스 UI는 Grafana·Prometheus·Jaeger·Kiali에서 확인합니다.

```bash
./infra/scripts/06_verify-observability.sh
```

클러스터 NodePort(30001~30004)는 Linux 노드 IP에서 직접 접속하는 환경용입니다.

## 6. 문서

### 인프라 (`infra/docs/`)

| 문서 | 내용 |
|------|------|
| [`k8s.md`](infra/docs/k8s.md) | Kubernetes 매니페스트 |
| [`helm.md`](infra/docs/helm.md) | Helm values |
| [`Jaeger-query.md`](infra/docs/Jaeger-query.md) | Jaeger·트레이스 조회 |
| [`Prometheus-query.md`](infra/docs/Prometheus-query.md) | PromQL 예시 |

### 스크립트 (`infra/scripts/`)

| 스크립트 | 역할 |
|----------|------|
| `01_build-images.sh` | Maven 빌드·Docker 이미지 |
| `02_install-istio.sh` | Istio 설치 |
| `03_install-observability.sh` | 관측 스택 Helm·OTel |
| `04_deploy-apps.sh` | 앱·Istio 매니페스트 일괄 적용 |
| `05_start-lab-access.sh` | localhost port-forward |
| `06_verify-observability.sh` | 관측 파이프라인 점검 |
| `07_rehearsal-dryrun.sh` | 교육 전 리허설 |
| `08_reset-cluster-lab.sh` | 실습 환경 초기화 |
| `09_demo-inventory-circuit-break.sh` | 서킷브레이커·HPA 데모 |
| `10_demo-kiali-traces.sh` | Kiali 트레이스 데모 |

---

## 7. 참고

- OTel Collector DaemonSet이 노드 Pod 로그를 Loki로, OTLP 메트릭·트레이스를 Prometheus·Jaeger로 전달합니다.
- 클러스터마다 StorageClass, LoadBalancer, 보안 정책 조정이 필요할 수 있습니다.
