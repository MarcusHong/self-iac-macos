#!/bin/bash
set -uo pipefail

# ================================================
# K8s 워크로드 (02-k8s)
#
#   ① Traefik (TLS 종단)
#   ② GitLab CE (Helm, INSTALL_GITLAB=true 일 때만)
#   ③ Argo CD (GitOps) + k8s/ 플랫폼 매니페스트 직접 적용
#
# 01-data.sh가 실행 중이어야 함
# INSTALL_GITLAB 기본값: false (01-data.sh와 같은 값으로 실행)
# ================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Apple Silicon Homebrew(/opt/homebrew)는 기본 PATH에 없음 — run.sh나 새 셸에서 실행해도 찾도록
[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"

INSTALL_GITLAB="${INSTALL_GITLAB:-false}"

PG_VERSION="18"
CERT_DIR="$HOME/.local/share/tailscale-certs"

# 호스트 서비스는 localhost 전용이라 비밀번호 없이 운영 (01-data.sh와 같은 값)
S3_ENDPOINT="http://host.docker.internal:9000"   # RustFS — 파드의 host.docker.internal은 Mac localhost로 연결됨
S3_REGION="us-east-1"
S3_ACCESS_KEY="rustfsadmin"
S3_SECRET_KEY="rustfsadmin"
# PostgreSQL은 로컬 trust라 비밀번호를 검사하지 않음 — GitLab 차트가 Secret을 요구해서 자리 표시 값만 넣음
PG_GITLAB_PASS="unused-trust-auth"

# Helm 차트 버전 (고정)
TRAEFIK_CHART_VERSION="42.0.0"   # Traefik v3.7.14
GITLAB_CHART_VERSION="10.5.0"    # GitLab 19.5.0
ARGOCD_CHART_VERSION="10.10.5"   # Argo CD v3.5.5

step "1/4 사전 체크"

for cmd in kubectl helm; do
    command -v "$cmd" &>/dev/null || err "$cmd 필요"
done

if ! kubectl cluster-info &>/dev/null; then
    err "K8s 클러스터 연결 실패 (OrbStack K8s 활성화 확인)"
fi
log "K8s OK"

if [ "$INSTALL_GITLAB" = "true" ]; then
    # postgresql@18은 keg-only라 brew bin에 링크되지 않음 (01-data.sh의 PATH 설정은 이 프로세스에 전달되지 않음)
    export PATH="$(brew --prefix postgresql@${PG_VERSION})/bin:$PATH"

    psql -d postgres -c "SELECT 1;" &>/dev/null || err "PostgreSQL 미실행 (01-data.sh 먼저)"
    valkey-cli ping 2>/dev/null | grep -q "PONG" || err "Valkey 미실행"
    curl -sf http://127.0.0.1:9000/health &>/dev/null || err "RustFS 미실행 (01-data.sh 먼저)"
fi
log "호스트 데이터 레이어 OK"

TS_HOSTNAME=""
for certfile in "$CERT_DIR"/*.crt; do
    [ -f "$certfile" ] && TS_HOSTNAME=$(basename "$certfile" .crt) && break
done

if [ -z "$TS_HOSTNAME" ]; then
    err "TLS 인증서 없음. 01-data.sh 먼저."
fi
log "TLS: ${TS_HOSTNAME}"
GITLAB_HOST="${TS_HOSTNAME}"

step "2/4 Traefik"

kubectl create namespace traefik 2>/dev/null || true

kubectl create secret tls tailscale-tls \
    --namespace traefik \
    --cert="$CERT_DIR/${TS_HOSTNAME}.crt" \
    --key="$CERT_DIR/${TS_HOSTNAME}.key" \
    --dry-run=client -o yaml | kubectl apply -f -
log "TLS Secret 등록"

helm upgrade --install traefik oci://ghcr.io/traefik/helm/traefik \
    --version "$TRAEFIK_CHART_VERSION" \
    --namespace traefik \
    -f "$SCRIPT_DIR/traefik-values.yaml" \
    --wait --timeout 3m || err "Traefik 설치 실패"

log "Traefik 완료 (HTTPS: 443)"

step "3/4 GitLab CE"

if [ "$INSTALL_GITLAB" != "true" ]; then
    log "건너뜀 (INSTALL_GITLAB=${INSTALL_GITLAB}) — 설치하려면 INSTALL_GITLAB=true로 01, 02 재실행"
else
    kubectl create namespace gitlab 2>/dev/null || true

    kubectl create secret generic gitlab-postgres-secret \
        --namespace gitlab \
        --from-literal=password="${PG_GITLAB_PASS}" \
        --dry-run=client -o yaml | kubectl apply -f -

    # ── 오브젝트 스토리지 시크릿 (호스트 RustFS) ──
    # 형식은 GitLab 차트 문서의 외부 S3 예시를 따름 (docs.gitlab.com/charts/installation/migration/bundled_chart_migration)
    # RustFS는 127.0.0.1에만 리슨하지만 OrbStack 파드의 host.docker.internal은 Mac localhost로 연결됨
    S3_HOSTPORT="${S3_ENDPOINT#*://}"

    # Rails/Workhorse (fog) 연결
    kubectl create secret generic gitlab-object-storage \
        --namespace gitlab \
        --from-literal=connection="$(cat << EOF
provider: AWS
region: ${S3_REGION}
endpoint: ${S3_ENDPOINT}
aws_access_key_id: ${S3_ACCESS_KEY}
aws_secret_access_key: ${S3_SECRET_KEY}
path_style: true
EOF
)" \
        --dry-run=client -o yaml | kubectl apply -f -

    # toolbox 백업/복원은 s3cmd 설정 파일 형식을 사용
    kubectl create secret generic gitlab-object-storage-s3cmd \
        --namespace gitlab \
        --from-literal=config="$(cat << EOF
[default]
access_key = ${S3_ACCESS_KEY}
secret_key = ${S3_SECRET_KEY}
host_base = ${S3_HOSTPORT}
host_bucket = ${S3_HOSTPORT}
bucket_location = ${S3_REGION}
use_https = False
EOF
)" \
        --dry-run=client -o yaml | kubectl apply -f -

    # GitLab 19부터 s3는 s3_v2(AWS SDK v2) 별칭 — regionendpoint에 스킴 필수, host.docker.internal은 path-style 필수
    kubectl create secret generic gitlab-registry-storage \
        --namespace gitlab \
        --from-literal=config="$(cat << EOF
s3:
  bucket: gitlab-registry
  accesskey: ${S3_ACCESS_KEY}
  secretkey: ${S3_SECRET_KEY}
  region: ${S3_REGION}
  regionendpoint: ${S3_ENDPOINT}
  secure: false
  v4auth: true
  pathstyle: true
EOF
)" \
        --dry-run=client -o yaml | kubectl apply -f -

    # ── SMTP 설정 ──
    if [ -z "${SMTP_USER:-}" ]; then
        echo ""
        read -rp "  Gmail SMTP 설정? (y/N): " SMTP_ENABLE
        if [[ "${SMTP_ENABLE:-N}" =~ ^[Yy]$ ]]; then
            echo "  앱 비밀번호: https://myaccount.google.com/apppasswords"
            read -rp "  Gmail 주소: " SMTP_USER
            read -rsp "  앱 비밀번호: " SMTP_PASSWORD
            echo ""
        fi
    fi

    if [ -n "${SMTP_USER:-}" ] && [ -n "${SMTP_PASSWORD:-}" ]; then
        kubectl create secret generic gitlab-smtp-secret \
            --namespace gitlab \
            --from-literal=password="${SMTP_PASSWORD}" \
            --dry-run=client -o yaml | kubectl apply -f -
        log "SMTP 시크릿 생성 (${SMTP_USER})"
    else
        SMTP_USER=""
        log "SMTP 비활성화"
    fi

    # ── Runner 캐시 시크릿 ──
    kubectl create secret generic gitlab-runner-cache-secret \
        --namespace gitlab \
        --from-literal=accesskey="${S3_ACCESS_KEY}" \
        --from-literal=secretkey="${S3_SECRET_KEY}" \
        --dry-run=client -o yaml | kubectl apply -f -
    log "Runner 캐시 시크릿 생성"

    log "GitLab K8s Secrets 생성 (PostgreSQL gitlab 유저 패스워드 포함)"

    cp "$SCRIPT_DIR/gitlab-values.yaml" /tmp/gitlab-values-rendered.yaml || err "gitlab-values.yaml 복사 실패"
    sed -i '' "s|TS_HOSTNAME_PLACEHOLDER|${TS_HOSTNAME}|g" /tmp/gitlab-values-rendered.yaml
    if [ -n "${SMTP_USER:-}" ]; then
        sed -i '' "s/SMTP_USER_PLACEHOLDER/${SMTP_USER}/g" /tmp/gitlab-values-rendered.yaml
        sed -i '' "s/SMTP_ENABLED_PLACEHOLDER/true/" /tmp/gitlab-values-rendered.yaml
    else
        sed -i '' "s/SMTP_ENABLED_PLACEHOLDER/false/" /tmp/gitlab-values-rendered.yaml
        sed -i '' "s/SMTP_USER_PLACEHOLDER/noreply@example.com/g" /tmp/gitlab-values-rendered.yaml
    fi

    helm repo add gitlab https://charts.gitlab.io/ 2>/dev/null || true
    helm repo update gitlab

    echo "  GitLab Helm 설치 중 (5~10분)..."

    helm upgrade --install gitlab gitlab/gitlab \
        --version "$GITLAB_CHART_VERSION" \
        --namespace gitlab \
        -f /tmp/gitlab-values-rendered.yaml \
        --timeout 15m \
        --wait || err "GitLab 설치 실패"

    rm -f /tmp/gitlab-values-rendered.yaml
    log "GitLab 설치 완료!"

    GITLAB_ROOT_PW=$(kubectl get secret gitlab-gitlab-initial-root-password \
        -n gitlab -ojsonpath='{.data.password}' 2>/dev/null | base64 --decode || echo "N/A")

    echo ""
    echo "  GitLab root 비밀번호: ${GITLAB_ROOT_PW}"
    echo ""

    echo -n "  GitLab 응답 대기"
    for i in $(seq 1 60); do
        if curl -sfk "https://${GITLAB_HOST}/-/readiness" > /dev/null 2>&1; then
            echo ""
            log "GitLab 응답 OK"
            break
        fi
        echo -n "."
        sleep 5
        [ "$i" -eq 60 ] && { echo ""; warn "기동 중. kubectl get pods -n gitlab"; }
    done
fi

step "4/4 Argo CD"

kubectl create namespace argocd 2>/dev/null || true

# builders-starter-iac와 같은 구성: Argo CD는 Helm으로 설치하고,
# AppProject·Ingress·서비스 Application은 k8s/에서 직접 적용 (IaC 저장소는 Argo CD source가 아님)
helm upgrade --install argocd oci://ghcr.io/argoproj/argo-helm/argo-cd \
    --version "$ARGOCD_CHART_VERSION" \
    --namespace argocd \
    -f "$SCRIPT_DIR/argocd-values.yaml" \
    --set global.domain="$TS_HOSTNAME" \
    --set configs.cm.url="https://${TS_HOSTNAME}/argocd" \
    --wait --timeout 10m || err "Argo CD 설치 실패"

log "Argo CD 설치 완료"

TS_HOSTNAME="$TS_HOSTNAME" "$SCRIPT_DIR/../k8s/deploy.sh" || err "k8s/ 플랫폼 매니페스트 적용 실패"
log "Argo CD UI — https://${TS_HOSTNAME}/argocd"

ARGOCD_ADMIN_PW=$(kubectl get secret argocd-initial-admin-secret \
    -n argocd -ojsonpath='{.data.password}' 2>/dev/null | base64 --decode || echo "")

if [ -n "$ARGOCD_ADMIN_PW" ]; then
    echo ""
    echo "  Argo CD admin 비밀번호: ${ARGOCD_ADMIN_PW}"
    echo "  (argocd-initial-admin-secret에 보관 — 비밀번호를 바꾼 뒤에는 이 Secret을 지워도 됨)"
    echo ""
fi

echo ""
echo "  서비스 배포: 서비스 CI가 *-deploy OCI 아티팩트를 발행하고, 서비스별 Application이 동기화합니다."
echo "    k8s/_template/service → k8s/services/<service> 복사 후 ./k8s/deploy.sh (docs/argocd.md)"

echo ""
kubectl get pods -n traefik 2>/dev/null
echo ""
if [ "$INSTALL_GITLAB" = "true" ]; then
    kubectl get pods -n gitlab 2>/dev/null
    echo ""
fi
kubectl get pods -n argocd 2>/dev/null

echo ""
echo "  ┌──────────────────────────────────────────────┐"
echo "  │  호스트                                        │"
echo "  │  ├─ PostgreSQL 18  localhost:5432            │"
echo "  │  ├─ Valkey         localhost:6379            │"
echo "  │  └─ RustFS (S3)    localhost:9000            │"
echo "  │                                              │"
echo "  │  K8s                                         │"
echo "  │  ├─ Traefik   https://${TS_HOSTNAME}"
if [ "$INSTALL_GITLAB" = "true" ]; then
echo "  │  ├─ GitLab    https://${GITLAB_HOST}"
fi
echo "  │  └─ Argo CD   https://${TS_HOSTNAME}/argocd"
echo "  └──────────────────────────────────────────────┘"
echo ""
