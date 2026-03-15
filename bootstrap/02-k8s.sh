#!/bin/bash
set -uo pipefail

# ================================================
# K8s 워크로드 (02-k8s)
#
#   ① Traefik (TLS 종단)
#   ② GitLab CE (Helm)
#   ③ Flux 부트스트랩
#
# 01-data.sh가 실행 중이어야 함
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

CERT_DIR="$HOME/.local/share/tailscale-certs"
OPENBAO_DATA_DIR="$HOME/.local/share/openbao"

FLUX_OWNER="infra"
FLUX_REPO="infra"
FLUX_BRANCH="main"
FLUX_PATH="clusters/mac-mini"

step "1/4 사전 체크"

for cmd in kubectl helm flux; do
    command -v "$cmd" &>/dev/null || err "$cmd 필요"
done

if ! kubectl cluster-info &>/dev/null; then
    err "K8s 클러스터 연결 실패 (OrbStack K8s 활성화 확인)"
fi
log "K8s OK"

psql -d postgres -c "SELECT 1;" &>/dev/null || err "PostgreSQL 미실행 (01-data.sh 먼저)"
valkey-cli ping 2>/dev/null | grep -q "PONG" || err "Valkey 미실행"
curl -sf http://localhost:9000/minio/health/live &>/dev/null || err "MinIO 미실행"
curl -sf http://127.0.0.1:8200/v1/sys/seal-status &>/dev/null || err "OpenBao 미실행"
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

export BAO_ADDR="http://127.0.0.1:8200"
if [ -f "$OPENBAO_DATA_DIR/init-keys.json" ]; then
    ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('$OPENBAO_DATA_DIR/init-keys.json'))['root_token'])" 2>/dev/null || true)
    export BAO_TOKEN="${ROOT_TOKEN:-}"
fi

MINIO_USER=""
MINIO_PASS=""
PG_GITLAB_PASS=""
if [ -n "${BAO_TOKEN:-}" ]; then
    MINIO_USER=$(bao kv get -field=root_user infra/minio 2>/dev/null || echo "minioadmin")
    MINIO_PASS=$(bao kv get -field=root_password infra/minio 2>/dev/null || echo "")
    PG_GITLAB_PASS=$(bao kv get -field=gitlab_password infra/postgresql 2>/dev/null || echo "")
    log "OpenBao에서 시크릿 로드 (minio, postgresql)"
else
    err "OpenBao 토큰 없음 — 01-data.sh를 먼저 실행하세요"
fi

step "2/4 Traefik"

kubectl create namespace traefik 2>/dev/null || true

kubectl create secret tls tailscale-tls \
    --namespace traefik \
    --cert="$CERT_DIR/${TS_HOSTNAME}.crt" \
    --key="$CERT_DIR/${TS_HOSTNAME}.key" \
    --dry-run=client -o yaml | kubectl apply -f -
log "TLS Secret 등록"

helm upgrade --install traefik oci://ghcr.io/traefik/helm/traefik \
    --namespace traefik \
    -f "$SCRIPT_DIR/traefik-values.yaml" \
    --wait --timeout 3m || err "Traefik 설치 실패"

log "Traefik 완료 (HTTPS: 443)"

step "3/4 GitLab CE"

kubectl create namespace gitlab 2>/dev/null || true

kubectl create secret generic gitlab-postgres-secret \
    --namespace gitlab \
    --from-literal=password="${PG_GITLAB_PASS}" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic gitlab-minio-secret \
    --namespace gitlab \
    --from-literal=connection="$(cat << EOF
provider: AWS
endpoint: http://host.docker.internal:9000
aws_access_key_id: ${MINIO_USER}
aws_secret_access_key: ${MINIO_PASS}
region: us-east-1
path_style: true
EOF
)" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic gitlab-registry-storage \
    --namespace gitlab \
    --from-literal=config="$(cat << EOF
s3:
  bucket: gitlab-registry
  accesskey: ${MINIO_USER}
  secretkey: ${MINIO_PASS}
  regionendpoint: http://host.docker.internal:9000
  region: us-east-1
  v4auth: true
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
    --from-literal=accesskey="${MINIO_USER}" \
    --from-literal=secretkey="${MINIO_PASS}" \
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

if [ -n "${BAO_TOKEN:-}" ]; then
    bao kv put infra/gitlab root_password="$GITLAB_ROOT_PW" 2>/dev/null || true
    log "GitLab 비밀번호 → OpenBao 저장"
fi

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

step "4/4 Flux 부트스트랩"

if [ -z "${GITLAB_TOKEN:-}" ]; then
    echo ""
    echo "  GitLab Personal Access Token이 필요합니다."
    echo "  https://${GITLAB_HOST} → User Settings → Access Tokens"
    echo "  Scopes: api, read_repository, write_repository"
    echo ""
    read -rp "  토큰 입력: " GITLAB_TOKEN
    export GITLAB_TOKEN
fi

[ -z "$GITLAB_TOKEN" ] && err "GITLAB_TOKEN 필요"

if [ -n "${BAO_TOKEN:-}" ]; then
    bao kv patch infra/gitlab pat="$GITLAB_TOKEN" 2>/dev/null || bao kv put infra/gitlab pat="$GITLAB_TOKEN" 2>/dev/null || true
    log "GitLab PAT → OpenBao 저장"
fi

flux check --pre || err "Flux 사전 체크 실패"

flux bootstrap gitlab \
    --hostname="$GITLAB_HOST" \
    --owner="$FLUX_OWNER" \
    --repository="$FLUX_REPO" \
    --branch="$FLUX_BRANCH" \
    --path="$FLUX_PATH" \
    --token-auth \
    --personal || err "Flux 부트스트랩 실패"

log "Flux 부트스트랩 완료!"

echo ""
kubectl get pods -n traefik 2>/dev/null
echo ""
kubectl get pods -n gitlab 2>/dev/null
echo ""
kubectl get pods -n flux-system 2>/dev/null

echo ""
echo "  ┌──────────────────────────────────────────────┐"
echo "  │  호스트                                        │"
echo "  │  ├─ PostgreSQL 18  localhost:5432            │"
echo "  │  ├─ Valkey         localhost:6379            │"
echo "  │  ├─ MinIO          localhost:9000            │"
echo "  │  └─ OpenBao        localhost:8200/ui         │"
echo "  │                                              │"
echo "  │  K8s                                         │"
echo "  │  ├─ Traefik   https://${TS_HOSTNAME}         |"
echo "  │  ├─ GitLab    https://${GITLAB_HOST}         |"
echo "  │  └─ Flux      → ${FLUX_OWNER}/${FLUX_REPO}   |"
echo "  └──────────────────────────────────────────────┘"
echo ""
