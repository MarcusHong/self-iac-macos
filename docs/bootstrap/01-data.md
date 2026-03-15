# 호스트 데이터 레이어

호스트에 네이티브로 설치하는 컴포넌트들. K8s와 독립적으로 운영된다.

## 실행

```bash
./bootstrap/01-data.sh
```

## 설치 순서

| 순서 | 컴포넌트 | 포트 | 용도 |
|:---:|---------|:----:|------|
| 1 | PostgreSQL 18 | 5432 | GitLab DB + 서비스 DB |
| 2 | Valkey | 6379 | 캐시, 큐, 세션 |
| 3 | MinIO | 9000/9001 | GitLab 오브젝트 스토리지 |
| 4 | OpenBao | 8200 | 시크릿 관리 |
| 5 | TLS 인증서 | — | Tailscale cert 발급 |

## 1. PostgreSQL 18

```bash
brew install postgresql@18
brew services start postgresql@18
```

GitLab용 데이터베이스와 두 개의 유저가 자동 생성된다.

| 유저 | 역할 | 용도 |
|------|------|------|
| root | 슈퍼유저 | 관리용 |
| gitlab | 일반 유저 (CREATEDB) | GitLab 전용 |

패스워드는 `openssl rand`로 32자 랜덤 생성되며, 자동으로 OpenBao에 저장된다.
`pg_hba.conf`는 `scram-sha-256` 인증으로 설정된다.

**확장 모듈:** `pg_trgm`, `btree_gist` (GitLab 필수)

**네트워크:** `pg_hba.conf`에 Docker/K8s/Tailscale 대역이 추가된다.
- `10.0.0.0/8` — K8s Pod 네트워크
- `172.16.0.0/12` — Docker 네트워크
- `192.168.0.0/16` — 로컬 네트워크
- `100.64.0.0/10` — Tailscale CGNAT

**확인:**

```bash
psql -d postgres -c "SELECT rolname, rolsuper FROM pg_roles WHERE rolname IN ('root', 'gitlab');"
psql -d gitlab -c "SELECT extname FROM pg_extension;"
```

## 2. Valkey

Redis 호환 오픈소스 (Linux Foundation 관리).

```bash
brew install valkey
brew services start valkey
valkey-cli ping   # → PONG
```

## 3. MinIO

S3 호환 오브젝트 스토리지. GitLab의 artifacts, uploads, packages, registry, LFS, terraform state를 저장한다.

```bash
brew install minio
brew install minio/stable/mc
```

**자동 생성되는 버킷:**

| 버킷 | 용도 |
|------|------|
| gitlab-artifacts | CI/CD 아티팩트 |
| gitlab-uploads | 파일 업로드 |
| gitlab-packages | 패키지 레지스트리 |
| gitlab-registry | 컨테이너 이미지 |
| gitlab-lfs | Git LFS |
| gitlab-terraform | Terraform state |
| gitlab-backups | GitLab 자동 백업 |
| gitlab-runner-cache | Runner CI/CD 캐시 |

**콘솔 접속:** http://localhost:9001 (minioadmin / 설정한 비밀번호)

MinIO 비밀번호는 최초 실행 시 랜덤 생성되며 자동으로 OpenBao에 저장된다. `02-k8s.sh`가 OpenBao에서 읽어 사용한다.

## 4. OpenBao

HashiCorp Vault 호환 오픈소스 시크릿 관리 (Linux Foundation, MPL 2.0).

```bash
brew install openbao
```

**초기화:** 스크립트가 자동으로 초기화하고 Unseal Key + Root Token을 발급한다.

```
~/.local/share/openbao/init-keys.json
```

**이 파일을 반드시 별도로 백업할 것.** 분실 시 OpenBao의 모든 시크릿에 접근 불가.

**자동 저장되는 시크릿:**

| 경로 | 내용 |
|------|------|
| `infra/postgresql` | root/gitlab 유저 + 패스워드 |
| `infra/minio` | MinIO root 자격증명 |
| `infra/valkey` | Valkey 접속 정보 |

**UI 접속:** http://localhost:8200/ui (Root Token으로 로그인)

**CLI 사용:**

```bash
export BAO_ADDR=http://127.0.0.1:8200
export BAO_TOKEN=$(python3 -c "import json; print(json.load(open('$HOME/.local/share/openbao/init-keys.json'))['root_token'])")

bao kv list infra/
bao kv get infra/minio
```

## 5. TLS 인증서

Tailscale의 `tailscale cert` 명령으로 Let's Encrypt 정식 인증서를 발급받는다.
발급 실패 시 Tailscale Admin Console 설정 안내와 함께 재시도 프롬프트가 나타난다.
설정을 완료한 뒤 Y를 누르면 재시도하고, N을 누르면 건너뛸 수 있다 (02-k8s.sh 실행 전에 수동 발급 필요).

```
~/.local/share/tailscale-certs/<hostname>.crt
~/.local/share/tailscale-certs/<hostname>.key
```

**갱신 cron:** 격월 1일 03:00에 자동 갱신 + K8s Secret 업데이트

```bash
crontab -l | grep tailscale
```

## 완료 후 상태 확인

```bash
# PostgreSQL
psql -d postgres -c "SELECT version();"

# Valkey
valkey-cli ping

# MinIO
curl -s http://localhost:9000/minio/health/live

# OpenBao
curl -s http://127.0.0.1:8200/v1/sys/seal-status | python3 -m json.tool

# TLS
ls ~/.local/share/tailscale-certs/
```
