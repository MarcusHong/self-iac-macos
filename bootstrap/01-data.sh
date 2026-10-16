#!/bin/bash
set -uo pipefail

# ================================================
# 호스트 데이터 레이어 (01-data)
#
#   ① 사전 체크
#   ② PostgreSQL 18
#   ③ Valkey
#   ④ MinIO
#   ⑤ OpenBao
#   ⑥ Tailscale TLS 인증서
#   ⑦ 인증서 갱신 cron
#
# INSTALL_GITLAB=true 일 때만 GitLab용 리소스(PG gitlab 유저/DB,
# MinIO gitlab-* 버킷)를 만든다. 기본값: false
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
OPENBAO_VERSION="2.7.1"   # brew 설치 실패 시 바이너리 다운로드 버전
MINIO_ROOT_USER="minioadmin"
MINIO_ROOT_PASS=""
MINIO_DATA_DIR="$HOME/.local/share/minio"
MINIO_CONFIG_DIR="$HOME/.config/minio"
MINIO_ENV_FILE="$MINIO_CONFIG_DIR/env"
OPENBAO_DATA_DIR="$HOME/.local/share/openbao"
OPENBAO_CONFIG_DIR="$HOME/.config/openbao"
CERT_DIR="$HOME/.local/share/tailscale-certs"

gen_pass() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32; }

# MinIO는 기동할 때마다 같은 root 자격증명이 필요하므로 파일(0600)에 보관
write_minio_env() {
    (umask 077; printf 'MINIO_ROOT_USER=%s\nMINIO_ROOT_PASSWORD=%s\n' "$MINIO_ROOT_USER" "$MINIO_ROOT_PASS" > "$MINIO_ENV_FILE")
}

step "1/7 사전 체크"

command -v brew &>/dev/null || err "Homebrew 필요: https://brew.sh"
log "Homebrew OK"

command -v kubectl &>/dev/null || { echo "  kubectl 설치 중..."; brew install kubectl; }
log "kubectl OK"

command -v helm &>/dev/null || { echo "  Helm 설치 중..."; brew install helm; }
log "Helm OK"

command -v flux &>/dev/null || { echo "  flux CLI 설치 중..."; brew install fluxcd/tap/flux; }
log "flux CLI OK"

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

step "2/7 PostgreSQL ${PG_VERSION}"

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

PG_RESET_PASSWORDS=false

ROOT_EXISTS=$(psql -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='root';" 2>/dev/null || echo "")
GITLAB_EXISTS=""
if [ "$INSTALL_GITLAB" = "true" ]; then
    GITLAB_EXISTS=$(psql -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='gitlab';" 2>/dev/null || echo "")
fi

if [ "$ROOT_EXISTS" = "1" ] || [ "$GITLAB_EXISTS" = "1" ]; then
    echo ""
    warn "PostgreSQL 유저가 이미 존재합니다:"
    [ "$ROOT_EXISTS" = "1" ] && echo "    - root (superuser)"
    [ "$GITLAB_EXISTS" = "1" ] && echo "    - gitlab"
    echo ""
    echo "  [Y] 패스워드를 재생성하고 OpenBao에 업데이트"
    echo "  [N] 기존 패스워드 유지 (OpenBao에 이미 저장되어 있어야 함)"
    echo ""
    read -rp "  패스워드를 재생성할까요? (y/N): " RESET_PG
    case "${RESET_PG:-N}" in
        [Yy]*) PG_RESET_PASSWORDS=true ;;
        *) log "기존 패스워드 유지" ;;
    esac
fi

# 없는 유저는 새로 만들고, 재생성을 선택하면 기존 유저 패스워드도 교체
# (나중에 INSTALL_GITLAB=true로 재실행하면 gitlab 유저만 추가로 생성됨)
PG_ROOT_PASS=""
PG_GITLAB_PASS=""
if [ "$ROOT_EXISTS" != "1" ] || [ "$PG_RESET_PASSWORDS" = "true" ]; then
    PG_ROOT_PASS=$(gen_pass)
fi
if [ "$INSTALL_GITLAB" = "true" ] && { [ "$GITLAB_EXISTS" != "1" ] || [ "$PG_RESET_PASSWORDS" = "true" ]; }; then
    PG_GITLAB_PASS=$(gen_pass)
fi

if [ -n "$PG_ROOT_PASS" ]; then
    psql -d postgres << EOSQL 2>/dev/null || true
-- root 슈퍼유저
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'root') THEN
        CREATE ROLE root WITH LOGIN PASSWORD '${PG_ROOT_PASS}' SUPERUSER CREATEDB CREATEROLE;
    ELSE
        ALTER ROLE root WITH PASSWORD '${PG_ROOT_PASS}';
    END IF;
END
\$\$;
EOSQL
    log "유저 패스워드 설정: root (superuser) — OpenBao 업데이트 예정"
fi

if [ -n "$PG_GITLAB_PASS" ]; then
    psql -d postgres << EOSQL 2>/dev/null || true
-- gitlab 유저
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'gitlab') THEN
        CREATE ROLE gitlab WITH LOGIN PASSWORD '${PG_GITLAB_PASS}' CREATEDB;
    ELSE
        ALTER ROLE gitlab WITH PASSWORD '${PG_GITLAB_PASS}';
    END IF;
END
\$\$;
EOSQL
    log "유저 패스워드 설정: gitlab — OpenBao 업데이트 예정"
fi

if [ "$INSTALL_GITLAB" = "true" ]; then
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
    log "gitlab DB + 확장 모듈 준비 (owner: gitlab)"
fi

PG_DATA_DIR="$(brew --prefix)/var/postgresql@${PG_VERSION}"

if [ -f "$PG_DATA_DIR/postgresql.conf" ]; then
    PG_CONF_CHANGED=false

    if ! grep -q "^listen_addresses = '\*'" "$PG_DATA_DIR/postgresql.conf"; then
        sed -i '' "s/^#listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_DATA_DIR/postgresql.conf" 2>/dev/null || \
        echo "listen_addresses = '*'" >> "$PG_DATA_DIR/postgresql.conf"
        log "listen_addresses = '*'"
        PG_CONF_CHANGED=true
    fi

    # GitLab은 100개 이상의 커넥션을 사용하므로 여유 있게 설정
    CURRENT_MAX=$(grep -E "^max_connections" "$PG_DATA_DIR/postgresql.conf" 2>/dev/null | grep -oE '[0-9]+' || echo "100")
    if [ "$CURRENT_MAX" -lt 1000 ]; then
        sed -i '' "s/^#*max_connections = .*/max_connections = 1000/" "$PG_DATA_DIR/postgresql.conf" 2>/dev/null
        if ! grep -q "^max_connections" "$PG_DATA_DIR/postgresql.conf"; then
            echo "max_connections = 1000" >> "$PG_DATA_DIR/postgresql.conf"
        fi
        log "max_connections = 1000"
        PG_CONF_CHANGED=true
    fi

    if [ "$PG_CONF_CHANGED" = "true" ]; then
        brew services restart postgresql@${PG_VERSION}
        sleep 3
        log "PostgreSQL 재시작 (설정 변경 적용)"
    fi
fi

PG_HBA="$PG_DATA_DIR/pg_hba.conf"
if [ -f "$PG_HBA" ] && ! grep -q "# Infra" "$PG_HBA"; then
    cat >> "$PG_HBA" << EOF

# Infra — scram-sha-256 인증
host    all    root      127.0.0.1/32    scram-sha-256
host    all    root      ::1/128         scram-sha-256
host    all    root      10.0.0.0/8      scram-sha-256
host    all    root      172.16.0.0/12   scram-sha-256
host    all    root      192.168.0.0/16  scram-sha-256
host    all    root      100.64.0.0/10   scram-sha-256
host    all    gitlab    127.0.0.1/32    scram-sha-256
host    all    gitlab    ::1/128         scram-sha-256
host    all    gitlab    10.0.0.0/8      scram-sha-256
host    all    gitlab    172.16.0.0/12   scram-sha-256
host    all    gitlab    192.168.0.0/16  scram-sha-256
host    all    gitlab    100.64.0.0/10   scram-sha-256
EOF
    brew services restart postgresql@${PG_VERSION}
    sleep 2
    log "pg_hba.conf 업데이트 (scram-sha-256)"
fi

if [ -n "$PG_GITLAB_PASS" ]; then
    if PGPASSWORD="${PG_GITLAB_PASS}" psql -U gitlab -h 127.0.0.1 -d gitlab -c "SELECT 1;" &>/dev/null; then
        log "gitlab 유저 패스워드 인증 OK"
    else
        warn "gitlab 유저 인증 테스트 실패 (PostgreSQL 재시작 후 재시도 필요할 수 있음)"
    fi
fi

step "3/7 Valkey"

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

step "4/7 MinIO"

if ! command -v minio &>/dev/null; then
    echo "  MinIO 설치 중..."
    brew install minio
fi

if ! command -v mc &>/dev/null; then
    brew install minio/stable/mc
fi

mkdir -p "$MINIO_DATA_DIR" "$MINIO_CONFIG_DIR"

# 재실행(재부팅 후 등) 시 저장된 자격증명을 재사용 — 새로 생성하면 OpenBao/K8s Secret과 어긋남
if [ -f "$MINIO_ENV_FILE" ]; then
    source "$MINIO_ENV_FILE"
    MINIO_ROOT_PASS="${MINIO_ROOT_PASSWORD:-}"
fi

if curl -sf http://localhost:9000/minio/health/live &>/dev/null; then
    log "MinIO 이미 실행 중 — localhost:9000 (콘솔: 9001)"
else
    if [ -z "$MINIO_ROOT_PASS" ]; then
        if [ -d "$MINIO_DATA_DIR/.minio.sys" ]; then
            warn "기존 MinIO 데이터가 있지만 자격증명 파일이 없음 — 새 패스워드로 기동 (완료 후 02-k8s.sh 재실행 필요)"
        fi
        MINIO_ROOT_PASS=$(gen_pass)
        write_minio_env
        log "MinIO 자격증명 생성 — ${MINIO_ENV_FILE}"
    fi
    MINIO_ROOT_USER="$MINIO_ROOT_USER" \
    MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASS" \
    nohup minio server "$MINIO_DATA_DIR" \
        --address ":9000" \
        --console-address ":9001" \
        > "$MINIO_DATA_DIR/minio.log" 2>&1 &
    sleep 3
    curl -sf http://localhost:9000/minio/health/live &>/dev/null || err "MinIO 시작 실패. 로그: $MINIO_DATA_DIR/minio.log"
    log "MinIO 시작됨 — localhost:9000 (콘솔: 9001)"
fi

# GitLab 버킷은 INSTALL_GITLAB=true 이고 비밀번호를 알 때만 생성
# (자격증명 파일이 없는 이전 설치는 OpenBao 단계에서 파일을 복원)
if [ "$INSTALL_GITLAB" != "true" ]; then
    log "GitLab 버킷 건너뜀 (INSTALL_GITLAB=${INSTALL_GITLAB})"
elif [ -n "$MINIO_ROOT_PASS" ]; then
    mc alias set local http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASS" 2>/dev/null || true
    for bucket in gitlab-artifacts gitlab-uploads gitlab-packages gitlab-registry gitlab-lfs gitlab-terraform gitlab-backups gitlab-runner-cache; do
        mc mb "local/${bucket}" 2>/dev/null || true
    done
    log "MinIO 버킷 생성 완료"
else
    log "MinIO 이미 실행 중 — 자격증명 파일 없음, 버킷 생성 건너뜀"
fi

step "5/7 OpenBao"

if ! command -v bao &>/dev/null; then
    echo "  OpenBao 설치 중..."
    brew install openbao 2>/dev/null || {
        # Homebrew에 없으면 바이너리 직접 다운로드
        warn "brew 설치 실패, 바이너리 다운로드 시도..."
        ARCH=$(uname -m)
        [ "$ARCH" = "arm64" ] || ARCH="amd64"
        BAO_TMP=$(mktemp -d)
        curl -fsSL "https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}/openbao_${OPENBAO_VERSION}_darwin_${ARCH}.tar.gz" -o "$BAO_TMP/openbao.tar.gz"
        tar -xzf "$BAO_TMP/openbao.tar.gz" -C "$BAO_TMP" bao
        sudo mv "$BAO_TMP/bao" /usr/local/bin/bao
        sudo chmod +x /usr/local/bin/bao
        rm -rf "$BAO_TMP"
    }
fi

command -v bao &>/dev/null || err "OpenBao 설치 실패"
log "OpenBao 설치됨 — $(bao version)"

if [ -d "$OPENBAO_DATA_DIR/raft" ] && [ "$(ls -A "$OPENBAO_DATA_DIR/raft" 2>/dev/null)" ]; then
    echo ""
    warn "OpenBao 기존 데이터가 발견되었습니다: $OPENBAO_DATA_DIR/raft"
    if [ -f "$OPENBAO_DATA_DIR/init-keys.json" ]; then
        echo "  init-keys.json 존재 — 기존 설정 유지 가능"
    else
        warn "init-keys.json 없음 — 기존 데이터 복구 불가"
    fi
    echo ""
    echo "  [Y] 기존 데이터 삭제하고 새로 초기화"
    echo "  [N] 기존 데이터 유지하고 계속"
    echo ""
    read -rp "  기존 데이터를 삭제할까요? (y/N): " RESET_BAO
    case "${RESET_BAO:-N}" in
        [Yy]*)
            pkill -f "bao server" 2>/dev/null || true
            sleep 2
            rm -rf "$OPENBAO_DATA_DIR/raft"/*
            rm -f "$OPENBAO_DATA_DIR/init-keys.json"
            log "OpenBao 데이터 삭제 완료 — 새로 초기화합니다"
            ;;
        *)
            log "기존 데이터 유지"
            ;;
    esac
fi

mkdir -p "$OPENBAO_DATA_DIR" "$OPENBAO_CONFIG_DIR"

cat > "$OPENBAO_CONFIG_DIR/config.hcl" << EOF
ui = true

listener "tcp" {
    address     = "0.0.0.0:8200"
    tls_disable = true
}

storage "raft" {
    path    = "${OPENBAO_DATA_DIR}/raft"
    node_id = "mac-mini-1"
}

api_addr     = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"

disable_mlock = true
EOF

mkdir -p "$OPENBAO_DATA_DIR/raft"
log "OpenBao 설정 생성"

export BAO_ADDR="http://127.0.0.1:8200"

# seal-status는 sealed/unsealed 모두 200 반환
if curl -sf "$BAO_ADDR/v1/sys/seal-status" &>/dev/null; then
    log "OpenBao 이미 실행 중"
else
    nohup bao server -config="$OPENBAO_CONFIG_DIR/config.hcl" \
        > "$OPENBAO_DATA_DIR/openbao.log" 2>&1 &

    echo -n "  OpenBao 시작 대기"
    for i in $(seq 1 20); do
        if curl -sf "$BAO_ADDR/v1/sys/seal-status" &>/dev/null; then
            echo ""
            log "OpenBao 시작됨 — localhost:8200"
            break
        fi
        echo -n "."
        sleep 1
        [ "$i" -eq 20 ] && { echo ""; err "OpenBao 시작 실패. 로그: $OPENBAO_DATA_DIR/openbao.log"; }
    done
fi

INIT_STATUS=$(curl -sf "$BAO_ADDR/v1/sys/seal-status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('initialized', False))" 2>/dev/null || echo "unknown")

if [ "$INIT_STATUS" = "True" ]; then
    log "OpenBao 이미 초기화됨"

    if [ -f "$OPENBAO_DATA_DIR/init-keys.json" ]; then
        UNSEAL_KEY=$(python3 -c "import json; print(json.load(open('$OPENBAO_DATA_DIR/init-keys.json'))['unseal_keys_b64'][0])" 2>/dev/null || true)
        ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('$OPENBAO_DATA_DIR/init-keys.json'))['root_token'])" 2>/dev/null || true)

        SEALED=$(curl -sf "$BAO_ADDR/v1/sys/seal-status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed', True))" 2>/dev/null || echo "True")
        if [ "$SEALED" = "True" ]; then
            bao operator unseal "$UNSEAL_KEY" > /dev/null 2>&1
            log "OpenBao Unseal 완료"
        else
            log "OpenBao 이미 Unsealed"
        fi
    else
        warn "init-keys.json 없음. 수동 unseal 필요:"
        echo "  bao operator unseal <your-unseal-key>"
    fi
else
    echo "  OpenBao 초기화 중..."
    INIT_OUTPUT=$(bao operator init -key-shares=1 -key-threshold=1 -format=json 2>&1)

    if echo "$INIT_OUTPUT" | python3 -c "import sys,json; json.load(sys.stdin)" &>/dev/null; then
        echo "$INIT_OUTPUT" > "$OPENBAO_DATA_DIR/init-keys.json"
        chmod 600 "$OPENBAO_DATA_DIR/init-keys.json"

        UNSEAL_KEY=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['unseal_keys_b64'][0])")
        ROOT_TOKEN=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])")

        echo ""
        echo "  ┌──────────────────────────────────────────────┐"
        echo "  │  OpenBao 초기화 완료!                         │"
        echo "  │                                              │"
        echo "  │  Unseal Key: ${UNSEAL_KEY}"
        echo "  │  Root Token: ${ROOT_TOKEN}"
        echo "  │                                              │"
        echo "  │  저장: ${OPENBAO_DATA_DIR}/init-keys.json"
        echo "  │  ⚠️  반드시 별도 백업!                        │"
        echo "  └──────────────────────────────────────────────┘"
        echo ""

        bao operator unseal "$UNSEAL_KEY" > /dev/null 2>&1
        log "OpenBao Unseal 완료"
    else
        err "OpenBao 초기화 실패:
  ${INIT_OUTPUT}
  수동 초기화: bao operator init -key-shares=1 -key-threshold=1"
    fi
fi

if [ -n "${ROOT_TOKEN:-}" ]; then
    export BAO_TOKEN="$ROOT_TOKEN"

    bao secrets enable -path=infra kv-v2 2>/dev/null || true

    # PostgreSQL — 새로 설정한 패스워드만 반영 (나머지 필드는 유지)
    PG_FIELDS=()
    [ -n "$PG_ROOT_PASS" ] && PG_FIELDS+=(root_user="root" root_password="$PG_ROOT_PASS")
    [ -n "$PG_GITLAB_PASS" ] && PG_FIELDS+=(gitlab_user="gitlab" gitlab_password="$PG_GITLAB_PASS")
    if [ "${#PG_FIELDS[@]}" -gt 0 ]; then
        if bao kv get infra/postgresql &>/dev/null; then
            bao kv patch infra/postgresql "${PG_FIELDS[@]}" 2>/dev/null || true
        else
            bao kv put infra/postgresql \
                host="host.docker.internal" \
                port="5432" \
                "${PG_FIELDS[@]}" 2>/dev/null || true
        fi
        log "시크릿 업데이트: infra/postgresql"
    elif bao kv get infra/postgresql &>/dev/null; then
        log "시크릿 유지: infra/postgresql (변경 없음)"
    else
        warn "infra/postgresql 시크릿 없음 — 패스워드 재생성이 필요합니다"
        echo "  스크립트를 다시 실행하고 패스워드 재생성에 Y를 선택하세요."
    fi

    if [ -n "$MINIO_ROOT_PASS" ]; then
        # 매 실행마다 같은 값이면 새 버전을 만들지 않음
        if [ "$(bao kv get -field=root_password infra/minio 2>/dev/null)" != "$MINIO_ROOT_PASS" ]; then
            bao kv put infra/minio \
                root_user="$MINIO_ROOT_USER" \
                root_password="$MINIO_ROOT_PASS" 2>/dev/null || true
        fi
    elif MINIO_ROOT_PASS=$(bao kv get -field=root_password infra/minio 2>/dev/null) && [ -n "$MINIO_ROOT_PASS" ]; then
        # 자격증명 파일 도입 이전 설치: OpenBao 값으로 파일 복원
        MINIO_ROOT_USER=$(bao kv get -field=root_user infra/minio 2>/dev/null || echo "$MINIO_ROOT_USER")
        write_minio_env
        log "MinIO 자격증명 파일 복원 (OpenBao infra/minio) — ${MINIO_ENV_FILE}"
    else
        warn "MinIO 비밀번호를 알 수 없음 — MinIO 데이터를 삭제하고 재실행하세요"
    fi

    bao kv put infra/valkey \
        host="host.docker.internal" \
        port="6379" 2>/dev/null || true

    log "시크릿 저장: infra/minio, infra/valkey"
    unset BAO_TOKEN
fi

step "6/7 Tailscale TLS 인증서"

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

step "7/7 인증서 갱신 cron"

# cron의 PATH는 /usr/bin:/bin 뿐이므로 절대경로 사용
TAILSCALE_BIN=$(command -v tailscale)
KUBECTL_BIN=$(command -v kubectl)
CRON_CMD="0 3 1 */2 * { ${TAILSCALE_BIN} cert --cert-file ${CERT_DIR}/${TS_HOSTNAME}.crt --key-file ${CERT_DIR}/${TS_HOSTNAME}.key ${TS_HOSTNAME} && ${KUBECTL_BIN} -n traefik create secret tls tailscale-tls --cert=${CERT_DIR}/${TS_HOSTNAME}.crt --key=${CERT_DIR}/${TS_HOSTNAME}.key --dry-run=client -o yaml | ${KUBECTL_BIN} apply -f -; } >> ${CERT_DIR}/renew.log 2>&1"

if crontab -l 2>/dev/null | grep -qxF "$CRON_CMD"; then
    log "cron 이미 등록됨"
else
    # 기존 항목(PATH 문제로 실패하던 이전 버전 포함)은 교체
    (crontab -l 2>/dev/null | grep -v "tailscale cert"; echo "$CRON_CMD") | crontab -
    log "인증서 갱신 cron 등록 (격월 1일 03:00, 로그: ${CERT_DIR}/renew.log)"
fi

echo ""
echo "  ┌──────────────────────────────────────────────┐"
echo "  │  호스트 데이터 레이어 완료                         │"
echo "  │                                              │"
echo "  │  PostgreSQL 18  localhost:5432               │"
echo "  │  Valkey         localhost:6379               │"
echo "  │  MinIO          localhost:9000 (콘솔:9001)    │"
echo "  │  OpenBao        localhost:8200 (UI: /ui)     │"
echo "  │                                              │"
echo "  │  TLS: ${TS_HOSTNAME}                         │"
echo "  └──────────────────────────────────────────────┘"
echo ""
echo "  OpenBao UI: http://localhost:8200/ui"
echo ""
echo "  다음: ./bootstrap/02-k8s.sh"
echo ""
