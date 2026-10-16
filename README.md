# SELF Infra - macos

LLM 운영용 셀프호스팅 인프라.
GitLab CE(선택)와 Flux로 GitOps 파이프라인을 구성한다.

## 개요

headless 서버로 운영하며, 호스트에 데이터 레이어(PostgreSQL, Valkey, MinIO, OpenBao)를
네이티브로 설치하고 OrbStack K8s 위에 워크로드(Traefik, 선택적으로 GitLab·Flux)를 배포한다.

외부 접근은 Tailscale VPN 메시를 통해 이루어지며, Let's Encrypt 정식 인증서로 HTTPS를 제공한다.
시크릿은 OpenBao에서 중앙 관리하고, GitLab 사용 시 부트스트랩 이후 인프라 변경은 Flux GitOps로 처리한다.

| 레이어 | 구성 | 역할 |
|--------|------|------|
| **네트워크** | Tailscale | VPN 메시, MagicDNS, TLS 인증서 |
| **호스트** | PostgreSQL 18, Valkey, MinIO, OpenBao | 데이터, 캐시, 오브젝트 스토리지, 시크릿 |
| **K8s** | Traefik, GitLab CE (선택), Flux (GitLab 사용 시) | Ingress, CI/CD, GitOps |
| **자동화** | 격월 인증서 갱신 (+ GitLab 사용 시 일일 백업, 주간 Registry GC) | 무인 운영 |

### GitLab (선택)

GitLab은 기본으로 설치하지 않는다. 설치하려면 `INSTALL_GITLAB=true`로 실행한다.

```bash
INSTALL_GITLAB=true ./bootstrap/run.sh
```

`INSTALL_GITLAB=true`이면 PostgreSQL `gitlab` 유저/DB와 MinIO `gitlab-*` 버킷을 만들고,
GitLab 설치 후 GitLab을 소스로 Flux를 부트스트랩한다.

### 구성 요소 버전

| 구성 요소 | 버전 | 고정 위치 |
|-----------|------|-----------|
| PostgreSQL | 18 (Homebrew `postgresql@18`) | `01-data.sh` `PG_VERSION` |
| OpenBao | 2.7.1 (Homebrew 실패 시 바이너리) | `01-data.sh` `OPENBAO_VERSION` |
| Traefik | chart 42.0.0 / v3.7.14 | `02-k8s.sh` `TRAEFIK_CHART_VERSION` |
| GitLab CE | chart 10.5.0 / 19.5.0 | `02-k8s.sh` `GITLAB_CHART_VERSION` |
| GitLab Runner 기본 이미지 | `ubuntu:26.04` | `gitlab-values.yaml` |

Valkey, MinIO, kubectl, Helm, flux CLI, Tailscale은 설치 시점의 Homebrew 최신 버전을 사용한다.

## 아키텍처

```
┌─ SELF Infra ──────────────────────────────────────────┐
│                                                       │
│  ┌─ Host (Native) ─────────────────────────────────┐  │
│  │  PostgreSQL 18  :5432      Valkey     :6379     │  │
│  │  MinIO          :9000      OpenBao    :8200     │  │
│  └────────────────────────┬────────────────────────┘  │
│                           │ host.docker.internal      │
│  ┌─ OrbStack K8s ─────────┴────────────────────────┐  │
│  │  Traefik        Ingress + TLS                   │  │
│  │  GitLab CE      Runner · Registry  (선택)       │  │
│  │                 Terraform State                 │  │
│  │  Flux           GitOps  (GitLab 사용 시)        │  │
│  └─────────────────────────────────────────────────┘  │
│                                                       │
│  ┌─ Tailscale ─────────────────────────────────────┐  │
│  │  https://<hostname>.ts.net  (Let's Encrypt)     │  │
│  └─────────────────────────────────────────────────┘  │
│                                                       │
└───────────────────────────────────────────────────────┘
```

### 설계 원칙

- **데이터는 호스트에, 워크로드는 K8s에.** K8s가 죽어도 DB는 살아있다.
- **GitLab은 선택.** 켜면 코드, CI/CD, 레지스트리, Terraform state, Flux 소스를 맡는다.
- **수동 작업은 부트스트랩 뿐.** 이후 모든 인프라 변경은 git push.

## 빠른 시작

```bash
# 서버에서 전체 순차 실행 (GitLab 제외)
./bootstrap/run.sh

# GitLab 포함
INSTALL_GITLAB=true ./bootstrap/run.sh

# 또는 단계별 실행 (01, 02에는 같은 INSTALL_GITLAB 값을 사용)
./bootstrap/00-prerequisites.sh
./bootstrap/01-data.sh
./bootstrap/02-k8s.sh

# 랩탑에서 원격 접근 설정 (별도)
./bootstrap/client.sh
```

## 프로젝트 구조

```
self-iac/
├── bootstrap/
│   ├── run.sh                 # 전체 순차 실행
│   ├── 00-prerequisites.sh    # 서버 설정 + Xcode CLT, Homebrew, OrbStack, Tailscale
│   ├── client.sh              # 랩탑에서 원격 OrbStack kubeconfig 구성
│   ├── 01-data.sh             # PostgreSQL, Valkey, MinIO, OpenBao, TLS
│   ├── 02-k8s.sh              # Traefik, GitLab·Flux (선택)
│   ├── gitlab-values.yaml     # GitLab Helm values
│   └── traefik-values.yaml    # Traefik Helm values
│
└── docs/
    ├── bootstrap/
    │   ├── 00-prerequisites.md
    │   ├── 01-data.md
    │   └── 02-k8s.md
    └── operations.md
```

## 문서

- [00 - 사전 요구사항](docs/bootstrap/00-prerequisites.md)
- [01 - 호스트 데이터 레이어](docs/bootstrap/01-data.md)
- [02 - K8s 워크로드](docs/bootstrap/02-k8s.md)
- [운영 가이드](docs/operations.md)

## 리소스 예상 사용량

| 구분 | RAM |
|------|:---:|
| 호스트 (PG, Valkey, MinIO, OpenBao, macOS) | ~4.6GB |
| K8s (GitLab·Flux 포함 시, Traefik, limit 기준) | ~6GB |
| **합계 (GitLab 포함)** | **~10.6GB** |
| **여유 (16GB 기준, GitLab 포함)** | **~5.4GB** |

## 향후 확장

부트스트랩 완료 후, 모든 서비스는 Flux GitOps로 배포한다 (GitLab 사용 시).

| 서비스 | 용도 |
|--------|------|
| External Secrets Operator | OpenBao → K8s Secret 자동 동기화 |
| pgvector | RAG 벡터 DB (PostgreSQL extension) |
| Open WebUI | 챗 인터페이스 |
| FastAPI Gateway | 에이전트 오케스트레이션 |
| GitLab MCP Server | AI 에이전트 ↔ GitLab 연동 |
