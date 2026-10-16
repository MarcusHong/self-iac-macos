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

# 로컬 OrbStack이 관리하는 orbstack 항목과 겹치지 않도록 원격은 별도 이름으로 등록
REMOTE_NAME="orbstack-remote"
REMOTE_SERVER="https://${ORBSTACK_HOST}:26443"
REMOTE_CONFIG=~/.kube/orbstack-remote-config

mkdir -p ~/.kube && chmod 700 ~/.kube

# 재등록 대응: 이전에 등록한 원격 항목 제거
kubectl config delete-context "$REMOTE_NAME" &>/dev/null || true
kubectl config delete-cluster "$REMOTE_NAME" &>/dev/null || true
kubectl config delete-user "$REMOTE_NAME" &>/dev/null || true

# 이전 버전은 원격을 orbstack 이름으로 등록했음 — 같은 서버를 가리킬 때만 제거 (로컬 OrbStack 항목은 유지)
OLD_SERVER=$(kubectl config view -o jsonpath='{.clusters[?(@.name=="orbstack")].cluster.server}' 2>/dev/null || true)
SWITCH_CONTEXT=false
if [ "$OLD_SERVER" = "$REMOTE_SERVER" ]; then
    [ "$(kubectl config current-context 2>/dev/null)" = "orbstack" ] && SWITCH_CONTEXT=true
    kubectl config delete-context orbstack &>/dev/null || true
    kubectl config delete-cluster orbstack &>/dev/null || true
    kubectl config delete-user orbstack &>/dev/null || true
    warn "이전 버전이 orbstack 이름으로 등록한 원격 항목 제거"
fi

(umask 077; scp "$ORBSTACK_SSH":~/.kube/config "$REMOTE_CONFIG") || err "kubeconfig 복사 실패"
log "kubeconfig 복사 완료"

# 원격 kubeconfig에서 orbstack context와 그 cluster/user만 남기고 orbstack-remote로 이름 변경
# OrbStack은 localhost용 인증서만 발급하므로 Tailscale 경유 시 TLS 검증 우회 필요
RENDERED=$(KUBECONFIG="$REMOTE_CONFIG" kubectl config view --raw -o json | python3 -c '
import json, sys
name, server = sys.argv[1], sys.argv[2]
c = json.load(sys.stdin)
ctx = next(x for x in c["contexts"] if x["name"] == "orbstack")
cl = next(x for x in c["clusters"] if x["name"] == ctx["context"]["cluster"])
us = next(x for x in c["users"] if x["name"] == ctx["context"]["user"])
cl["cluster"].pop("certificate-authority-data", None)
cl["cluster"]["server"] = server
cl["cluster"]["insecure-skip-tls-verify"] = True
cl["name"] = us["name"] = ctx["name"] = name
ctx["context"]["cluster"] = ctx["context"]["user"] = name
c.update(clusters=[cl], users=[us], contexts=[ctx])
c["current-context"] = name
json.dump(c, sys.stdout)
' "$REMOTE_NAME" "$REMOTE_SERVER") || { rm -f "$REMOTE_CONFIG"; err "원격 kubeconfig에 orbstack context가 없습니다"; }
(umask 077; printf '%s\n' "$RENDERED" > "$REMOTE_CONFIG")
log "context ${REMOTE_NAME} → ${REMOTE_SERVER}"

# 기존 config 백업 후 merge (기존 current-context 유지)
BACKUP_MSG="기존 config 없음"
if [ -f ~/.kube/config ]; then
    cp -p ~/.kube/config ~/.kube/config.bak
    BACKUP_MSG="백업: ~/.kube/config.bak"
fi
(umask 077; KUBECONFIG=~/.kube/config:"$REMOTE_CONFIG" kubectl config view --flatten > ~/.kube/config-merged) \
    || { rm -f ~/.kube/config-merged "$REMOTE_CONFIG"; err "kubeconfig merge 실패 (기존 ~/.kube/config는 그대로)"; }
mv ~/.kube/config-merged ~/.kube/config
rm -f "$REMOTE_CONFIG"
log "kubeconfig merge 완료 (${BACKUP_MSG})"

# 이전 버전의 orbstack(원격)이 current-context였다면 새 이름으로 전환
if [ "$SWITCH_CONTEXT" = "true" ]; then
    kubectl config use-context "$REMOTE_NAME" > /dev/null
    log "current-context → ${REMOTE_NAME}"
fi

kubectl --context="$REMOTE_NAME" cluster-info &>/dev/null || err "원격 OrbStack 연결 실패"
log "원격 OrbStack K8s 연결 성공 — kubectl --context=${REMOTE_NAME}"
kubectl --context="$REMOTE_NAME" get nodes
