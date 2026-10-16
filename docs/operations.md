# 운영

## 접속 정보

| 서비스 | URL / 접속 방법 |
|--------|----------------|
| PostgreSQL | `psql -d postgres` |
| Valkey | `valkey-cli` |
| Garage (S3) | http://localhost:3900 (콘솔 없음 — `garage` CLI, 아래 참고) |
| OpenBao UI | http://localhost:8200/ui (서버 localhost 전용 — 랩탑에서는 `ssh -L 8200:127.0.0.1:8200 <server>`) |
| Argo CD | https://<tailscale-hostname>/argocd |
| GitLab (선택) | https://<tailscale-hostname> |
| Registry (GitLab 사용 시) | `docker login <tailscale-hostname>:5050` (Traefik `registry` 엔트리포인트, TLS) |

## Garage (오브젝트 스토리지)

`brew services`(launchd)로 기동되므로 재부팅 후 자동으로 올라온다. 관리는 `garage` CLI로 한다.

```bash
export GARAGE_CONFIG_FILE=$(brew --prefix)/etc/garage/config.toml

garage status                          # 노드/용량
curl -s http://127.0.0.1:3903/health   # 클러스터 상태
garage bucket list
garage bucket info gitlab-artifacts    # 오브젝트 수, 용량
garage key info gitlab                 # 키 권한 (--show-secret으로 비밀 키 표시)
```

기존 MinIO 데이터 이전은 [MinIO → Garage 이전](migrate-minio-to-garage.md) 참고.

## 백업

GitLab 사용 시 백업은 **매일 04:00** 자동 실행되며 Garage `gitlab-backups` 버킷에 저장된다.
(오브젝트 데이터와 백업이 같은 Garage에 있으므로 `~/.local/share/garage`도 디스크 단위로 따로 백업할 것)

```bash
# 수동 백업
kubectl exec -n gitlab deployment/gitlab-toolbox -- backup-utility

# 백업 목록 확인 (toolbox에 s3cmd 설정이 들어 있음)
kubectl exec -n gitlab deployment/gitlab-toolbox -- s3cmd ls s3://gitlab-backups/

# PostgreSQL 별도 백업
pg_dump gitlab > gitlab_$(date +%Y%m%d).sql

# OpenBao
cp ~/.local/share/openbao/init-keys.json /safe/backup/location/
```

## Container Registry 관리

Registry GC는 **매주 일요일 05:00** 자동 실행된다.

```bash
# GC는 gitlab-values.yaml의 maintenance.gc.schedule로 자동 실행
# 수동 트리거가 필요하면 registry pod 재시작
kubectl rollout restart deployment -n gitlab -l app=registry

# Registry 용량 확인
garage -c $(brew --prefix)/etc/garage/config.toml bucket info gitlab-registry
```

## 서비스 재시작

```bash
# 호스트 서비스
brew services restart postgresql@18
brew services restart valkey
brew services restart garage
# OpenBao도 프로세스 kill 후 재시작 + unseal 필요

# K8s 워크로드
kubectl rollout restart deployment -n traefik
kubectl rollout restart deployment -n argocd
kubectl rollout restart deployment -n gitlab   # GitLab 사용 시
```

## OpenBao Unseal (재시작 후)

OpenBao는 재시작되면 자동으로 sealed 상태가 된다. 수동 unseal 필요.

```bash
export BAO_ADDR=http://127.0.0.1:8200
UNSEAL_KEY=$(python3 -c "import json; print(json.load(open('$HOME/.local/share/openbao/init-keys.json'))['unseal_keys_b64'][0])")
bao operator unseal "$UNSEAL_KEY"
```

## OpenBao 데이터 분실 시 전체 리셋

OpenBao는 모든 시크릿의 중앙 저장소다.
`init-keys.json`을 분실하거나 OpenBao 데이터를 삭제하면 아래 서비스의 비밀번호를 복구할 수 없다.

| 서비스 | 영향 |
|--------|------|
| PostgreSQL | root/gitlab 유저 비밀번호 분실 → DB 접근 불가 |
| Garage | 영향 없음 — 키는 Garage 메타데이터에 있고 `01-data.sh`가 `infra/garage`로 다시 복사 |
| GitLab | K8s Secret의 DB 비밀번호 불일치 → 기동 실패 |

**복구 절차:**

```bash
# 1. 호스트 서비스 전체 중지
brew services stop postgresql@18
brew services stop valkey
pkill -f "bao server"

# 2. 데이터 삭제
rm -rf ~/.local/share/openbao/raft ~/.local/share/openbao/init-keys.json

# 3. K8s 워크로드 삭제
helm uninstall gitlab -n gitlab   # GitLab 사용 시
helm uninstall argocd -n argocd
helm uninstall traefik -n traefik
kubectl delete ns gitlab argocd traefik

# 4. PostgreSQL gitlab DB 재생성
brew services start postgresql@18
psql -d postgres -c "DROP DATABASE IF EXISTS gitlab;"
psql -d postgres -c "DROP ROLE IF EXISTS gitlab; DROP ROLE IF EXISTS root;"

# 5. 부트스트랩 재실행 (GitLab 사용 시 INSTALL_GITLAB=true)
./bootstrap/01-data.sh
./bootstrap/02-k8s.sh
```

**`init-keys.json`은 반드시 별도 백업할 것.**

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

# OpenBao
tail -f ~/.local/share/openbao/openbao.log

# Garage
tail -f $(brew --prefix)/var/log/garage.log
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

보통 원인: 호스트 PostgreSQL/Valkey/Garage에 연결 실패.
`host.docker.internal` 해석 확인:

```bash
kubectl run test --rm -it --image=busybox -- nslookup host.docker.internal
```

### OpenBao sealed 상태

재시작 시 자동 sealed. 위의 Unseal 절차 수행.

### PostgreSQL 연결 거부

```bash
# pg_hba.conf 확인
cat $(brew --prefix)/var/postgresql@18/pg_hba.conf | grep Infra

# listen_addresses 확인
psql -d postgres -c "SHOW listen_addresses;"
# → * 이어야 함
```

### Garage 시작 실패

```bash
brew services info garage
tail -20 $(brew --prefix)/var/log/garage.log

# 포트 충돌 확인
lsof -i :3900 -i :3901 -i :3903

# 설정 파일 권한 — 다른 사용자가 읽을 수 있으면 Garage가 기동을 거부함
ls -l $(brew --prefix)/etc/garage/config.toml   # -rw------- 이어야 함
```

### GitLab 업로드/다운로드/Registry push 실패 (GitLab 사용 시)

```bash
# Pod에서 Garage S3 포트 도달 여부 (403 AccessDenied가 나오면 정상 — 인증 없는 요청이라서)
kubectl run s3test --rm -it --image=curlimages/curl -- curl -s -o /dev/null -w '%{http_code}\n' http://host.docker.internal:3900/

# 키 권한 확인 — 모든 gitlab-* 버킷에 RW가 있어야 함
garage -c $(brew --prefix)/etc/garage/config.toml key info gitlab
```
