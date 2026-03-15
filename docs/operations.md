# 운영

## 접속 정보

| 서비스 | URL / 접속 방법 |
|--------|----------------|
| PostgreSQL | `psql -d postgres` |
| Valkey | `valkey-cli` |
| MinIO Console | http://localhost:9001 |
| OpenBao UI | http://localhost:8200/ui |
| GitLab | https://<tailscale-hostname> |
| Registry | `kubectl get svc gitlab-registry -n gitlab` (LoadBalancer IP:5000) |

## 백업

GitLab 백업은 **매일 04:00** 자동 실행되며 MinIO `gitlab-backups` 버킷에 저장된다.

```bash
# 수동 백업
kubectl exec -n gitlab deployment/gitlab-toolbox -- gitlab-backup create

# 백업 목록 확인
mc ls local/gitlab-backups/

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
mc du local/gitlab-registry/
```

## 서비스 재시작

```bash
# 호스트 서비스
brew services restart postgresql@18
brew services restart valkey
# MinIO는 프로세스 kill 후 재시작 필요
# OpenBao도 프로세스 kill 후 재시작 + unseal 필요

# K8s 워크로드
kubectl rollout restart deployment -n gitlab
kubectl rollout restart deployment -n traefik
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
| MinIO | root 비밀번호 분실 → 오브젝트 스토리지 접근 불가 |
| GitLab | K8s Secret의 DB/MinIO 비밀번호 불일치 → 기동 실패 |

**복구 절차:**

```bash
# 1. 호스트 서비스 전체 중지
brew services stop postgresql@18
brew services stop valkey
pkill -f minio
pkill -f "bao server"

# 2. 데이터 삭제
rm -rf ~/.local/share/openbao/raft ~/.local/share/openbao/init-keys.json
rm -rf ~/.local/share/minio

# 3. K8s 워크로드 삭제
helm uninstall gitlab -n gitlab
helm uninstall traefik -n traefik
kubectl delete ns gitlab traefik

# 4. PostgreSQL gitlab DB 재생성
brew services start postgresql@18
psql -d postgres -c "DROP DATABASE IF EXISTS gitlab;"
psql -d postgres -c "DROP ROLE IF EXISTS gitlab; DROP ROLE IF EXISTS root;"

# 5. 부트스트랩 재실행
./bootstrap/01-data.sh
./bootstrap/02-k8s.sh
```

**`init-keys.json`은 반드시 별도 백업할 것.**

## Flux GitOps 워크플로우

```bash
# infra 레포 클론
git clone https://<tailscale-hostname>/infra/infra.git
cd infra

# 매니페스트 추가/수정
vim clusters/mac-mini/my-service.yaml

# push → Flux 자동 배포
git add -A
git commit -m "feat: add my-service"
git push origin main

# 동기화 확인
flux get kustomizations
```

## SMTP (Gmail) 설정

메일 발송이 필요하면 환경변수를 설정 후 Helm upgrade를 실행한다.

```bash
export SMTP_USER="your@gmail.com"
export SMTP_PASSWORD="Google 앱 비밀번호"
./bootstrap/02-k8s.sh
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

# Flux
flux logs

# OpenBao
tail -f ~/.local/share/openbao/openbao.log

# MinIO
tail -f ~/.local/share/minio/minio.log
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

### GitLab Pod가 기동 안 됨

```bash
kubectl get pods -n gitlab
kubectl describe pod <pod-name> -n gitlab
kubectl logs <pod-name> -n gitlab
```

보통 원인: 호스트 PostgreSQL/Valkey/MinIO에 연결 실패.
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

### MinIO 시작 실패

```bash
tail -20 ~/.local/share/minio/minio.log

# 포트 충돌 확인
lsof -i :9000
```
