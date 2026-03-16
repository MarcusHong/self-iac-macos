#!/bin/bash
set -uo pipefail

# ================================================
# Client — 원격 OrbStack K8s 접근 설정
#
# 작업 머신(랩탑)에서 실행하여 원격 OrbStack K8s에
# kubectl로 접근할 수 있도록 kubeconfig를 구성한다.
#
# 사전 조건:
#   - 서버에서 00-prerequisites.sh 실행 완료
#   - 서버와 Tailscale로 연결
#   - 서버에 SSH 접속 가능
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

# ── 1. 연결 정보 ──
step "원격 OrbStack 접근 설정"

read -rp "  SSH 접속 정보 (예: user@hostname): " ORBSTACK_SSH
[ -z "$ORBSTACK_SSH" ] && err "SSH 접속 정보 필요"

ORBSTACK_HOST="${ORBSTACK_SSH#*@}"

ssh -o ConnectTimeout=5 "$ORBSTACK_SSH" "true" 2>/dev/null || err "SSH 연결 실패: $ORBSTACK_SSH"
log "SSH 연결 OK"

# ── 2. kubeconfig 구성 ──
step "kubeconfig 구성"

# 기존 orbstack context 제거 (재등록 대응)
kubectl config delete-context orbstack 2>/dev/null || true
kubectl config delete-cluster orbstack 2>/dev/null || true
kubectl config delete-user orbstack 2>/dev/null || true

scp "$ORBSTACK_SSH":~/.kube/config ~/.kube/orbstack-config || err "kubeconfig 복사 실패"
log "kubeconfig 복사 완료"

# 원격 kubeconfig에서 orbstack context만 추출 (다른 context가 로컬을 덮어쓰지 않도록)
KUBECONFIG=~/.kube/orbstack-config kubectl config get-contexts -o name | while read -r ctx; do
    [ "$ctx" = "orbstack" ] || KUBECONFIG=~/.kube/orbstack-config kubectl config delete-context "$ctx" 2>/dev/null || true
done

# OrbStack은 localhost용 인증서만 발급하므로 Tailscale 경유 시 TLS 검증 우회 필요
sed -i '' '/certificate-authority-data:/d' ~/.kube/orbstack-config
# server 주소 변경 + insecure-skip-tls-verify 추가
KUBECONFIG=~/.kube/orbstack-config kubectl config set-cluster orbstack \
    --server="https://${ORBSTACK_HOST}:26443" \
    --insecure-skip-tls-verify=true || err "kubeconfig 수정 실패"
log "server → https://${ORBSTACK_HOST}:26443"

# 기존 config 백업 후 merge
cp ~/.kube/config ~/.kube/config.bak
KUBECONFIG=~/.kube/config:~/.kube/orbstack-config \
  kubectl config view --flatten > ~/.kube/config-merged || { mv ~/.kube/config.bak ~/.kube/config; err "kubeconfig merge 실패"; }
mv ~/.kube/config-merged ~/.kube/config
rm -f ~/.kube/orbstack-config
log "kubeconfig merge 완료 (백업: ~/.kube/config.bak)"

kubectl --context=orbstack cluster-info &>/dev/null || err "원격 OrbStack 연결 실패"
log "원격 OrbStack K8s 연결 성공"
kubectl --context=orbstack get nodes
