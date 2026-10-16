# 호스트 데이터 레이어

호스트에 네이티브로 설치하는 컴포넌트들. K8s와 독립적으로 운영된다.

## 실행

```bash
# GitLab 제외 (기본값)
./bootstrap/01-data.sh

# GitLab용 리소스 포함
INSTALL_GITLAB=true ./bootstrap/01-data.sh
```

`INSTALL_GITLAB=true`일 때만 GitLab용 리소스(PostgreSQL `gitlab` 유저/DB, Garage `gitlab` 키와 `gitlab-*` 버킷)를 만든다.
나중에 GitLab을 켜려면 `INSTALL_GITLAB=true`로 다시 실행하면 된다 (`gitlab` 유저, 키, 버킷만 추가로 생성됨).

## 설치 순서

| 순서 | 컴포넌트 | 포트 | 용도 |
|:---:|---------|:----:|------|
| 1 | PostgreSQL 18 | 5432 | 서비스 DB (+ GitLab DB) |
| 2 | Valkey | 6379 | 캐시, 큐, 세션 |
| 3 | Garage | 3900 (S3), 3903 (admin) | S3 호환 오브젝트 스토리지 |
| 4 | OpenBao | 8200 | 시크릿 관리 |
| 5 | TLS 인증서 | — | Tailscale cert 발급 |

## 1. PostgreSQL 18

```bash
brew install postgresql@18
brew services start postgresql@18
```

관리용 유저가 자동 생성되며, `INSTALL_GITLAB=true`이면 GitLab용 데이터베이스와 유저도 만든다.

| 유저 | 역할 | 용도 | 생성 조건 |
|------|------|------|-----------|
| root | 슈퍼유저 | 관리용 | 항상 |
| gitlab | 일반 유저 (CREATEDB) | GitLab 전용 | `INSTALL_GITLAB=true` |

패스워드는 `openssl rand`로 32자 랜덤 생성되며, 자동으로 OpenBao에 저장된다.
`pg_hba.conf`는 `scram-sha-256` 인증으로 설정된다.

**확장 모듈:** `pg_trgm`, `btree_gist` (GitLab DB, `INSTALL_GITLAB=true`일 때)

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

## 3. Garage

S3 호환 오브젝트 스토리지 ([Garage](https://garagehq.deuxfleurs.fr/), AGPL-3.0).
GitLab 사용 시 artifacts, uploads, packages, registry, LFS, terraform state, 백업, Runner 캐시를 저장한다.

> [!NOTE]
> 이전에는 MinIO를 썼지만 업스트림 저장소가 보관(archived)되어 Homebrew `minio` 포뮬러가 deprecated 되었다.
> Garage는 GitLab 차트 문서가 번들 MinIO 대체재로 안내하는 스토리지다.
> 기존 MinIO 데이터 이전은 [MinIO → Garage 이전](../migrate-minio-to-garage.md) 참고.

```bash
brew install garage
brew services start garage   # launchd 등록 — 재부팅 후 자동 시작
```

**설정 파일:** `$(brew --prefix)/etc/garage/config.toml` (0600, `brew services`가 이 경로를 사용)

| 항목 | 값 |
|------|----|
| 데이터 | `~/.local/share/garage/{meta,data}` |
| S3 API | `0.0.0.0:3900` (K8s에서 `http://host.docker.internal:3900`) |
| RPC | `127.0.0.1:3901` (단일 노드라 외부 노출 없음) |
| Admin API | `127.0.0.1:3903` (`/health`) |
| 리전 | `garage` |
| 메타데이터 DB | sqlite + fsync + 6시간 자동 스냅샷 (LMDB는 비정상 종료 시 손상 위험) |
| 로그 | `$(brew --prefix)/var/log/garage.log` |

설정 파일은 처음 한 번만 만들고 재실행 시 덮어쓰지 않는다 (`rpc_secret`, `admin_token` 유지).
첫 기동 때 단일 노드 레이아웃(`replication_factor = 1`)을 적용한다.

**GitLab 키와 버킷 (`INSTALL_GITLAB=true`일 때):**

S3 키 `gitlab`을 만들고 아래 버킷에 읽기/쓰기 권한만 준다 (버킷 생성 권한 없음).
키는 Garage 메타데이터에 저장되므로 재실행해도 새로 만들지 않고, 값은 OpenBao `infra/garage`에 복사된다.

| 버킷 | 용도 |
|------|------|
| gitlab-artifacts | CI/CD 아티팩트 |
| gitlab-uploads | 파일 업로드 |
| gitlab-packages | 패키지 레지스트리 |
| gitlab-registry | 컨테이너 이미지 |
| gitlab-lfs | Git LFS |
| gitlab-terraform | Terraform state |
| gitlab-backups | GitLab 자동 백업 |
| gitlab-tmp | 백업/복원 임시 파일 |
| gitlab-runner-cache | Runner CI/CD 캐시 |

**관리:** 웹 콘솔은 없고 `garage` CLI를 쓴다.

```bash
export GARAGE_CONFIG_FILE=$(brew --prefix)/etc/garage/config.toml

garage status
garage bucket list
garage bucket info gitlab-registry
garage key info gitlab --show-secret
```

## 4. OpenBao

HashiCorp Vault 호환 오픈소스 시크릿 관리 (Linux Foundation, MPL 2.0).

```bash
brew install openbao
```

Homebrew 설치가 실패하면 GitHub 릴리스의 `openbao_<버전>_darwin_<arch>.tar.gz`(기본 2.7.1, `OPENBAO_VERSION`)를 받아 설치한다.

**초기화:** 스크립트가 자동으로 초기화하고 Unseal Key + Root Token을 발급한다.

```
~/.local/share/openbao/init-keys.json
```

**이 파일을 반드시 별도로 백업할 것.** 분실 시 OpenBao의 모든 시크릿에 접근 불가.

**자동 저장되는 시크릿:**

| 경로 | 내용 |
|------|------|
| `infra/postgresql` | root 유저 + 패스워드 (GitLab 사용 시 gitlab 유저 포함) |
| `infra/garage` | Garage S3 엔드포인트/리전 + `gitlab` 키 (GitLab 사용 시) |
| `infra/valkey` | Valkey 접속 정보 |
| `infra/argocd` | Argo CD admin 비밀번호 (`02-k8s.sh`가 저장) |
| `infra/gitlab` | GitLab root 비밀번호 (`02-k8s.sh`, GitLab 사용 시) |

**UI 접속:** http://localhost:8200/ui (Root Token으로 로그인)

**CLI 사용:**

```bash
export BAO_ADDR=http://127.0.0.1:8200
export BAO_TOKEN=$(python3 -c "import json; print(json.load(open('$HOME/.local/share/openbao/init-keys.json'))['root_token'])")

bao kv list infra/
bao kv get infra/garage
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

cron의 PATH에는 Homebrew 경로가 없으므로 `tailscale`/`kubectl`은 등록 시점의 절대경로로 기록된다.

```bash
crontab -l | grep tailscale
cat ~/.local/share/tailscale-certs/renew.log   # 갱신 로그
```

## 완료 후 상태 확인

```bash
# PostgreSQL
psql -d postgres -c "SELECT version();"

# Valkey
valkey-cli ping

# Garage
curl -s http://127.0.0.1:3903/health

# OpenBao
curl -s http://127.0.0.1:8200/v1/sys/seal-status | python3 -m json.tool

# TLS
ls ~/.local/share/tailscale-certs/
```
