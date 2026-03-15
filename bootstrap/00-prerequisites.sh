#!/bin/bash
set -uo pipefail

# ================================================
# Prerequisites — 서버 사전 요구사항 설치
#
# OrbStack이 설치될 서버에서 실행한다.
#
#   ⓪ macOS 서버 설정 (SSH, 잠자기 방지, 전원 복구)
#   ① Xcode Command Line Tools (Git 포함)
#   ② Homebrew
#   ③ OrbStack (K8s)
#   ④ Tailscale
#
# 수동 설정이 필요한 항목:
#   - 자동 로그인: 시스템 설정 → 사용자 및 그룹
#   - Tailscale Admin Console: MagicDNS + HTTPS Certificates 활성화
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

# ── ⓪ macOS 서버 설정 ──
step "macOS 서버 설정"

REMOTE_LOGIN=$(sudo systemsetup -getremotelogin 2>/dev/null | grep -c "On" || echo "0")
if [ "$REMOTE_LOGIN" = "0" ]; then
  warn "원격 로그인 활성화"
  sudo systemsetup -setremotelogin on
fi
log "원격 로그인 (SSH) 활성화됨"

SLEEP_VAL=$(pmset -g | grep -E "^\s+sleep\s+" | awk '{print $2}')
if [ "${SLEEP_VAL:-1}" != "0" ]; then
  warn "잠자기 방지 설정"
  sudo pmset -a sleep 0 displaysleep 0 disksleep 0
fi
log "잠자기 방지 설정됨"

AUTORESTART=$(pmset -g | grep -c "autorestart.*1" || echo "0")
if [ "$AUTORESTART" = "0" ]; then
  sudo pmset -a autorestart 1
fi
log "전원 복구 시 자동 시작 설정됨"

mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo ""
read -rp "  원격 접속용 SSH 공개키를 등록할까요? (Y/n): " SETUP_SSH_KEY
case "${SETUP_SSH_KEY:-Y}" in
  [Nn]*) ;;
  *)
    echo ""
    echo "  랩탑에서 공개키를 복사하세요:"
    echo "    cat ~/.ssh/id_ed25519.pub"
    echo ""
    read -rp "  공개키 붙여넣기: " SSH_PUB_KEY
    if [ -n "$SSH_PUB_KEY" ]; then
      if grep -qF "$SSH_PUB_KEY" ~/.ssh/authorized_keys 2>/dev/null; then
        log "이미 등록된 키"
      else
        echo "$SSH_PUB_KEY" >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        log "SSH 공개키 등록 완료"
      fi
    else
      warn "공개키가 비어있음 — 건너뜀"
    fi
    ;;
esac

echo ""
echo "  아래 항목은 수동으로 설정해주세요:"
echo ""
echo "  1. 자동 로그인"
echo "     → 시스템 설정 → 사용자 및 그룹 → 자동 로그인"
echo "     (FileVault 활성화 시 자동 로그인 불가)"
echo ""

# ── ① Xcode Command Line Tools ──
step "Xcode Command Line Tools"

if xcode-select -p &>/dev/null; then
  log "이미 설치됨: $(xcode-select -p)"
else
  warn "설치 시작 (시스템 팝업이 뜰 수 있음)"
  xcode-select --install 2>/dev/null
  echo "설치 팝업에서 [Install]을 클릭하세요."
  echo -n "설치 완료 후 Enter를 눌러주세요... "
  read -r
  xcode-select -p &>/dev/null || err "Xcode CLT 설치 실패"
  log "설치 완료"
fi

git --version &>/dev/null || err "git을 찾을 수 없음"
log "Git: $(git --version)"

# ── ② Homebrew ──
step "Homebrew"

if command -v brew &>/dev/null; then
  log "이미 설치됨: $(brew --version | head -1)"
else
  warn "설치 시작"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Apple Silicon 경로 추가
  if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi

  command -v brew &>/dev/null || err "Homebrew 설치 실패"
  log "설치 완료: $(brew --version | head -1)"
fi

# ── ③ OrbStack (K8s) ──
step "OrbStack (K8s)"

if ! command -v orbctl &>/dev/null; then
  warn "설치 시작"
  brew install orbstack || err "OrbStack 설치 실패"
  log "설치 완료"
else
  log "이미 설치됨"
fi

if ! pgrep -q OrbStack; then
  warn "OrbStack 실행 중이 아님 — 실행합니다"
  open -a OrbStack
  echo -n "OrbStack이 실행될 때까지 대기 중... "
  for _ in $(seq 1 30); do
    pgrep -q OrbStack && break
    sleep 1
  done
  if pgrep -q OrbStack; then
    echo "OK"
  else
    err "OrbStack 실행 실패"
  fi
fi

if kubectl cluster-info &>/dev/null; then
  log "K8s 활성화됨"
  kubectl get nodes
else
  warn "K8s가 활성화되지 않음"
  echo ""
  echo "  OrbStack → Settings → Kubernetes → Enable Kubernetes 체크"
  echo ""
  echo -n "활성화 후 Enter를 눌러주세요... "
  read -r
  kubectl cluster-info &>/dev/null || err "K8s 활성화 확인 실패"
  log "K8s 활성화 확인 완료"
fi

# ── ④ Tailscale ──
step "Tailscale"

if command -v tailscale &>/dev/null; then
  log "이미 설치됨"
else
  warn "설치 시작"
  brew install tailscale || err "Tailscale 설치 실패"
  log "설치 완료"
fi

if tailscale status &>/dev/null; then
  TS_HOSTNAME=$(tailscale status --json | python3 -c "import sys,json; print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))" 2>/dev/null)
  log "로그인됨: ${TS_HOSTNAME:-unknown}"
else
  warn "로그인 필요"
  tailscale login
  echo -n "브라우저에서 인증 후 Enter를 눌러주세요... "
  read -r
  tailscale status &>/dev/null || err "Tailscale 로그인 실패"
  log "로그인 완료"
fi

# ── 수동 설정 안내 ──
step "수동 설정 확인"

echo ""
echo "  아래 항목은 수동으로 확인해주세요:"
echo ""
echo "  1. Tailscale Admin Console (https://login.tailscale.com/admin/dns)"
echo "     → MagicDNS 활성화"
echo "     → HTTPS Certificates 활성화"
echo ""

# ── 완료 ──
step "사전 요구사항 설치 완료"

echo ""
echo "  Git:       $(git --version)"
echo "  Homebrew:  $(brew --version | head -1)"
echo "  OrbStack:  $(orbctl version 2>/dev/null || echo 'installed')"
echo "  Tailscale: $(tailscale version 2>/dev/null | head -1 || echo 'installed')"
echo "  K8s:       $(kubectl version --client -o json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['clientVersion']['gitVersion'])" 2>/dev/null || echo 'available')"
echo ""
echo "  다음 단계:"
echo "    서버: ./bootstrap/01-data.sh"
echo "    랩탑: ./bootstrap/client.sh (원격 접근 시)"
echo ""
