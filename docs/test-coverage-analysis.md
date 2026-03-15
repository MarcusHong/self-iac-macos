# Test Coverage Analysis

## Current State

**Test coverage: 0%** — The project has no automated tests, no test framework, and no CI/CD pipeline.

| File | Lines | Tests |
|------|-------|-------|
| `bootstrap/run.sh` | 37 | None |
| `bootstrap/00-prerequisites.sh` | 210 | None |
| `bootstrap/01-data.sh` | 544 | None |
| `bootstrap/02-k8s.sh` | 268 | None |
| `bootstrap/client.sh` | 84 | None |
| `bootstrap/gitlab-values.yaml` | ~50 | None |
| `bootstrap/traefik-values.yaml` | ~36 | None |

---

## Recommended Testing Strategy

Since this is a Bash-based IaC project, we recommend **[BATS (Bash Automated Testing System)](https://github.com/bats-core/bats-core)** as the test framework. Tests should be structured in three tiers:

### Tier 1: Unit Tests (High Priority)

Extract pure logic into testable functions and validate them in isolation by mocking external commands.

#### 1.1 Shared Utility Functions (`log`, `warn`, `err`, `step`)

These are duplicated across all four scripts. They should be extracted into a shared `lib/common.sh` and unit tested.

- `log()` outputs green `[✓]` prefix
- `warn()` outputs yellow `[!]` prefix
- `err()` outputs red `[✗]` prefix and exits with code 1
- `step()` outputs cyan section header

#### 1.2 Tailscale Hostname Detection (`01-data.sh:59-77`)

The three-fallback hostname detection logic is complex and has no validation:

```
1. tailscale cert 2>&1 | grep -oE pattern
2. tailscale status --json | python3 parse
3. tailscale whois --json self | python3 parse
```

**Tests needed:**
- Each fallback returns a valid hostname
- Graceful handling when all three fail
- Hostname format validation (should match `*.ts.net`)

#### 1.3 Password Generation (`01-data.sh:125-126`)

```bash
openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32
```

**Tests needed:**
- Output is exactly 32 characters
- Output contains only alphanumeric characters
- Two consecutive calls produce different values

#### 1.4 PostgreSQL Configuration Logic (`01-data.sh:179-205`)

- `listen_addresses` detection and update
- `max_connections` threshold comparison (`< 1000`)
- `pg_hba.conf` idempotency (check for `# Infra` marker)

**Tests needed:**
- Config file with default values gets updated
- Config file with existing correct values is not modified
- `PG_CONF_CHANGED` flag controls restart behavior

#### 1.5 Certificate Expiry Check (`01-data.sh:484-486`)

```bash
openssl x509 -enddate -noout -in "$CERT_DIR/${TS_HOSTNAME}.crt"
```

**Tests needed:**
- Expired certificate is detected
- Valid certificate reports correct expiry date

#### 1.6 Cron Idempotency (`01-data.sh:522-527`)

**Tests needed:**
- Cron entry is added when absent
- Cron entry is not duplicated when already present

### Tier 2: Integration Tests (Medium Priority)

These tests validate interactions between components with real (or containerized) services.

#### 2.1 `run.sh` — Orchestration Logic

- Scripts are executed in alphabetical order (`00-*.sh`, `01-*.sh`, `02-*.sh`)
- Failure in any script stops execution and returns the correct exit code
- Success prints completion message

#### 2.2 PostgreSQL Setup (`01-data.sh`)

- User creation is idempotent (safe to re-run)
- Password reset flow updates existing users
- Database `gitlab` is created with correct owner and extensions (`pg_trgm`, `btree_gist`)
- `pg_hba.conf` entries allow scram-sha-256 auth from expected subnets

#### 2.3 OpenBao Secrets (`01-data.sh`)

- `infra/postgresql`, `infra/minio`, `infra/valkey` secrets are written
- Secrets are only updated when passwords change (not on every run)
- Re-run with existing data preserves secrets

#### 2.4 K8s Secret Generation (`02-k8s.sh:83-164`)

- Kubernetes secrets are created with correct structure
- MinIO connection secret has valid YAML format
- Registry storage config has valid YAML format
- `--dry-run=client -o yaml | kubectl apply -f -` pattern is idempotent

#### 2.5 GitLab Values Rendering (`02-k8s.sh:168-176`)

- `TS_HOSTNAME_PLACEHOLDER` is replaced correctly
- SMTP enabled/disabled paths produce valid YAML
- Rendered file is cleaned up after use

#### 2.6 `client.sh` — kubeconfig Merge

- Existing kubeconfig is backed up before merge
- Only `orbstack` context is imported (other contexts are not leaked)
- Server URL is rewritten to remote host on port 26443
- Merge failure restores backup

### Tier 3: Validation Tests (Lower Priority but Quick Wins)

#### 3.1 YAML Lint

Validate `gitlab-values.yaml` and `traefik-values.yaml` are well-formed YAML.

#### 3.2 ShellCheck Static Analysis

Run [ShellCheck](https://www.shellcheck.net/) on all `.sh` files to catch:
- Unquoted variables
- Unused variables
- Incorrect `test`/`[` usage
- Word splitting issues

#### 3.3 Script Header Validation

- All scripts have `set -uo pipefail`
- All scripts have descriptive headers

---

## Proposed File Structure

```
tests/
├── bats/                    # BATS test files
│   ├── common.bats          # Shared utility function tests
│   ├── prerequisites.bats   # 00-prerequisites.sh tests
│   ├── data.bats            # 01-data.sh tests
│   ├── k8s.bats             # 02-k8s.sh tests
│   ├── client.bats          # client.sh tests
│   └── run.bats             # run.sh orchestration tests
├── fixtures/                # Test data
│   ├── pg_hba.conf          # Sample pg_hba.conf
│   ├── postgresql.conf      # Sample postgresql.conf
│   └── fake-cert.crt        # Test certificate
├── helpers/                 # Test helpers
│   └── mocks.bash           # Command mocks (brew, kubectl, helm, etc.)
└── lint/
    └── shellcheck.sh        # ShellCheck wrapper
bootstrap/
└── lib/
    └── common.sh            # Extracted shared functions (new)
```

---

## Top 5 Priorities

| # | Area | Why | Effort |
|---|------|-----|--------|
| 1 | **Extract & test `lib/common.sh`** | Eliminates duplication across 4 scripts, easy to test in isolation | Low |
| 2 | **ShellCheck linting** | Zero-effort wins — catches real bugs statically | Low |
| 3 | **Tailscale hostname detection** | Complex 3-fallback logic with no validation; silent failures possible | Medium |
| 4 | **PostgreSQL config idempotency** | Most complex logic in the project (01-data.sh); incorrect config = data loss risk | Medium |
| 5 | **kubeconfig merge safety** | Modifies user's kubeconfig — bugs can break all K8s access | Medium |

---

## Getting Started

```bash
# Install BATS
brew install bats-core

# Install ShellCheck
brew install shellcheck

# Run ShellCheck on all scripts
shellcheck bootstrap/*.sh

# Run BATS tests
bats tests/bats/
```
