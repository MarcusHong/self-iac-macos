#!/bin/bash
set -uo pipefail

# ================================================
# self-iac 전체 순차 실행
#
#   00 → Prerequisites (Xcode CLT, Homebrew, OrbStack, Tailscale)
#   01 → Data (PostgreSQL, Valkey, MinIO, OpenBao, TLS)
#   02 → K8s  (Traefik, GitLab, Flux)
# ================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}━━━ self-iac 부트스트랩 시작 ━━━${NC}"
echo ""

for script in "$SCRIPT_DIR"/[0-9][0-9]-*.sh; do
    name=$(basename "$script" .sh)
    echo -e "${CYAN}▶ ${name}${NC}"

    bash "$script"
    rc=$?
    if [ $rc -eq 0 ]; then
        echo -e "${GREEN}[✓]${NC} ${name} 완료"
    else
        echo -e "${RED}[✗]${NC} ${name} 실패 (exit ${rc})"
        exit $rc
    fi
    echo ""
done

echo -e "${GREEN}━━━ 전체 부트스트랩 완료 ━━━${NC}"
