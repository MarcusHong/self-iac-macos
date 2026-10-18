#!/bin/bash
set -uo pipefail

# ================================================
# 호스트 데이터 레이어 (01-data)
#
#   ① 사전 체크
#   ② PostgreSQL 18
#   ③ Valkey
#   ④ RustFS (S3 오브젝트 스토리지)
#   ⑤ Tailscale TLS 인증서
#   ⑥ 인증서 자동 갱신 (launchd)
#
# 비밀번호 없이 운영한다: PostgreSQL·RustFS 모두 localhost에만 리슨하고
# PostgreSQL은 로컬 trust, RustFS는 고정 기본 자격증명을 쓴다.
#
# INSTALL_GITLAB=true 일 때만 GitLab용 리소스(PG gitlab 유저/DB,
# RustFS gitlab-* 버킷)를 만든다. 기본값: false
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

# ── 설정 ──
INSTALL_GITLAB="${INSTALL_GITLAB:-false}"
PG_VERSION="18"
RUSTFS_VERSION="1.0.3"
RUSTFS_SHA256="9ec6f2ad89df88db9b8889f59e37bb27f6b67c61ee8a97968dd90aaa2ac4dd30"   # rustfs-macos-aarch64-v1.0.3.zip
RUSTFS_HOME="$HOME/.local/opt/rustfs"          # <버전>/rustfs
RUSTFS_DATA_DIR="$HOME/.local/share/rustfs"    # data/, rustfs.log
# localhost 전용이므로 비밀번호를 관리하지 않고 고정 기본 자격증명 사용 (02-k8s.sh와 같은 값)
RUSTFS_ACCESS_KEY="rustfsadmin"
RUSTFS_SECRET_KEY="rustfsadmin"
RUSTFS_PORT="9000"
RUSTFS_CONSOLE_PORT="9001"
RUSTFS_REGION="us-east-1"
RUSTFS_ENDPOINT="http://127.0.0.1:${RUSTFS_PORT}"
RUSTFS_LABEL="local.self-iac.rustfs"
RUSTFS_PLIST="$HOME/Library/LaunchAgents/${RUSTFS_LABEL}.plist"
RUSTFS_GITLAB_BUCKETS="gitlab-artifacts gitlab-uploads gitlab-packages gitlab-registry gitlab-lfs gitlab-terraform gitlab-backups gitlab-tmp gitlab-runner-cache"
CERT_DIR="$HOME/.local/share/tailscale-certs"

# Apple Silicon Homebrew(/opt/homebrew)는 기본 PATH에 없음 — run.sh나 새 셸에서 실행해도 찾도록
[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"

step "1/6 사전 체크"

command -v brew &>/dev/null || err "Homebrew 필요: https://brew.sh"
log "Homebrew OK"

command -v kubectl &>/dev/null || { echo "  kubectl 설치 중..."; brew install kubectl; }
log "kubectl OK"

command -v helm &>/dev/null || { echo "  Helm 설치 중..."; brew install helm; }
log "Helm OK"

command -v argocd &>/dev/null || { echo "  Argo CD CLI 설치 중..."; brew install argocd; }
log "Argo CD CLI OK"

if [ "$INSTALL_GITLAB" = "true" ]; then
    log "GitLab 리소스 포함 (INSTALL_GITLAB=true)"
else
    log "GitLab 리소스 건너뜀 (INSTALL_GITLAB=${INSTALL_GITLAB})"
fi

if ! command -v tailscale &>/dev/null; then
    err "Tailscale 필요: https://tailscale.com/download/mac"
fi

if ! tailscale status &>/dev/null; then
    err "Tailscale이 실행 중이 아닙니다. 먼저:
  tailscale up"
fi

TS_HOSTNAME=""
TS_HOSTNAME=$(tailscale cert 2>&1 | grep -oE '[a-zA-Z0-9-]+\.[a-zA-Z0-9-]+\.ts\.net' | head -1 || true)

if [ -z "$TS_HOSTNAME" ]; then
    TS_HOSTNAME=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || true)
fi

if [ -z "$TS_HOSTNAME" ]; then
    TS_HOSTNAME=$(tailscale whois --json self 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Node',{}).get('Name','').rstrip('.'))" 2>/dev/null || true)
fi

if [ -z "$TS_HOSTNAME" ]; then
    warn "Tailscale 호스트명 자동 감지 실패"
    echo ""
    echo "  tailscale status 로 호스트명을 확인 후 입력하세요."
    echo "  예: mac-mini.tail12345.ts.net"
    echo ""
    read -rp "  Tailscale 호스트명: " TS_HOSTNAME
fi

[ -z "$TS_HOSTNAME" ] && err "Tailscale 호스트명이 필요합니다."
log "Tailscale: ${TS_HOSTNAME}"

step "2/6 PostgreSQL ${PG_VERSION}"

# keg-only 포뮬러라 psql 존재 여부가 아닌 설치 여부로 확인
if ! brew list postgresql@${PG_VERSION} &>/dev/null; then
    echo "  PostgreSQL ${PG_VERSION} 설치 중..."
    brew install postgresql@${PG_VERSION}
fi

export PATH="$(brew --prefix postgresql@${PG_VERSION})/bin:$PATH"

if ! brew services list | grep -q "postgresql@${PG_VERSION}.*started"; then
    brew services start postgresql@${PG_VERSION}
    sleep 3
fi

if ! psql -d postgres -c "SELECT version();" &>/dev/null; then
    err "PostgreSQL 연결 실패"
fi
log "PostgreSQL 실행 중 — $(psql -d postgres -tAc 'SHOW server_version;')"

# 비밀번호 없이 운영: localhost에만 리슨(기본값)하고 Homebrew 기본 pg_hba(로컬 trust)를 그대로 사용
# OrbStack 파드의 host.docker.internal 연결은 Mac localhost로 들어옴
if [ "$INSTALL_GITLAB" = "true" ]; then
    psql -v ON_ERROR_STOP=1 -d postgres > /dev/null << EOSQL || err "PostgreSQL gitlab 유저 생성 실패"
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'gitlab') THEN
        CREATE ROLE gitlab WITH LOGIN CREATEDB;
    END IF;
END
\$\$;
EOSQL
    psql -d postgres << EOSQL 2>/dev/null || true
SELECT 'CREATE DATABASE gitlab OWNER gitlab'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'gitlab');
\gexec
ALTER DATABASE gitlab OWNER TO gitlab;
\c gitlab
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gist;
GRANT ALL PRIVILEGES ON DATABASE gitlab TO gitlab;
EOSQL
    log "gitlab 유저/DB + 확장 모듈 준비 (비밀번호 없음, 로컬 trust)"
fi

PG_DATA_DIR="$(brew --prefix)/var/postgresql@${PG_VERSION}"

# GitLab은 100개 이상의 커넥션을 사용하므로 여유 있게 설정
if [ -f "$PG_DATA_DIR/postgresql.conf" ]; then
    CURRENT_MAX=$(grep -E "^max_connections" "$PG_DATA_DIR/postgresql.conf" 2>/dev/null | grep -oE '[0-9]+' || echo "100")
    if [ "$CURRENT_MAX" -lt 1000 ]; then
        sed -i '' "s/^#*max_connections = .*/max_connections = 1000/" "$PG_DATA_DIR/postgresql.conf" 2>/dev/null
        if ! grep -q "^max_connections" "$PG_DATA_DIR/postgresql.conf"; then
            echo "max_connections = 1000" >> "$PG_DATA_DIR/postgresql.conf"
        fi
        brew services restart postgresql@${PG_VERSION}
        sleep 3
        log "max_connections = 1000 (PostgreSQL 재시작)"
    fi
fi

step "3/6 Valkey"

if ! command -v valkey-server &>/dev/null; then
    echo "  Valkey 설치 중..."
    brew install valkey
fi

if ! valkey-cli ping 2>/dev/null | grep -q "PONG"; then
    brew services start valkey
    sleep 2
fi

if valkey-cli ping 2>/dev/null | grep -q "PONG"; then
    log "Valkey 실행 중 — localhost:6379"
else
    err "Valkey 시작 실패"
fi

step "4/6 RustFS"

# Homebrew core에 없고 공식 tap은 버전 고정이 안 되므로 GitHub 릴리스 바이너리를 체크섬 검증 후 설치
RUSTFS_BIN="${RUSTFS_HOME}/${RUSTFS_VERSION}/rustfs"
if [ ! -x "$RUSTFS_BIN" ]; then
    [ "$(uname -m)" = "arm64" ] || err "RustFS macOS 바이너리는 Apple Silicon(arm64)만 제공됨"
    echo "  RustFS ${RUSTFS_VERSION} 설치 중..."
    RUSTFS_TMP=$(mktemp -d)
    curl -fsSL "https://github.com/rustfs/rustfs/releases/download/${RUSTFS_VERSION}/rustfs-macos-aarch64-v${RUSTFS_VERSION}.zip" \
        -o "$RUSTFS_TMP/rustfs.zip" || err "RustFS 다운로드 실패"
    echo "${RUSTFS_SHA256}  ${RUSTFS_TMP}/rustfs.zip" | shasum -a 256 -c - > /dev/null \
        || err "RustFS 체크섬 불일치 — ${RUSTFS_TMP}/rustfs.zip 확인 (RUSTFS_SHA256)"
    unzip -q -o "$RUSTFS_TMP/rustfs.zip" rustfs -d "$RUSTFS_TMP" || err "RustFS 압축 해제 실패"
    mkdir -p "$(dirname "$RUSTFS_BIN")"
    install -m 0755 "$RUSTFS_TMP/rustfs" "$RUSTFS_BIN" || err "RustFS 설치 실패: ${RUSTFS_BIN}"
    rm -rf "$RUSTFS_TMP"
fi
RUSTFS_VER_OUT=$("$RUSTFS_BIN" --version 2>/dev/null || true)
[ "${RUSTFS_VER_OUT%%$'\n'*}" = "rustfs ${RUSTFS_VERSION}" ] || err "RustFS 버전 확인 실패: ${RUSTFS_BIN}"
log "RustFS ${RUSTFS_VERSION} 설치됨 — ${RUSTFS_BIN}"

mkdir -p "$RUSTFS_DATA_DIR/data"

# launchd LaunchAgent — 로그인 세션(자동 로그인)에서 기동되고 재부팅 후 자동 시작, 죽으면 재시작
# S3 API/콘솔은 127.0.0.1에만 바인딩: OrbStack 컨테이너·파드의 host.docker.internal은
# Mac의 localhost 리스너에도 연결됨 (이 저장소 대상 Mac에서 파드로 확인)
RUSTFS_PLIST_NEW=$(cat << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${RUSTFS_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${RUSTFS_BIN}</string>
		<string>server</string>
		<string>--address</string>
		<string>127.0.0.1:${RUSTFS_PORT}</string>
		<string>--console-enable</string>
		<string>--console-address</string>
		<string>127.0.0.1:${RUSTFS_CONSOLE_PORT}</string>
		<string>--region</string>
		<string>${RUSTFS_REGION}</string>
		<string>--access-key</string>
		<string>${RUSTFS_ACCESS_KEY}</string>
		<string>--secret-key</string>
		<string>${RUSTFS_SECRET_KEY}</string>
		<string>${RUSTFS_DATA_DIR}/data</string>
	</array>
	<key>WorkingDirectory</key>
	<string>${RUSTFS_DATA_DIR}</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>${RUSTFS_DATA_DIR}/rustfs.log</string>
	<key>StandardErrorPath</key>
	<string>${RUSTFS_DATA_DIR}/rustfs.log</string>
</dict>
</plist>
EOF
)

RUSTFS_DOMAIN="gui/$(id -u)"
mkdir -p "$(dirname "$RUSTFS_PLIST")"
if [ "$(cat "$RUSTFS_PLIST" 2>/dev/null)" != "$RUSTFS_PLIST_NEW" ]; then
    printf '%s\n' "$RUSTFS_PLIST_NEW" > "$RUSTFS_PLIST"
    log "RustFS LaunchAgent 작성 — ${RUSTFS_PLIST}"
    # 버전/옵션이 바뀌었으면 기존 에이전트를 내린 뒤(완전히 내려갈 때까지 대기) 새 설정으로 다시 등록
    if launchctl print "${RUSTFS_DOMAIN}/${RUSTFS_LABEL}" &>/dev/null; then
        launchctl bootout "${RUSTFS_DOMAIN}/${RUSTFS_LABEL}" 2>/dev/null || true
        for i in $(seq 1 10); do
            launchctl print "${RUSTFS_DOMAIN}/${RUSTFS_LABEL}" &>/dev/null || break
            sleep 1
        done
    fi
fi
if ! launchctl print "${RUSTFS_DOMAIN}/${RUSTFS_LABEL}" &>/dev/null; then
    launchctl bootstrap "$RUSTFS_DOMAIN" "$RUSTFS_PLIST" \
        || err "RustFS LaunchAgent 등록 실패 — GUI 로그인 세션(자동 로그인)이 있어야 합니다: launchctl bootstrap ${RUSTFS_DOMAIN} ${RUSTFS_PLIST}"
elif ! curl -sf "${RUSTFS_ENDPOINT}/health" &>/dev/null; then
    # 응답이 없으면 재시작
    launchctl kickstart -k "${RUSTFS_DOMAIN}/${RUSTFS_LABEL}" || err "RustFS 재시작 실패"
fi

echo -n "  RustFS 응답 대기"
for i in $(seq 1 30); do
    if curl -sf "${RUSTFS_ENDPOINT}/health" &>/dev/null; then
        echo ""
        break
    fi
    echo -n "."
    sleep 1
    [ "$i" -eq 30 ] && { echo ""; err "RustFS 시작 실패. 로그: ${RUSTFS_DATA_DIR}/rustfs.log"; }
done

# 파일의 자격증명이 실제 서버와 맞는지 확인 (서명 요청이 403이면 다른 키로 기동된 것)
# 자격증명은 curl 설정을 stdin으로 넘겨 프로세스 목록에 노출되지 않게 함
rustfs_s3() {
    printf 'user = "%s:%s"\n' "$RUSTFS_ACCESS_KEY" "$RUSTFS_SECRET_KEY" \
        | curl -s -K - --aws-sigv4 "aws:amz:${RUSTFS_REGION}:s3" -o /dev/null -w '%{http_code}' "$@"
}
RUSTFS_AUTH_CODE=$(rustfs_s3 "${RUSTFS_ENDPOINT}/")
[ "$RUSTFS_AUTH_CODE" = "200" ] || err "RustFS 인증 확인 실패 (HTTP ${RUSTFS_AUTH_CODE}) — 기본 자격증명(rustfsadmin)과 서버가 다름 — 이전 데이터가 다른 키로 초기화됐는지 확인"
log "RustFS 실행 중 — 127.0.0.1:${RUSTFS_PORT} (콘솔: 127.0.0.1:${RUSTFS_CONSOLE_PORT})"

# GitLab 버킷은 INSTALL_GITLAB=true 일 때만
if [ "$INSTALL_GITLAB" != "true" ]; then
    log "GitLab 버킷 건너뜀 (INSTALL_GITLAB=${INSTALL_GITLAB})"
else
    for bucket in $RUSTFS_GITLAB_BUCKETS; do
        [ "$(rustfs_s3 -I "${RUSTFS_ENDPOINT}/${bucket}")" = "200" ] && continue
        RUSTFS_MB_CODE=$(rustfs_s3 -X PUT "${RUSTFS_ENDPOINT}/${bucket}")
        [ "$RUSTFS_MB_CODE" = "200" ] || err "RustFS 버킷 생성 실패: ${bucket} (HTTP ${RUSTFS_MB_CODE})"
    done
    log "RustFS 버킷 준비 완료 (${RUSTFS_GITLAB_BUCKETS// /, })"
fi

if [ -d "$HOME/.local/share/minio" ]; then
    warn "이전 MinIO 데이터 발견 (~/.local/share/minio) — 이전 절차: docs/migrate-minio-to-rustfs.md"
fi

step "5/6 Tailscale TLS 인증서"

mkdir -p "$CERT_DIR"

if [ -f "$CERT_DIR/${TS_HOSTNAME}.crt" ]; then
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_DIR/${TS_HOSTNAME}.crt" 2>/dev/null | cut -d= -f2)
    log "인증서 존재 (만료: ${EXPIRY})"
else
    while true; do
        echo "  인증서 발급 시도 중..."
        CERT_ERR=$(tailscale cert \
            --cert-file "$CERT_DIR/${TS_HOSTNAME}.crt" \
            --key-file "$CERT_DIR/${TS_HOSTNAME}.key" \
            "$TS_HOSTNAME" 2>&1)

        if [ -f "$CERT_DIR/${TS_HOSTNAME}.crt" ]; then
            log "인증서 발급 완료"
            break
        fi

        echo ""
        warn "인증서 발급 실패:"
        echo "  ${CERT_ERR}"
        echo ""
        echo "  확인사항:"
        echo "    1. https://login.tailscale.com/admin/dns 접속"
        echo "    2. MagicDNS 활성화 확인"
        echo "    3. HTTPS Certificates 활성화 확인"
        echo "    4. 머신 이름에 민감 정보 없는지 확인"
        echo ""
        read -rp "  설정 완료 후 재시도? (Y/n): " RETRY
        case "${RETRY:-Y}" in
            [Nn]*) warn "TLS 인증서 건너뜀. 02-k8s.sh 실행 전에 수동 발급 필요."; break ;;
            *) echo "" ;;
        esac
    done
fi

step "6/6 인증서 자동 갱신 (launchd)"

# crontab은 수정할 때 macOS 관리 권한 창을 띄우므로 RustFS처럼 LaunchAgent 예약 실행으로 등록
# LaunchAgent 환경의 PATH에는 Homebrew 경로가 없으므로 절대경로를 스크립트에 기록
TAILSCALE_BIN=$(command -v tailscale)
KUBECTL_BIN=$(command -v kubectl)
RENEW_SCRIPT="${CERT_DIR}/renew.sh"
RENEW_LABEL="local.self-iac.cert-renew"
RENEW_PLIST="$HOME/Library/LaunchAgents/${RENEW_LABEL}.plist"
RENEW_DOMAIN="gui/$(id -u)"

cat > "$RENEW_SCRIPT" << EOF
#!/bin/bash
# 01-data.sh가 생성 — Tailscale 인증서를 갱신하고 Traefik TLS Secret을 업데이트
set -uo pipefail
echo "== \$(date '+%F %T')"
"${TAILSCALE_BIN}" cert --cert-file "${CERT_DIR}/${TS_HOSTNAME}.crt" --key-file "${CERT_DIR}/${TS_HOSTNAME}.key" "${TS_HOSTNAME}" || exit 1
"${KUBECTL_BIN}" -n traefik create secret tls tailscale-tls \\
    --cert="${CERT_DIR}/${TS_HOSTNAME}.crt" --key="${CERT_DIR}/${TS_HOSTNAME}.key" \\
    --dry-run=client -o yaml | "${KUBECTL_BIN}" apply -f -
EOF
chmod 755 "$RENEW_SCRIPT"

# 매월 1일 03:00 — 잠자기 중이었으면 깨어날 때 실행됨 (인증서 유효기간 90일)
RENEW_PLIST_NEW=$(cat << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${RENEW_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${RENEW_SCRIPT}</string>
	</array>
	<key>StartCalendarInterval</key>
	<dict>
		<key>Day</key>
		<integer>1</integer>
		<key>Hour</key>
		<integer>3</integer>
		<key>Minute</key>
		<integer>0</integer>
	</dict>
	<key>StandardOutPath</key>
	<string>${CERT_DIR}/renew.log</string>
	<key>StandardErrorPath</key>
	<string>${CERT_DIR}/renew.log</string>
</dict>
</plist>
EOF
)

mkdir -p "$(dirname "$RENEW_PLIST")"
if [ "$(cat "$RENEW_PLIST" 2>/dev/null)" != "$RENEW_PLIST_NEW" ]; then
    printf '%s\n' "$RENEW_PLIST_NEW" > "$RENEW_PLIST"
    if launchctl print "${RENEW_DOMAIN}/${RENEW_LABEL}" &>/dev/null; then
        launchctl bootout "${RENEW_DOMAIN}/${RENEW_LABEL}" 2>/dev/null || true
        for i in $(seq 1 10); do
            launchctl print "${RENEW_DOMAIN}/${RENEW_LABEL}" &>/dev/null || break
            sleep 1
        done
    fi
fi
if ! launchctl print "${RENEW_DOMAIN}/${RENEW_LABEL}" &>/dev/null; then
    launchctl bootstrap "$RENEW_DOMAIN" "$RENEW_PLIST" \
        || err "인증서 갱신 LaunchAgent 등록 실패: launchctl bootstrap ${RENEW_DOMAIN} ${RENEW_PLIST}"
fi
log "인증서 자동 갱신 등록 — 매월 1일 03:00 (${RENEW_LABEL}, 로그: ${CERT_DIR}/renew.log)"

# 이전 버전이 등록한 cron 항목은 알리기만 함 (crontab 수정은 권한 창이 뜨므로 자동으로 하지 않음)
if crontab -l 2>/dev/null | grep -q "tailscale cert"; then
    warn "이전 버전의 cron 갱신 항목이 남아 있음 — crontab -e로 'tailscale cert' 줄을 지우세요"
fi

echo ""
echo "  ┌──────────────────────────────────────────────┐"
echo "  │  호스트 데이터 레이어 완료                         │"
echo "  │                                              │"
echo "  │  PostgreSQL 18  localhost:5432               │"
echo "  │  Valkey         localhost:6379               │"
echo "  │  RustFS (S3)    localhost:9000 (콘솔:9001)    │"
echo "  │                                              │"
echo "  │  TLS: ${TS_HOSTNAME}                         │"
echo "  └──────────────────────────────────────────────┘"
echo ""
echo "  다음: ./bootstrap/02-k8s.sh"
echo ""
