# 운영

## 접속 정보

| 서비스 | URL / 접속 방법 |
|--------|----------------|
| PostgreSQL | `psql -d postgres` (localhost 전용, 로컬 trust — 비밀번호 없음) |
| Valkey | `valkey-cli` |
| RustFS (S3) | http://127.0.0.1:9000 (서버 localhost 전용) |
| RustFS 콘솔 | http://localhost:9001/rustfs/console/ (랩탑에서는 `ssh -L 9001:127.0.0.1:9001 <server>`, `rustfsadmin`/`rustfsadmin`으로 로그인) |
| Argo CD | https://<tailscale-hostname>:8443 (tailnet 전용, 로그인 없음) · 서버에서는 http://127.0.0.1:8080 |
| GitLab (선택) | https://<tailscale-hostname> |
| Registry (GitLab 사용 시) | `docker login <tailscale-hostname>:5050` (Traefik `registry` 엔트리포인트, TLS) |

## RustFS (오브젝트 스토리지)

LaunchAgent(`local.self-iac.rustfs`)로 기동되므로 자동 로그인된 서버에서는 재부팅 후 자동으로 올라오고,
프로세스가 죽으면 launchd가 다시 띄운다. S3 API와 콘솔은 `127.0.0.1`에만 리슨한다.

```bash
RUSTFS_JOB=gui/$(id -u)/local.self-iac.rustfs

launchctl print $RUSTFS_JOB | grep -E 'state|pid'   # 상태
launchctl kickstart -k $RUSTFS_JOB                    # 재시작
curl -s http://127.0.0.1:9000/health                  # 헬스 체크
tail -f ~/.local/share/rustfs/rustfs.log              # 로그 (JSON)
```

버킷 조회는 aws CLI를 쓴다 (`brew install awscli`, 선택).

```bash
export AWS_ACCESS_KEY_ID=rustfsadmin AWS_SECRET_ACCESS_KEY=rustfsadmin
export AWS_DEFAULT_REGION=us-east-1 AWS_ENDPOINT_URL=http://127.0.0.1:9000

aws s3 ls
aws s3 ls s3://gitlab-registry --recursive --summarize | tail -2   # 오브젝트 수, 용량
```

**버전 업그레이드:** `01-data.sh`의 `RUSTFS_VERSION`, `RUSTFS_SHA256`(릴리스의 `SHA256SUMS`에서
`rustfs-macos-aarch64-v<버전>.zip` 값)을 바꾸고 다시 실행하면 새 바이너리를 받아 에이전트를 다시 등록한다.

**로그:** `rustfs.log`는 회전하지 않는다. 커지면 `: > ~/.local/share/rustfs/rustfs.log`로 비운다.

기존 MinIO 데이터 이전은 [MinIO → RustFS 이전](migrate-minio-to-rustfs.md) 참고.

## 백업

GitLab 사용 시 백업은 **매일 04:00** 자동 실행되며 RustFS `gitlab-backups` 버킷에 저장된다.
(오브젝트 데이터와 백업이 같은 RustFS에 있으므로 `~/.local/share/rustfs`도 디스크 단위로 따로 백업할 것)

```bash
# 수동 백업
kubectl exec -n gitlab deployment/gitlab-toolbox -- backup-utility

# 백업 목록 확인 (toolbox에 s3cmd 설정이 들어 있음)
kubectl exec -n gitlab deployment/gitlab-toolbox -- s3cmd ls s3://gitlab-backups/

# PostgreSQL 별도 백업
pg_dump gitlab > gitlab_$(date +%Y%m%d).sql
```

## Container Registry 관리

Registry GC는 **매주 일요일 05:00** 자동 실행된다.

```bash
# GC는 gitlab-values.yaml의 maintenance.gc.schedule로 자동 실행
# 수동 트리거가 필요하면 registry pod 재시작
kubectl rollout restart deployment -n gitlab -l app=registry

# Registry 용량 확인 (위 RustFS 섹션의 aws CLI 환경변수 필요)
aws s3 ls s3://gitlab-registry --recursive --summarize | tail -2
```

## 서비스 재시작

```bash
# 호스트 서비스
brew services restart postgresql@18
brew services restart valkey
launchctl kickstart -k gui/$(id -u)/local.self-iac.rustfs

# K8s 워크로드
kubectl rollout restart deployment -n traefik
kubectl rollout restart deployment -n argocd
kubectl rollout restart deployment -n gitlab   # GitLab 사용 시
```

## 전체 리셋

호스트 서비스는 비밀번호 없이 운영하므로 복구할 시크릿이 없다. 처음부터 다시 설치하려면:

```bash
# 1. K8s 워크로드 삭제
helm uninstall gitlab -n gitlab   # GitLab 사용 시
helm uninstall argocd -n argocd
helm uninstall traefik -n traefik
kubectl delete ns gitlab argocd traefik

# 2. GitLab DB/유저 삭제 (GitLab 사용 시)
psql -d postgres -c "DROP DATABASE IF EXISTS gitlab;"
psql -d postgres -c "DROP ROLE IF EXISTS gitlab;"

# 3. RustFS 데이터 삭제 (오브젝트가 모두 지워짐)
launchctl bootout gui/$(id -u)/local.self-iac.rustfs
rm -rf ~/.local/share/rustfs/data

# 4. 부트스트랩 재실행 (GitLab 사용 시 INSTALL_GITLAB=true)
./bootstrap/01-data.sh
./bootstrap/02-k8s.sh
```

## Argo CD

플랫폼 매니페스트(`k8s/`)는 직접 적용하고, 서비스는 `*-deploy` OCI 아티팩트로 배포한다.
자세한 내용은 [Argo CD 운영](argocd.md) 참고.

```bash
# k8s/ 변경 후 다시 적용
./k8s/deploy.sh

# 새 서비스 등록
cp -R k8s/_template/service k8s/services/<service>
#   CHANGEME 채우고 k8s/services/kustomization.yaml resources에 추가
./k8s/deploy.sh

# 상태 확인
kubectl -n argocd get appprojects,applications
```

## SMTP (Gmail) 설정

GitLab 사용 시 메일 발송이 필요하면 환경변수를 설정 후 Helm upgrade를 실행한다.

```bash
export SMTP_USER="your@gmail.com"
export SMTP_PASSWORD="Google 앱 비밀번호"
INSTALL_GITLAB=true ./bootstrap/02-k8s.sh
```

메일 발송 테스트:
```bash
kubectl exec -n gitlab deployment/gitlab-toolbox -- \
  gitlab-rails runner "Notify.test_email('your@gmail.com', 'Test', 'It works!').deliver_now"
```

## 로그 확인

```bash
# GitLab
kubectl logs -f deployment/gitlab-webservice-default -n gitlab

# Traefik
kubectl logs -f deployment/traefik -n traefik

# Argo CD
kubectl logs -f deployment/argocd-server -n argocd
kubectl logs -f statefulset/argocd-application-controller -n argocd

# RustFS
tail -f ~/.local/share/rustfs/rustfs.log
```

## TLS 인증서 수동 갱신

```bash
TS_HOSTNAME="your-hostname.ts.net"
CERT_DIR="$HOME/.local/share/tailscale-certs"

tailscale cert \
  --cert-file "$CERT_DIR/${TS_HOSTNAME}.crt" \
  --key-file "$CERT_DIR/${TS_HOSTNAME}.key" \
  "$TS_HOSTNAME"

# K8s Secret 업데이트
kubectl -n traefik create secret tls tailscale-tls \
  --cert="$CERT_DIR/${TS_HOSTNAME}.crt" \
  --key="$CERT_DIR/${TS_HOSTNAME}.key" \
  --dry-run=client -o yaml | kubectl apply -f -
```

## 트러블슈팅

### Tailscale 호스트명 감지 실패

```bash
tailscale status
# 출력에서 자신의 호스트명 확인 (예: mac-mini.tail12345.ts.net)
```

### GitLab Pod가 기동 안 됨 (GitLab 사용 시)

```bash
kubectl get pods -n gitlab
kubectl describe pod <pod-name> -n gitlab
kubectl logs <pod-name> -n gitlab
```

보통 원인: 호스트 PostgreSQL/Valkey/RustFS에 연결 실패.
`host.docker.internal` 해석 확인:

```bash
kubectl run test --rm -it --image=busybox -- nslookup host.docker.internal
```

### PostgreSQL 연결 거부

```bash
# pg_hba.conf 확인 — 127.0.0.1/::1이 trust여야 함 (Homebrew 기본값)
grep -vE '^\s*(#|$)' $(brew --prefix)/var/postgresql@18/pg_hba.conf

# listen_addresses 확인 — localhost (파드는 host.docker.internal → Mac localhost로 접속)
psql -d postgres -c "SHOW listen_addresses;"
```

### RustFS 시작 실패

```bash
launchctl print gui/$(id -u)/local.self-iac.rustfs | grep -E 'state|pid|last exit'
tail -20 ~/.local/share/rustfs/rustfs.log

# 포트 충돌 확인
lsof -nP -iTCP:9000 -iTCP:9001 -sTCP:LISTEN

# 에이전트가 등록되지 않음 → GUI 로그인 세션(자동 로그인) 확인 후 01-data.sh 재실행
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.self-iac.rustfs.plist
```

`01-data.sh`가 `RustFS 인증 확인 실패 (HTTP 403)`로 멈추면 데이터가 기본 자격증명(`rustfsadmin`)이 아닌
다른 키로 초기화된 것이다. 오브젝트가 없다면 위 '전체 리셋'의 3번처럼 데이터를 지우고 다시 실행한다.

### GitLab 업로드/다운로드/Registry push 실패 (GitLab 사용 시)

RustFS는 `127.0.0.1`에만 리슨한다. OrbStack 파드의 `host.docker.internal`은 Mac localhost로 연결되지만,
OrbStack 업데이트로 이 동작이 바뀌면 파드에서 접속이 끊긴다.

```bash
# Pod에서 RustFS 도달 여부 (200이어야 함)
kubectl run s3test --rm -it --restart=Never --image=curlimages/curl -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://host.docker.internal:9000/health

# 실패하면 RustFS를 모든 인터페이스에 바인딩해 확인 (임시 — LAN에 S3 API 노출)
#   ~/Library/LaunchAgents/local.self-iac.rustfs.plist의 127.0.0.1:9000 → 0.0.0.0:9000 후
#   launchctl bootout gui/$(id -u)/local.self-iac.rustfs && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.self-iac.rustfs.plist
```
