#!/bin/bash
set -uo pipefail

# ================================================
# k8s/ 플랫폼 매니페스트 직접 적용
#
#   AppProject(platform, apps), apps Namespace,
#   서비스별 OCI Application
#
# 이 디렉터리는 Argo CD source가 아니다.
# 변경 후에는 이 스크립트로 현재 kube context에 다시 적용한다.
# (02-k8s.sh가 Argo CD 설치 직후 호출)
# ================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

command -v kubectl &>/dev/null || err "kubectl 필요"

CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || true)
[ -n "$CURRENT_CONTEXT" ] || err "현재 kubectl context가 없습니다"

kubectl get crd applications.argoproj.io appprojects.argoproj.io &>/dev/null \
    || err "Argo CD CRD 없음 — 02-k8s.sh로 Argo CD를 먼저 설치하세요"

RENDERED="$(mktemp "${TMPDIR:-/tmp}/self-iac-k8s.XXXXXX")"
trap 'rm -f "$RENDERED"' EXIT

kubectl kustomize "$SCRIPT_DIR" > "$RENDERED" || err "k8s/ Kustomize 렌더 실패"

# 템플릿 토큰이나 채우지 않은 값이 남아 있으면 적용하지 않음
if grep -n '\${' "$RENDERED" || grep -n 'CHANGEME' "$RENDERED"; then
    err "최종 렌더에 치환되지 않은 값이 남아 있습니다 (위 줄 확인)"
fi

echo "  kubectl context: ${CURRENT_CONTEXT}"

kubectl apply --server-side --field-manager=self-iac -f "$RENDERED" || err "k8s/ 적용 실패"
log "k8s/ 매니페스트 적용 완료"

echo ""
kubectl -n argocd get appprojects,applications
