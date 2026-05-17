# egovframe-sample-msa

Spring Boot 3.5.6 기반 3개 서비스(`order-service`, `payment-service`, `inventory-service`)를 Kubernetes에 배포하고, Istio + OpenTelemetry + Prometheus/Loki/Jaeger/Grafana/Kiali를 함께 실습하기 위한 샘플 프로젝트입니다.

## 1. 프로젝트 구조

```text
.
├── pom.xml              # 멀티 모듈 부모 POM
├── order-service
├── payment-service
├── inventory-service
├── docs
└── infra                # Kubernetes + Istio + Helm 관측
    ├── helm
    ├── k8s
    └── scripts
```

## 2. 사전 요구사항

**빌드**

- Java 17
- Maven 3.9+
- Docker(컨테이너 이미지 빌드용)

**클러스터 배포·실습**

- kubectl
- Helm 3
- istioctl
- Kubernetes 클러스터(kind/minikube/원격 클러스터)

**minikube(교육용)로 `01`~`04`를 그대로 쓸 때**

- `kubectl`·`minikube`만으로는 부족합니다. **`helm`**, **`istioctl`**, 로컬 **`docker`**, **`java`/`maven`**(01번)이 필요합니다.
- `minikube start` 후 클러스터가 준비된 상태에서 스크립트를 실행하세요. 관측 스택이 무거우므로 메모리·CPU를 넉넉히 주는 것이 좋습니다(예: `--memory=8192 --cpus=4`).
- `01_build-images.sh`는 기본적으로 **호스트 Docker**에 이미지를 만듭니다. 그대로 두면 `04`에서 Pod가 `your-registry/...` 이미지를 **레지스트리에서 받으려다 실패**합니다. 아래 중 하나를 쓰세요.
  - **권장:** `MINIKUBE_DOCKER=true ./infra/scripts/01_build-images.sh` — minikube 노드가 쓰는 Docker에 같은 태그로 빌드합니다(프로필은 `MINIKUBE_PROFILE`로 지정 가능).
  - 또는 호스트에서 빌드한 뒤 `minikube image load`로 이미지를 클러스터에 넣습니다.
- 스토리지: Loki 등이 PVC를 쓰므로 클러스터에 **기본 StorageClass**가 있어야 합니다(minikube 기본 `standard`로 동작하는 경우가 많음).
- **선택 환경변수** (쉘 또는 `infra/config.env`에 `export` 없이 `KEY=value` 로만 두면 스크립트가 `source` 합니다):

  | 변수 | 스크립트 | 설명 |
  |------|----------|------|
  | `MINIKUBE_PROFILE` | `01`, `02` | 기본 `minikube` |
  | `MINIKUBE_START_ARGS` | `02` | API 연결 실패 시 `minikube start` 추가 인자 (예: `"--memory=8192 --cpus=4"`) |
  | `SKIP_MINIKUBE_IMAGE_LOAD` | `01` | `true` 이면 호스트 빌드 후 `minikube image load` 생략 |
  | `MINIKUBE_DOCKER` | `01` | 실행 시 `MINIKUBE_DOCKER=true` 권장 — `minikube docker-env` 로 빌드 |

### 설정 파일 (`infra/`)

| 파일 | 용도 |
|------|------|
| [`infra/config.env`](infra/config.env) | (선택) `EGOVFRAME_MSA_ROOT`, `REGISTRY`, `TAG` |
| [`infra/lab-access.env`](infra/lab-access.env) | `LAB_ACCESS_HOST`, `LAB_PORT_*` — `05` port-forward·데모 URL |

`config.env`에 경로를 넣지 않으면 clone 위치 기준으로 자동 계산됩니다. 포트·minikube 세부 옵션은 각각 `lab-access.env`·위 표만 보면 됩니다.

## 3. 빠른 시작

Kubernetes에 Istio·관측 스택·샘플 앱을 올리는 기준 순서입니다.

### 3-1. 이미지 빌드

```bash
cd egovframe-sample-msa
REGISTRY=<your-registry> TAG=1.0.0 ./infra/scripts/01_build-images.sh
```

minikube에서 곧바로 배포까지 할 경우(같은 `your-registry/...` 태그를 노드에서 쓰려면):

```bash
MINIKUBE_DOCKER=true ./infra/scripts/01_build-images.sh
```

`infra/k8s/*.yaml`의 이미지 경로(`your-registry/...`)를 사용 레지스트리로 맞추거나, 배포 전 `sed`로 변경합니다.

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

### 3-5. localhost 브라우저 접속 (port-forward)

macOS(minikube docker)·Windows WSL 등 **NodePort/minikube ip 가 브라우저에서 안 될 때** 사용합니다.  
고정 포트는 [`infra/lab-access.env`](infra/lab-access.env) 에 정의되어 있으며, `05` 가 Kiali·Grafana Helm URL 을 함께 맞춥니다. 이미지 태그·저장소 경로는 [`infra/config.env`](infra/config.env) 를 참고하세요.

```bash
./infra/scripts/05_start-lab-access.sh
```

중지·상태·URL 목록:

```bash
./infra/scripts/05_start-lab-access.sh stop
./infra/scripts/05_start-lab-access.sh status
./infra/scripts/05_start-lab-access.sh urls
```

| 구분 | URL (기본) |
|------|------------|
| Kiali | http://localhost:13001/kiali/ |
| Grafana | http://localhost:13002 (admin/admin) |
| Jaeger | http://localhost:13003 |
| Prometheus | http://localhost:13004 |
| Loki | http://localhost:13005 |
| Order API | `POST http://localhost:18088/api/orders` (본문 없이 `curl -X POST` 가능) |
| Order Swagger | http://localhost:18080/swagger-ui.html |

**Kiali 트레이스 확인 (교육용):**

```bash
./infra/scripts/10_demo-kiali-traces.sh
```

상세: [`infra/docs/Jaeger-query.md`](infra/docs/Jaeger-query.md)

**호출 흐름:** `Ingress(/api/orders)` → `order-service` → `inventory-service`(라운드로빈: `latest` / `risky`) → `payment-service`.  
`risky` 인스턴스는 5xx 를 반환하고, `inventory-service-dr` 의 `outlierDetection`(risky 에 5xx **연속 10회** → 50초 격리)으로 회로 차단됩니다. 이후 latest 로만 라우팅되면 HPA 가 스케일아웃합니다.

**Kiali Traffic Graph** 는 Prometheus 가 Istio(Envoy) 메트릭을 수집해야 표시됩니다(`infra/k8s/09-istio-envoy-podmonitor.yaml`, `03` 에서 적용). 그래프가 비어 있으면 `05` 실행 후 **Ingress Order API**(`18088`) 로 요청을 보내고 Kiali 에서 **Last 5m**·네임스페이스 **msaedu**·**istio-system** 을 선택하세요. observe 네임스페이스는 사이드카 없이 운영합니다.

### 3-6. 클러스터 실습 초기화(02~04 재시도 전)

중간에 오류가 나 부분 적용만 된 경우, 아래로 Helm·매니페스트·네임스페이스를 정리한 뒤 `02`부터 다시 실행할 수 있습니다.

```bash
./infra/scripts/08_reset-cluster-lab.sh
```

Istio 제어 플레인(`istio-system`)까지 지우고 완전히 맞추려면:

```bash
./infra/scripts/08_reset-cluster-lab.sh --purge-istio
```

로컬 Docker 이미지(`01_build-images.sh`)는 삭제하지 않습니다.

## 4. 실습 확인 포인트

### 4-1. Gateway 주소 확인

```bash
kubectl get svc istio-ingressgateway -n istio-system
```

`EXTERNAL-IP` 또는 `NodePort`를 확인 후 `GATEWAY_HOST` 변수에 넣어 사용합니다.

### 4-2. 주문 API 호출

```bash
curl -X POST "http://${GATEWAY_HOST}/api/orders" \
  -H "Content-Type: application/json" \
  -d '{
    "orderId":"ORD-1001",
    "itemId":"ITEM-1",
    "quantity":2,
    "price":1500
  }'
```

### 4-3. inventory-service 장애전파·서킷브레이커 (Kiali)

`inventory-service` 를 **latest(정상)** / **risky(503 주입)** 두 Deployment 로 배포하고 단일 Service 로 **ROUND_ROBIN** 분산합니다. risky 에 **5xx 연속 10회**가 쌓이면 서킷브레이크로 격리되고 요청은 **latest 100%** 로 몰립니다. 이때 latest CPU 가 올라가면 HPA(목표 25%)가 Pod 를 늘립니다.

| 리소스 | 파일 |
|--------|------|
| inventory latest / risky Deployment + HPA | `infra/k8s/04-inventory-service.yaml` |
| 단일 host 라우팅 | `infra/k8s/05-istio-ingress-and-routing.yaml` |
| DestinationRule + subsets + outlierDetection | `infra/k8s/10-inventory-circuit-breaking.yaml` |
| observe 호출(TLS DISABLE) | `infra/k8s/11-mesh-egress-to-observe.yaml` |

```bash
MINIKUBE_DOCKER=true ./infra/scripts/01_build-images.sh
./infra/scripts/04_deploy-apps.sh
./infra/scripts/05_start-lab-access.sh start

./infra/scripts/09_demo-inventory-circuit-break.sh   # 60회 기본
kubectl get hpa,deploy -n msaedu -w                   # 스케일아웃 관찰
```

**Kiali:** Graph Type **Versioned app graph**, Display **Response Code**·**Traffic Distribution**, Namespace **msaedu** + **istio-system**.  
초반에는 `latest` / `risky` 로 5xx 가 섞이다가 회로 차단 후에는 `latest` 만 호출되며 inventory-latest Pod 수가 늘어납니다.

### 4-4. Payment 지연 시뮬레이션

```bash
kubectl port-forward -n msaedu svc/payment-service 18081:8081
curl "http://localhost:18081/api/payments/simulate-delay?millis=2500"
```

Istio `VirtualService`에서 설정한 timeout/retry 정책(`infra/k8s/06-istio-resilience.yaml`) 전후를 비교해봅니다.

### 4-5. Swagger UI(springdoc-openapi)

각 서비스 애플리케이션 포트에서 OpenAPI 문서와 Try-it-out UI 가 제공됩니다.

| 서비스 | 접속 예(포트포워딩 후 브라우저) |
|--------|--------------------------------|
| order-service | http://localhost:8080/swagger-ui.html |
| payment-service | http://localhost:8081/swagger-ui.html |
| inventory-service | http://localhost:8082/swagger-ui.html |

예: `kubectl port-forward -n msaedu svc/order-service 8080:8080` 실행 후 위 주소로 Swagger UI에 접속합니다.

## 5. 관측 도구 접속

**교육용 권장:** `./infra/scripts/05_start-lab-access.sh` 로 localhost 고정 포트·Kiali/Grafana URL 을 한 번에 맞춘다(3-5절 표 참고).

클러스터 NodePort(30001~30004)는 Linux 노드 IP에서 직접 열리는 환경용이다. macOS minikube(docker)·일부 WSL 에서는 `minikube ip:30001` 이 브라우저에서 되지 않을 수 있다.

애플리케이션 Pod는 클러스터 내부에서 **`http://otel-collector.observe:4318`** 로 OTLP(HTTP) 트레이스·메트릭을 보냅니다. 로그·메트릭 UI 는 Grafana·Prometheus·Jaeger·Kiali 에서 확인합니다.

관측 스택 배포 상태 점검:

```bash
./infra/scripts/06_verify-observability.sh
```

## 6. 2시간 실습 권장 진행 순서

리허설 전 점검은 저장소 루트에서 `./infra/scripts/07_rehearsal-dryrun.sh`(Maven 빌드·스크립트 문법·핵심 경로 존재 여부)를 실행할 수 있습니다. 상세 체크리스트는 `docs/rehearsal-120m.md`를 참고하세요.

1. 아키텍처 설명(10분)
2. 서비스 코드 및 호출 흐름 설명(20분)
3. Kubernetes 배포 실습(25분)
4. Istio 라우팅/복원력·inventory 서킷브레이커 실습(25분, `09_demo-inventory-circuit-break.sh`)
5. OTel Collector + 관측 도구·Kiali 그래프 확인(30분)
6. 장애 시나리오와 지표 해석(10분)

## 7. 문서

저장소에 포함된 `docs/` 목록은 아래와 같습니다. 디렉터리·스크립트 역할 요약은 `docs/project-structure.md`를 보면 됩니다.

- `docs/project-structure.md`: 디렉터리·파일 구성 및 역할
- `docs/domain-api-scenario.md`: 도메인 경계, 호출 흐름, REST API 시나리오
- `docs/cluster-script.md`: `infra/scripts` 권장 순서·`04_deploy-apps.sh`·보조 스크립트
- `docs/cluster-observability-scenario.md`: 클러스터에서 메트릭·로그·트레이스 확인 절차
- `docs/cluster-practice-and-observability-guide.md`: 실습 순서·Service Mesh·관측 데이터 경로·도구별 확인 방법 통합 가이드
- `docs/step-flow.md`: `infra/k8s` 매니페스트 단계별 적용·복구 플로우(스크립트는 `04_deploy-apps.sh`로 일괄 적용)
- `docs/rehearsal-120m.md`: 120분 리허설 타임박스·실패 포인트·체크리스트

## 9. 참고

- DaemonSet Collector가 `filelog`로 노드 Pod 로그를 Loki로 보내고, OTLP 메트릭·트레이스는 Prometheus·Jaeger로 이어지는 구성입니다. 확인 절차는 `docs/cluster-observability-scenario.md`를 참고하세요.
- 클러스터 환경에 따라 StorageClass, LoadBalancer, 보안 정책 조정이 필요할 수 있습니다.
