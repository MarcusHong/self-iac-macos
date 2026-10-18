# SELF Infra - macos

LLM 운영용 셀프호스팅 인프라.
Argo CD로 서비스를 배포하고(OCI Ops), 필요하면 GitLab CE를 함께 올린다.

## 개요

headless 서버로 운영하며, 호스트에 데이터 레이어(PostgreSQL, Valkey, RustFS)를
네이티브로 설치하고 OrbStack K8s 위에 워크로드(Traefik, Argo CD, 선택적으로 GitLab)를 배포한다.

외부 접근은 Tailscale VPN 메시를 통해 이루어지며, Let's Encrypt 정식 인증서로 HTTPS를 제공한다.
호스트 서비스는 localhost에만 리슨하고 비밀번호 없이 운영한다(별도 시크릿 저장소 없음). Argo CD 구성은 builders-starter-iac를 따른다:
플랫폼 매니페스트(`k8s/`)는 직접 적용하고, 서비스는 CI가 발행한 `*-deploy` OCI 아티팩트를 Argo CD가 동기화한다.
이 저장소는 Argo CD source가 아니다.

| 레이어 | 구성 | 역할 |
|--------|------|------|
| **네트워크** | Tailscale | VPN 메시, MagicDNS, TLS 인증서 |
| **호스트** | PostgreSQL 18, Valkey, RustFS | 데이터, 캐시, 오브젝트 스토리지(S3) |
| **K8s** | Traefik, Argo CD, GitLab CE (선택) | Ingress, GitOps, CI/CD |
| **자동화** | 매월 인증서 갱신 (launchd) (+ GitLab 사용 시 일일 백업, 주간 Registry GC) | 무인 운영 |

### GitLab (선택)

GitLab은 기본으로 설치하지 않는다. 설치하려면 `INSTALL_GITLAB=true`로 실행한다.

```bash
INSTALL_GITLAB=true ./bootstrap/run.sh
```

`INSTALL_GITLAB=true`이면 PostgreSQL `gitlab` 유저/DB와 RustFS `gitlab-*` 버킷을 만들고 GitLab을 설치한다.

### 구성 요소 버전

| 구성 요소 | 버전 | 고정 위치 |
|-----------|------|-----------|
| PostgreSQL | 18 (Homebrew `postgresql@18`) | `01-data.sh` `PG_VERSION` |
| RustFS | 1.0.3 (GitHub 릴리스 바이너리, SHA-256 확인) | `01-data.sh` `RUSTFS_VERSION`, `RUSTFS_SHA256` |
| Traefik | chart 42.0.0 / v3.7.14 | `02-k8s.sh` `TRAEFIK_CHART_VERSION` |
| Argo CD | chart 10.10.5 / v3.5.5 | `02-k8s.sh` `ARGOCD_CHART_VERSION` |
| GitLab CE | chart 10.5.0 / 19.5.0 | `02-k8s.sh` `GITLAB_CHART_VERSION` |
| GitLab Runner 기본 이미지 | `ubuntu:26.04` | `gitlab-values.yaml` |

Valkey, kubectl, Helm, Argo CD CLI, Tailscale은 설치 시점의 Homebrew 최신 버전을 사용한다.

## 아키텍처

```
┌─ SELF Infra ──────────────────────────────────────────┐
│                                                       │
│  ┌─ Host (Native) ─────────────────────────────────┐  │
│  │  PostgreSQL 18  :5432      Valkey     :6379     │  │
│  │  RustFS (S3)    :9000                           │  │
│  └────────────────────────┬────────────────────────┘  │
│                           │ host.docker.internal      │
│  ┌─ OrbStack K8s ─────────┴────────────────────────┐  │
│  │  Traefik        Ingress + TLS                   │  │
│  │  Argo CD        GitOps (/argocd)                │  │
│  │  GitLab CE      Runner · Registry  (선택)       │  │
│  │                 Terraform State                 │  │
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
- **플랫폼과 서비스 배포 분리.** 플랫폼 매니페스트는 `k8s/deploy.sh`로 직접 적용하고, 서비스는 OCI 아티팩트를 Argo CD가 동기화한다.
- **GitLab은 선택.** 켜면 코드, CI/CD, 레지스트리, Terraform state를 맡는다.

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
│   ├── 01-data.sh             # PostgreSQL, Valkey, RustFS, TLS
│   ├── 02-k8s.sh              # Traefik, GitLab (선택), Argo CD
│   ├── argocd-values.yaml     # Argo CD Helm values
│   ├── gitlab-values.yaml     # GitLab Helm values
│   └── traefik-values.yaml    # Traefik Helm values
│
├── k8s/                       # 직접 적용하는 플랫폼 매니페스트 (Argo CD source 아님)
│   ├── deploy.sh              # 렌더 → 토큰 치환/검사 → kubectl apply --server-side
│   ├── kustomization.yaml
│   ├── namespace.yaml         # apps namespace
│   ├── projects/              # AppProject: platform, apps
│   ├── infra/                 # Argo CD Ingress (Traefik, /argocd)
│   ├── services/              # 서비스별 OCI Application
│   └── _template/service/     # 서비스 등록 템플릿
│
└── docs/
    ├── bootstrap/
    │   ├── 00-prerequisites.md
    │   ├── 01-data.md
    │   └── 02-k8s.md
    ├── argocd.md
    ├── migrate-minio-to-rustfs.md
    └── operations.md
```

## 문서

- [00 - 사전 요구사항](docs/bootstrap/00-prerequisites.md)
- [01 - 호스트 데이터 레이어](docs/bootstrap/01-data.md)
- [02 - K8s 워크로드](docs/bootstrap/02-k8s.md)
- [Argo CD 운영](docs/argocd.md)
- [운영 가이드](docs/operations.md)
- [MinIO → RustFS 이전](docs/migrate-minio-to-rustfs.md)

## 리소스 예상 사용량

| 구분 | RAM |
|------|:---:|
| 호스트 (PG, Valkey, RustFS, macOS) | ~4.6GB |
| K8s (Traefik, Argo CD, limit 기준) | ~2.3GB |
| K8s (GitLab, 선택, limit 기준) | +~6GB |
| **합계 (GitLab 포함)** | **~12.9GB** |
| **여유 (16GB 기준, GitLab 포함)** | **~3.1GB** |

## 향후 확장

부트스트랩 완료 후, 플랫폼 컴포넌트는 `k8s/`의 Argo CD Application(공개 Helm source)으로, 서비스는 OCI Application으로 배포한다.

| 서비스 | 용도 |
|--------|------|
| pgvector | RAG 벡터 DB (PostgreSQL extension) |
| Open WebUI | 챗 인터페이스 |
| FastAPI Gateway | 에이전트 오케스트레이션 |
| GitLab MCP Server | AI 에이전트 ↔ GitLab 연동 |
