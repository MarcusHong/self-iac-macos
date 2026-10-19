# Argo CD 운영

builders-starter-iac와 같은 구성을 따른다. IaC 저장소(이 저장소)와 `k8s/`는 Argo CD source가 아니며,
플랫폼 매니페스트는 운영자가 대상 kube context에 직접 적용한다. Argo CD가 동기화하는 대상은
직접 등록한 Helm 컴포넌트 Application과 서비스별 배포 OCI Application이다.

## 관리 경계

| 대상 | 등록 방식 | Argo CD 역할 |
|---|---|---|
| Argo CD 자체 | `02-k8s.sh`가 Helm으로 설치 (`bootstrap/argocd-values.yaml`) | — |
| Traefik, GitLab (선택) | `02-k8s.sh`가 Helm으로 설치 | 관리하지 않음 |
| `k8s/`의 raw 리소스 (Namespace, AppProject, Ingress) | `./k8s/deploy.sh`로 직접 적용 | 관리하지 않음 |
| 플랫폼 Helm 컴포넌트 (Operator·모니터링, 향후) | `k8s/`에 Application CR을 추가해 직접 적용 | 공개 Helm source를 `prune`·`selfHeal` |
| 서비스 | `k8s/services/<service>`에 repository Secret + Application | `*-deploy` OCI를 `prune`·`selfHeal` |
| Paperclip | `k8s/paperclip` raw 매니페스트를 `./k8s/deploy.sh`로 직접 적용 | 관리하지 않음 |

- **AppProject**: `platform`은 `monitoring`, `operators`, `kube-system`만, `apps`는 `apps` namespace만 허용한다.
- **apps 제한**: `apps`는 NetworkPolicy, namespaced SecretStore와 generator 리소스를 허용하지 않는다.
- **IaC source 미등록**: 이 저장소용 Git/OCI repository Secret이나 root Application을 만들지 않는다.
- **선택 컴포넌트**: ApplicationSet controller는 replica 0, Dex는 설치하지 않는다.
  Notifications controller는 활성화하지만 notifier와 구독은 별도 설정이다.
- **인증 없음**: 익명 사용자가 admin 권한을 가지며 admin 계정은 꺼져 있다.
- **tailnet 전용**: Ingress가 없고, `127.0.0.1:8080` port-forward를 Tailscale Serve가 tailnet에만 `https://<tailscale-hostname>:8443`으로 제공한다. LAN에는 열리지 않으며, tailnet의 모든 기기가 admin 권한을 가진다.

## 플랫폼 매니페스트 직접 적용

```bash
kubectl config current-context
kubectl kustomize k8s >/dev/null
./k8s/deploy.sh
```

`deploy.sh`는 렌더 결과의 `${TS_HOSTNAME}`을 치환하고, 치환되지 않은 `${...}` 또는 `CHANGEME`가 남아 있으면
중단한다. Tailscale 호스트명은 `~/.local/share/tailscale-certs/*.crt`에서 찾으며 `TS_HOSTNAME=<host>.ts.net`으로
지정할 수도 있다.

직접 적용 리소스에는 prune이 없다. `k8s/`에서 파일을 지운 리소스는 영향을 확인한 뒤 명시적으로 삭제한다.

## 서비스 OCI 배포

서비스 빌드 시스템(GitLab CI 등)이 렌더링한 Kubernetes 매니페스트를 OCI 아티팩트로 발행하고,
서비스별 Application이 이를 동기화한다.

| 항목 | 규칙 |
|---|---|
| 서비스 이미지 저장소 | `<service>` |
| 배포 매니페스트 저장소 | `<service>-deploy` |
| Application | 서비스당 하나 (`apps-<service>`) |
| AppProject | `apps` |
| source path | `.` |
| 개발 이동 태그 | `development` |
| 운영 이동 태그 | `production` |
| 롤백 기준 | `dev-SHA7`, `vYYYY.MM.N` 또는 digest |

### 1. 서비스 등록

```bash
cp -R k8s/_template/service k8s/services/api
# k8s/services/api/*.yaml의 CHANGEME를 채운다 (repoURL/url은 oci://<registry>/<path>/api-deploy)
# k8s/services/kustomization.yaml의 resources에 - api 추가
./k8s/deploy.sh
```

서비스마다 다음 리소스가 생긴다.

| 리소스 | 역할 |
|---|---|
| `repo-<service>-deploy` Secret | `project: apps`로 scope된 OCI repository 등록 (자격증명 없음) |
| `apps-<service>` Application | `oci://...-deploy`의 `targetRevision`, `path: .` 동기화 (ServerSideApply, 무한 retry) |

### 2. private 레지스트리 pull 인증

repository Secret에는 자격증명을 넣지 않는다. private 레지스트리(GitLab Container Registry, ghcr 등)는
URL prefix로 매칭되는 `repo-creds` Secret을 따로 만든다. 자격증명은 Git에 커밋하지 않는다.

```bash
kubectl -n argocd create secret generic repo-creds-<registry> \
  --from-literal=type=oci \
  --from-literal=url=oci://<registry>/<path-prefix> \
  --from-literal=username=<user> \
  --from-literal=password=<token> \
  --dry-run=client -o yaml \
  | kubectl label --local -f - argocd.argoproj.io/secret-type=repo-creds -o yaml \
  | kubectl apply -f -
```

### 3. 서비스 발행 계약

| 항목 | 규칙 |
|---|---|
| 포맷 | ORAS 디렉터리 push로 만든 단일 tar 또는 tar+gzip layer |
| 내용 | 이미지 tag 또는 digest가 고정된 렌더링 매니페스트 |
| 개발 불변 태그 | `dev-<SHA7>` |
| 개발 이동 태그 | `development` |
| 운영 불변 태그 | `vYYYY.MM.N` |
| 운영 이동 태그 | `production` |

권장 순서:

1. 테스트를 통과한 이미지를 불변 `dev-SHA7` tag로 push한다.
2. 배포 매니페스트에 해당 image tag 또는 digest를 고정한다.
3. 렌더 결과에 plaintext Secret, 미치환 토큰, 예상하지 않은 namespace가 없는지 검사한다.
4. 렌더 결과를 `<service>-deploy`에 `dev-SHA7`(운영은 `vYYYY.MM.N`)로 push한다.
5. 검증된 digest에 `development` 또는 `production` 이동 tag를 지정한다.

Argo CD는 이동 tag의 digest 변화를 감지한다(`timeout.reconciliation: 60s`). 이미지만 push하고
`*-deploy` 아티팩트를 발행하지 않으면 서비스는 갱신되지 않는다. 지원 layer media type은
`bootstrap/argocd-values.yaml`의 `reposerver.oci.layer.media.types`에 있다.

## UI / CLI 접근

```bash
# UI — 로그인 없음 (익명 admin)
#   tailnet 기기:  https://<tailscale-hostname>:8443
#   서버 Mac:      http://127.0.0.1:8080

# CLI — 로그인 불필요. ~/.zshrc 등에 두면 argocd app list처럼 바로 사용
export ARGOCD_OPTS="--server <tailscale-hostname>:8443 --grpc-web"
argocd app list
```

| 구성 | 내용 |
|------|------|
| port-forward | LaunchAgent `local.self-iac.argocd-forward` — `kubectl port-forward --address 127.0.0.1 svc/argocd-server 8080:80` (KeepAlive, 로그 `~/Library/Logs/self-iac-argocd-forward.log`) |
| Tailscale Serve | `tailscale serve --bg --https=8443 http://127.0.0.1:8080` — tailnet 전용(Funnel 아님), 설정은 Tailscale이 보관 |

Traefik IP 허용 목록으로는 제한할 수 없다. OrbStack LoadBalancer를 거치면 localhost·LAN·tailnet 접속이 모두
같은 출발지 IP(OrbStack 게이트웨이)로 보이기 때문이다. Tailscale 네트워크 확장은 OrbStack 내부 주소(ClusterIP)로
연결하지 못하므로 Serve의 백엔드는 `127.0.0.1` port-forward를 거친다.

```bash
tailscale serve status
launchctl print gui/$(id -u)/local.self-iac.argocd-forward | grep -E 'state|pid'
launchctl kickstart -k gui/$(id -u)/local.self-iac.argocd-forward   # 다시 연결
```

## 상태 확인

```bash
kubectl -n argocd get appprojects,applications
kubectl -n argocd get applications \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision'
kubectl -n argocd describe application <name>

# repository / repo-creds Secret
kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=repository
kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=repo-creds

# 즉시 다시 조회
kubectl -n argocd annotate application <name> argocd.argoproj.io/refresh=hard --overwrite
```

## 트러블슈팅

```bash
kubectl -n argocd logs statefulset/argocd-application-controller --tail=100
kubectl -n argocd logs deployment/argocd-repo-server --tail=100
kubectl -n argocd get application <name> -o jsonpath='{.status.conditions}'
```

| 증상 | 확인할 항목 |
|---|---|
| `deploy.sh`가 미치환 값으로 중단 | `kubectl kustomize k8s` 결과의 `${...}`/`CHANGEME` 위치 |
| Application이 존재하지 않는 project를 참조 | `./k8s/deploy.sh`로 AppProject를 적용했는지 |
| destination 권한 거부 | 서비스 매니페스트 namespace가 `apps`인지 |
| OCI `revision not found` | `targetRevision` 태그가 `*-deploy` 저장소에 발행됐는지 |
| OCI `unauthorized` | `repo-creds` Secret의 url prefix와 자격증명 |
| 서비스만 `Unknown` | 이미지뿐 아니라 `*-deploy` 아티팩트도 발행했는지 |
| UI 접속 안 됨 | `tailscale serve status`, port-forward 에이전트 상태(`launchctl kickstart -k ...argocd-forward`), `argocd-server` 파드 |

## 롤백

- **플랫폼 매니페스트**: 검증된 파일 버전으로 되돌린 뒤 `./k8s/deploy.sh`. 되돌릴 버전에 없는 리소스는 명시적으로 삭제한다.
- **서비스 (개발)**: 검증된 `dev-SHA7`에 `development` 태그를 다시 지정하거나, Application의 `targetRevision`을 해당 태그/digest로 고정하고 `./k8s/deploy.sh`.
- **서비스 (운영)**: 검증된 `v*` 또는 digest로 `targetRevision`을 고정하는 방식을 우선한다.
