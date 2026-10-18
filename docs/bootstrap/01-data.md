# 호스트 데이터 레이어

호스트에 네이티브로 설치하는 컴포넌트들. K8s와 독립적으로 운영된다.

**비밀번호 없이 운영한다.** PostgreSQL과 RustFS는 `127.0.0.1`에만 리슨하고, PostgreSQL은 Homebrew 기본
`pg_hba.conf`(로컬 trust), RustFS는 고정 기본 자격증명(`rustfsadmin`)을 쓴다. 별도 시크릿 저장소는 없다.
LAN에는 열리지 않지만, 이 Mac의 로컬 프로세스와 OrbStack 컨테이너·파드는 인증 없이 접근할 수 있다.

## 실행

```bash
# GitLab 제외 (기본값)
./bootstrap/01-data.sh

# GitLab용 리소스 포함
INSTALL_GITLAB=true ./bootstrap/01-data.sh
```

`INSTALL_GITLAB=true`일 때만 GitLab용 리소스(PostgreSQL `gitlab` 유저/DB, RustFS `gitlab-*` 버킷)를 만든다.
나중에 GitLab을 켜려면 `INSTALL_GITLAB=true`로 다시 실행하면 된다 (`gitlab` 유저/DB와 버킷만 추가로 생성됨).

## 설치 순서

| 순서 | 컴포넌트 | 포트 | 용도 |
|:---:|---------|:----:|------|
| 1 | PostgreSQL 18 | 5432 | 서비스 DB (+ GitLab DB) |
| 2 | Valkey | 6379 | 캐시, 큐, 세션 |
| 3 | RustFS | 9000 (S3), 9001 (콘솔) | S3 호환 오브젝트 스토리지 |
| 4 | TLS 인증서 | — | Tailscale cert 발급 |

## 1. PostgreSQL 18

```bash
brew install postgresql@18
brew services start postgresql@18
```

기본 설정 그대로 `localhost`에만 리슨하고, Homebrew가 만든 `pg_hba.conf`(로컬·`127.0.0.1` trust)를 그대로 쓴다.
관리는 macOS 계정으로 로컬 접속한다 (`psql -d postgres`). 별도 관리용 유저나 비밀번호는 만들지 않는다.

`INSTALL_GITLAB=true`이면 비밀번호 없는 `gitlab` 유저(LOGIN, CREATEDB)와 `gitlab` DB를 만든다.
GitLab 파드는 `host.docker.internal:5432`로 접속하며, 이 연결은 Mac localhost로 들어와 trust로 인증된다.

**확장 모듈:** `pg_trgm`, `btree_gist` (GitLab DB, `INSTALL_GITLAB=true`일 때)

**max_connections:** GitLab이 커넥션을 많이 쓰므로 1000으로 올린다.

**확인:**

```bash
psql -d postgres -c "SHOW listen_addresses;"   # → localhost
psql -d postgres -c "SELECT rolname FROM pg_roles WHERE rolname = 'gitlab';"
psql -d gitlab -c "SELECT extname FROM pg_extension;"   # GitLab 사용 시
```

## 2. Valkey

Redis 호환 오픈소스 (Linux Foundation 관리).

```bash
brew install valkey
brew services start valkey
valkey-cli ping   # → PONG
```

## 3. RustFS

S3 호환 오브젝트 스토리지 ([RustFS](https://github.com/rustfs/rustfs), Apache-2.0).
GitLab 사용 시 artifacts, uploads, packages, registry, LFS, terraform state, 백업, Runner 캐시를 저장한다.

> [!NOTE]
> 이전에는 MinIO를 썼지만 업스트림 저장소가 보관(archived)되어 Homebrew `minio` 포뮬러가 deprecated 되었다.
> 기존 MinIO 데이터 이전은 [MinIO → RustFS 이전](../migrate-minio-to-rustfs.md) 참고.

**설치:** Homebrew core에 없고, 공식 tap(`rustfs/tap/rustfs`)은 항상 최신 버전으로 올라가 버전을 고정할 수 없다.
그래서 GitHub 릴리스의 `rustfs-macos-aarch64-v<버전>.zip`을 받아 SHA-256을 확인한 뒤 설치한다 (Apple Silicon만 지원).

| 항목 | 값 |
|------|----|
| 버전 | 1.0.3 (`01-data.sh`의 `RUSTFS_VERSION`, `RUSTFS_SHA256`) |
| 바이너리 | `~/.local/opt/rustfs/<버전>/rustfs` |
| 데이터 | `~/.local/share/rustfs/data` (단일 디스크) |
| 자격증명 | 고정 기본값 `rustfsadmin` / `rustfsadmin` (`RUSTFS_ACCESS_KEY`, `RUSTFS_SECRET_KEY`) |
| S3 API | `127.0.0.1:9000` (K8s에서 `http://host.docker.internal:9000`) |
| 콘솔 | `127.0.0.1:9001/rustfs/console/` |
| 리전 | `us-east-1` |
| 로그 | `~/.local/share/rustfs/rustfs.log` (JSON, 회전 없음) |
| 기동 | LaunchAgent `~/Library/LaunchAgents/local.self-iac.rustfs.plist` (RunAtLoad, KeepAlive) |

**localhost 바인딩:** S3 API와 콘솔은 `127.0.0.1`에만 리슨한다. OrbStack 컨테이너와 K8s 파드에서
`host.docker.internal`(0.250.250.254)로 접속하면 Mac의 localhost 리스너에 연결된다.
OrbStack 문서에는 Docker/K8s에 대한 명시가 없어(Linux 머신은 localhost 접속 미지원으로 명시) 이 서버에서
`127.0.0.1`에만 바인딩한 RustFS에 Docker 컨테이너와 K8s 파드로 `/health` 200을 확인했다.
OrbStack 업데이트 후 GitLab이 오브젝트 스토리지에 연결하지 못하면 이 부분부터 확인한다 ([운영](../operations.md) 트러블슈팅).

**자동 기동:** LaunchAgent는 로그인 세션에서 실행되므로 PostgreSQL/Valkey(`brew services`)와 마찬가지로
서버에 자동 로그인이 설정되어 있어야 재부팅 후 올라온다. 프로세스가 죽으면 launchd가 바로 다시 띄운다.
버전이나 옵션을 바꾸고 `01-data.sh`를 다시 실행하면 plist를 새로 쓰고 에이전트를 다시 등록한다.

**자격증명:** localhost 전용이므로 비밀번호를 생성·보관하지 않고 고정 기본값(`rustfsadmin`/`rustfsadmin`)으로
기동한다 (plist의 `--access-key`/`--secret-key`). `02-k8s.sh`도 같은 값으로 GitLab용 Secret을 만든다.
기동 후 이 값으로 서명한 요청이 200을 받는지 확인하며, 다른 키로 초기화된 이전 데이터가 있으면 중단한다.

**자동 생성되는 버킷 (`INSTALL_GITLAB=true`일 때):**

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

버킷은 별도 클라이언트 없이 `curl --aws-sigv4`로 만든다. 관리 명령은 [운영 가이드](../operations.md#rustfs-오브젝트-스토리지) 참고.

## 4. TLS 인증서

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

# RustFS
curl -s http://127.0.0.1:9000/health

# TLS
ls ~/.local/share/tailscale-certs/
```
