# 사전 요구사항

| 항목 | 요구사항 |
|------|---------|
| 하드웨어 (최소) | 4 CPU, 16GB RAM, 256GB SSD |
| 하드웨어 (권장) | 8 CPU, 24GB RAM, 512GB SSD |
| OS | macOS |
| Git | Xcode Command Line Tools |
| Homebrew | 패키지 관리자 |
| OrbStack | K8s 런타임 (CPU/RAM 동적 공유, VM 없음) |
| Tailscale | VPN 메시 + TLS 인증서 |

## 서버 설정 (00-prerequisites.sh)

OrbStack이 설치될 서버에서 실행한다.

```bash
# repo clone (첫 실행 시 Xcode CLT 설치 팝업이 자동으로 뜸)
git clone https://github.com/MarcusHong/self-iac-macos.git
cd self-iac-macos

./bootstrap/00-prerequisites.sh
```

### macOS 서버 설정

headless 서버로 운영하기 위한 macOS 설정. 스크립트가 자동 수행한다.

| 설정 | 자동/수동 | 내용 |
|------|:-------:|------|
| 원격 로그인 (SSH) | 자동 | `systemsetup -setremotelogin on` |
| 잠자기 방지 | 자동 | `pmset -a sleep 0 displaysleep 0 disksleep 0` |
| 전원 복구 시 자동 시작 | 자동 | `pmset -a autorestart 1` |
| SSH 공개키 등록 | 자동 | 랩탑의 공개키를 붙여넣어 등록 |
| 자동 로그인 | 수동 | 시스템 설정 → 사용자 및 그룹 → 자동 로그인 (FileVault 활성화 시 불가) |

### 설치 항목

스크립트가 순서대로 설치하고 상태를 확인한다.

1. Xcode Command Line Tools (Git 포함)
2. Homebrew
3. OrbStack (K8s 활성화)
4. Tailscale (로그인)

### 수동 설정 (스크립트 실행 후)

**Tailscale Admin Console** (https://login.tailscale.com/admin/dns):
1. MagicDNS 활성화
2. HTTPS Certificates 활성화
3. 머신 이름이 민감 정보를 포함하지 않는지 확인
   (인증서 발급 시 공개 CT 로그에 머신 이름이 게시됨)

## 원격 접근 설정 (client.sh)

작업 머신(랩탑)에서 실행하여 원격 OrbStack K8s에 kubectl로 접근할 수 있도록 kubeconfig를 구성한다.

```bash
./bootstrap/client.sh
```

### 사전 조건

- 서버에서 `00-prerequisites.sh` 실행 완료
- 서버와 Tailscale로 연결
- 서버에 SSH 접속 가능 (서버 세팅 시 SSH 공개키 등록 완료)

### 자동 수행 내용

1. `k8s.expose_services` 활성화 + OrbStack 재시작
2. kubeconfig 복사 (`scp`)
3. server 주소를 Tailscale MagicDNS hostname으로 변경
4. `insecure-skip-tls-verify` 설정
5. kubeconfig merge

**TLS 검증 우회가 필요한 이유:**
OrbStack K8s API 인증서의 SAN에 Tailscale hostname이 포함되지 않는다.
OrbStack은 이 설정을 지원하지 않으므로 ([#1456](https://github.com/orbstack/orbstack/issues/1456))
`insecure-skip-tls-verify`를 사용한다. Tailscale WireGuard가 전송 암호화를 제공하므로 보안상 문제없다.
