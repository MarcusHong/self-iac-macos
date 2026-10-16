# MinIO → Garage 이전

Homebrew `minio` 포뮬러가 deprecated(업스트림 저장소 archived) 되어 호스트 오브젝트 스토리지를 [Garage](https://garagehq.deuxfleurs.fr/)로 바꿨다.
Garage는 MinIO 데이터 디렉터리를 읽지 못하므로 데이터는 S3 API로 복사한다.

## 바뀌는 것

| 항목 | MinIO (이전) | Garage (현재) |
|------|-------------|---------------|
| 포트 | 9000 (S3), 9001 (콘솔) | 3900 (S3), 3901 (RPC, localhost), 3903 (admin, localhost) |
| 기동 | `nohup` — 재부팅 후 `01-data.sh` 재실행 필요 | `brew services` (launchd) — 재부팅 후 자동 시작 |
| 데이터 | `~/.local/share/minio` | `~/.local/share/garage/{meta,data}` |
| 설정 | 없음 (환경변수) | `$(brew --prefix)/etc/garage/config.toml` (0600) |
| 자격증명 | root 사용자, `~/.config/minio/env` + OpenBao `infra/minio` | `gitlab` 전용 키 (Garage 메타데이터) + OpenBao `infra/garage` |
| 리전 | `us-east-1` | `garage` |
| 관리 도구 | `mc`, 웹 콘솔 | `garage` CLI (콘솔 없음) |
| K8s Secret | `gitlab-minio-secret` | `gitlab-object-storage`, `gitlab-object-storage-s3cmd` |

같이 고친 GitLab 오브젝트 스토리지 설정 (MinIO에서도 깨져 있던 부분):

| 문제 | 수정 |
|------|------|
| LFS/Terraform state가 차트 기본 버킷(`git-lfs`, `gitlab-terraform-state`)을 찾음 — 만들지 않은 버킷 | `gitlab-values.yaml`에 버킷 이름 명시, 백업 임시 버킷 `gitlab-tmp` 추가 |
| 백업이 fog 연결 YAML을 s3cmd 설정으로 읽음 | s3cmd 형식 Secret `gitlab-object-storage-s3cmd` 사용 |
| Registry(s3_v2)에 `pathstyle` 없음 → `gitlab-registry.host.docker.internal`로 요청 | `pathstyle: true` |
| 다운로드가 클러스터 밖에서 접근 불가한 `host.docker.internal`로 리다이렉트 | `proxy_download: true`, Registry `redirect.disable: true` |
| Runner 캐시 `runners.cache.s3*` 값을 차트가 무시 | `runners.config`의 `[runners.cache.s3]`로 이동 |

그래서 기존 MinIO의 `gitlab-lfs`, `gitlab-terraform`, `gitlab-backups`, `gitlab-runner-cache`는 비어 있을 수 있다.

## GitLab을 쓰지 않는 경우 (`INSTALL_GITLAB=false`)

MinIO에는 버킷이 없었다. `./bootstrap/01-data.sh`를 다시 실행해 Garage를 올리고 [MinIO 정리](#6-minio-정리)만 하면 된다.

## GitLab을 쓰는 경우

다운타임이 필요하다 (GitLab 쓰기 중지 → 복사 → 재구성). 디스크는 MinIO 데이터만큼 여유가 있어야 한다.

### 0. 사전 확인

MinIO가 9000에서 떠 있어야 한다. 재부팅 후라면 저장된 자격증명으로 띄운다.

```bash
curl -sf http://localhost:9000/minio/health/live && echo "MinIO OK"

# 떠 있지 않으면
set -a; source ~/.config/minio/env; set +a
nohup minio server ~/.local/share/minio --address :9000 --console-address :9001 \
    > ~/.local/share/minio/minio.log 2>&1 &
```

기존 자동 백업은 백업 Secret 형식 문제로 실패했을 수 있다. 이전 중에는 `~/.local/share/minio`를 지우지 않는 것이 백업이다.
DB도 따로 떠 둔다.

```bash
pg_dump gitlab > gitlab_$(date +%Y%m%d).sql
```

### 1. Garage 준비

```bash
INSTALL_GITLAB=true ./bootstrap/01-data.sh
```

- PostgreSQL 패스워드 재생성 질문에는 **N** (기존 값 유지)
- Garage 설치 → `brew services` 등록 → 단일 노드 레이아웃 → `gitlab` 키와 버킷 생성 → OpenBao `infra/garage` 저장
- MinIO는 건드리지 않는다 (9000에서 계속 동작). `이전 MinIO 데이터 발견` 경고는 정상

### 2. GitLab 쓰기 중지

```bash
kubectl -n gitlab scale deploy \
    gitlab-webservice-default gitlab-sidekiq-all-in-1-v2 gitlab-registry \
    gitlab-toolbox gitlab-gitlab-runner --replicas=0
kubectl -n gitlab get pods   # gitaly, exporter만 남으면 됨
```

04:00 백업 CronJob과 겹치면 잠시 멈춘다: `kubectl -n gitlab patch cronjob gitlab-toolbox-backup -p '{"spec":{"suspend":true}}'`

### 3. 데이터 복사 (rclone)

`mc`도 archived 되었으므로 `rclone`을 쓴다. 자격증명은 설정 파일 대신 환경변수로 넘긴다.

```bash
brew install rclone

set -a; source ~/.config/minio/env; set +a
export BAO_ADDR=http://127.0.0.1:8200
export BAO_TOKEN=$(python3 -c "import json; print(json.load(open('$HOME/.local/share/openbao/init-keys.json'))['root_token'])")

export RCLONE_CONFIG_MINIO_TYPE=s3
export RCLONE_CONFIG_MINIO_PROVIDER=Minio
export RCLONE_CONFIG_MINIO_ENDPOINT=http://127.0.0.1:9000
export RCLONE_CONFIG_MINIO_ACCESS_KEY_ID="$MINIO_ROOT_USER"
export RCLONE_CONFIG_MINIO_SECRET_ACCESS_KEY="$MINIO_ROOT_PASSWORD"

export RCLONE_CONFIG_GARAGE_TYPE=s3
export RCLONE_CONFIG_GARAGE_PROVIDER=Other
export RCLONE_CONFIG_GARAGE_ENDPOINT=http://127.0.0.1:3900
export RCLONE_CONFIG_GARAGE_REGION=garage
export RCLONE_CONFIG_GARAGE_FORCE_PATH_STYLE=true
export RCLONE_CONFIG_GARAGE_ACCESS_KEY_ID=$(bao kv get -field=gitlab_access_key infra/garage)
export RCLONE_CONFIG_GARAGE_SECRET_ACCESS_KEY=$(bao kv get -field=gitlab_secret_key infra/garage)
export RCLONE_S3_NO_CHECK_BUCKET=true   # gitlab 키는 버킷 생성 권한이 없음

# MinIO 버킷 확인 — 아래 목록에 없는 버킷이 있으면 garage bucket create/allow 후 목록에 추가
rclone lsd minio:

BUCKETS="gitlab-artifacts gitlab-uploads gitlab-packages gitlab-registry gitlab-lfs gitlab-terraform gitlab-backups gitlab-runner-cache"
for b in $BUCKETS; do
    echo "== $b"; rclone copy "minio:$b" "garage:$b" --transfers 8 --stats-one-line -P
done

# 검증 — multipart 객체는 ETag가 달라 "hashes could not be checked"로 크기만 비교됨 (정상)
for b in $BUCKETS; do
    echo "== $b"; rclone check "minio:$b" "garage:$b" --one-way
done
```

`copy`는 대상 파일을 지우지 않으므로 중간에 끊겨도 다시 실행하면 이어서 복사한다.
`gitlab-runner-cache`는 버려도 되는 캐시라 생략해도 된다.

### 4. GitLab 재구성

```bash
INSTALL_GITLAB=true ./bootstrap/02-k8s.sh
```

새 Secret(`gitlab-object-storage`, `gitlab-object-storage-s3cmd`, `gitlab-registry-storage`, `gitlab-runner-cache-secret`)을 만들고 Helm upgrade 한다.
webservice/sidekiq/registry/runner는 차트가 `replicas`를 지정하지 않아(HPA 관리) 0에서 다시 올라오지 않는다.
Helm upgrade가 끝나면(`GitLab 응답 대기`가 보이면) 다른 터미널에서 직접 올린다.
늦어도 5분 뒤 경고만 출력하고 Argo CD 단계로 넘어간다.

```bash
kubectl -n gitlab scale deploy \
    gitlab-webservice-default gitlab-sidekiq-all-in-1-v2 gitlab-registry \
    gitlab-toolbox gitlab-gitlab-runner --replicas=1
kubectl -n gitlab patch cronjob gitlab-toolbox-backup -p '{"spec":{"suspend":false}}'   # 2에서 멈췄다면
```

### 5. 확인

```bash
kubectl -n gitlab get pods

# 백업 → gitlab-backups 버킷
kubectl exec -n gitlab deployment/gitlab-toolbox -- backup-utility --skip artifacts
kubectl exec -n gitlab deployment/gitlab-toolbox -- s3cmd ls s3://gitlab-backups/
```

- 기존 이슈/MR의 첨부 이미지가 보이는지 (uploads)
- 기존 컨테이너 이미지 `docker pull` (registry)
- 새 파이프라인: 아티팩트 업로드/다운로드, 캐시 저장/복원 (artifacts, runner-cache)
- LFS 파일 push/clone (lfs)

### 6. MinIO 정리

GitLab이 며칠 정상 동작한 뒤에 한다. 그 전까지 MinIO 데이터가 롤백 수단이다.

```bash
pkill -f "minio server"
kubectl -n gitlab delete secret gitlab-minio-secret --ignore-not-found
bao kv metadata delete infra/minio

brew uninstall minio
brew uninstall minio/stable/mc && brew untap minio/stable
rm -rf ~/.local/share/minio ~/.config/minio
```

## 롤백 (6 이전에만 가능)

1. 2번처럼 GitLab 쓰기를 멈춘다.
2. 이 변경 이전 커밋의 `bootstrap/`으로 `INSTALL_GITLAB=true ./bootstrap/02-k8s.sh`를 실행해 Secret과 values를 MinIO로 되돌린다 (MinIO가 9000에서 떠 있어야 함).
3. 4번처럼 deployment를 1로 올린다.

이전 이후 Garage에만 쓰인 데이터(새 아티팩트, 업로드, 이미지)는 MinIO에 없다. 필요하면 3번의 rclone을 방향만 바꿔 `garage:` → `minio:`로 복사한다.
