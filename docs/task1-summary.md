# Task 1 — Implementation Summary

A reference doc covering everything built in Task 1, **why** each decision was
made, and the design trade-offs an interviewer is likely to drill on.

---

## 1. Scope

> Build, containerise, deploy a Python POST/GET counter to EKS through a fully
> automated GitHub Actions + GitOps pipeline. Storage must be encrypted. EKS
> must use **STANDARD** support type. Live URL must serve on port 80.

Delivered: <http://k8s-prod-counters-5c27526452-245847380.eu-west-2.elb.amazonaws.com/>

---

## 2. Repository layout

```
counter-service/
├── service/                  # Python app (FastAPI + Redis)
│   ├── app/
│   │   ├── __init__.py       #   __version__
│   │   ├── main.py           #   FastAPI app, lifespan, middleware, endpoints
│   │   ├── config.py         #   pydantic-settings (env-driven)
│   │   ├── counter.py        #   CounterRepository Protocol + InMemory + Redis
│   │   ├── metrics.py        #   prometheus_client registry + meters
│   │   └── logging_setup.py  #   structured JSON logger
│   ├── tests/                #   24 pytest tests, 100% line coverage
│   │   ├── conftest.py
│   │   ├── test_counter.py
│   │   ├── test_endpoints.py
│   │   └── test_redis_counter.py   # fakeredis-backed
│   ├── Dockerfile            # multi-stage, distroless runtime
│   ├── docker-compose.yml    # local Redis-backed demo
│   └── pyproject.toml        # deps + ruff/mypy/pytest config
├── infra/
│   ├── bootstrap/            # one-shot: KMS-encrypted versioned S3 state bucket
│   │   ├── versions.tf
│   │   ├── variables.tf
│   │   ├── main.tf
│   │   └── outputs.tf
│   └── envs/prod/            # the entire prod stack
│       ├── versions.tf       # tf >= 1.10 (S3 native locking)
│       ├── backend.tf        # S3 backend, use_lockfile = true
│       ├── providers.tf      # aws + kubernetes + helm
│       ├── variables.tf
│       ├── vpc.tf            # 3 AZ VPC + endpoints
│       ├── kms.tf            # EKS-secrets CMK
│       ├── eks.tf            # cluster + node group + addons
│       ├── ecr.tf            # repo + lifecycle policy
│       ├── iam.tf            # OIDC role, IRSA roles, scoped policies
│       ├── addons.tf         # Helm releases for cluster add-ons
│       ├── outputs.tf
│       └── policies/         # IAM trust + permissions docs (templatefile)
│           ├── github-oidc-assume.json.tpl
│           ├── github-actions-inline.json.tpl
│           ├── github-actions-iam.json.tpl
│           └── image-updater-assume.json.tpl
├── deploy/                   # Kustomize manifests
│   ├── base/
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml          # PSS=restricted
│   │   ├── serviceaccount.yaml     # automountToken=false
│   │   ├── deployment.yaml         # securityContext, probes, spread
│   │   ├── service.yaml
│   │   ├── ingress.yaml            # ALB
│   │   ├── hpa.yaml                # CPU+mem
│   │   ├── pdb.yaml                # minAvailable=2
│   │   ├── networkpolicy.yaml      # default-deny + 3 allow rules
│   │   ├── servicemonitor.yaml
│   │   └── redis/                  # StatefulSet + ConfigMap + Service
│   └── overlays/prod/
│       └── kustomization.yaml      # image override + version label
├── gitops/apps/
│   ├── counter-service-app.yaml    # Argo CD Application (image-updater wired)
│   └── README.md
├── observability/dashboards/
│   └── counter-service.json        # Grafana dashboard, 8 panels
├── .github/workflows/
│   ├── service-ci.yml              # lint + types + tests + build + Trivy + push
│   └── terraform.yml               # fmt + plan (PR) + apply (main)
├── evidence/                       # captured kubectl/curl outputs
├── docs/                           # this file
└── README.md
```

---

## 3. Python service

### 3.1 Why FastAPI?

- Async-native (matches `redis.asyncio` ergonomically)
- Pydantic-driven validation built in (single dep for typing + settings + IO)
- ASGI gives uvicorn for high-perf HTTP without web-server complexity
- Auto-OpenAPI / Swagger at `/docs` — useful for the eval reviewer

Trade-off considered: Flask is simpler but sync-only; Quart adds async to
Flask but pulls fewer batteries; FastAPI hit the sweet spot.

### 3.2 Repository pattern (`counter.py`)

```python
class CounterRepository(Protocol):
    async def increment(self) -> int: ...
    async def value(self) -> int: ...
    async def record_restart(self) -> int: ...
    async def restart_count(self) -> int: ...
    async def ping(self) -> bool: ...
    async def close(self) -> None: ...
```

Two implementations:

- `InMemoryCounter` — used by tests and local dev
- `RedisCounter` — production backend; uses `INCR` for atomic increments

Factory `build_counter()` selects by env var `COUNTER_BACKEND={memory|redis}`.
Raises `ValueError` for unknown backends (tested).

**Why a Protocol, not ABC?** Structural typing — doesn't force concrete classes
to inherit. Cleaner for two implementations and easier to extend (e.g.,
DynamoDB, Postgres) without inheritance gymnastics.

### 3.3 Endpoints (`main.py`)

| Method+Path | Behaviour | Source |
|---|---|---|
| `GET /` | Returns plaintext `counter-service vX.Y.Z\ncount: N` | Reads current value, sets the `counter_value` gauge for Prometheus |
| `POST /` | Returns plaintext `count: N` (status 201) | Calls `INCR` server-side (atomic), updates gauge |
| `GET /healthz` | Returns `ok` | Liveness — always 200 unless process is dead |
| `GET /readyz` | Returns `ready` (200) or `not ready` (503) | Calls `repo.ping()` — true Redis health |
| `GET /version` | Returns `0.1.1` | The string the CD demo drives end-to-end |
| `GET /metrics` | Prometheus exposition | `counter_http_requests_total`, `counter_http_request_duration_seconds`, `counter_value`, `counter_restart_count` |

### 3.4 Lifespan & restart counting

The FastAPI lifespan event:
1. Builds the chosen CounterRepository (per env)
2. Calls `repo.record_restart()` — atomic INCR of a separate `counter:restarts`
   key. Every pod boot bumps this.
3. Sets the `counter_restart_count` gauge
4. Yields to serve traffic
5. On shutdown: closes the Redis client

**Why a separate restart counter?** Required by Task 2's bonus (the
`counter_data` table has `restart_count`). Implementing it from day 1 means
the integration is a small endpoint addition rather than a refactor.

### 3.5 Metrics middleware

A `@app.middleware("http")` wraps every request:
- Times it with `time.perf_counter()`
- Looks up the matched route's path for the label (avoids high-cardinality URL labels)
- Increments `counter_http_requests_total{method, endpoint, status}`
- Observes latency in `counter_http_request_duration_seconds{method, endpoint}`

Endpoint label = matched route path, not URL — so `/`, not `/?...`. Keeps
cardinality bounded.

### 3.6 Structured logging

`logging_setup.configure_logging()` installs a `python-json-logger` handler
on the root logger and forces uvicorn's loggers to the same level/format.
Every log line is JSON with `timestamp`, `level`, `logger`, `message`, plus
any `extra=` fields.

Sample output (verified live):
```json
{"timestamp": "...", "level": "INFO", "logger": "counter",
 "message": "service.started", "version": "0.1.1", "backend": "memory",
 "restarts": 1}
```

### 3.7 Configuration (`config.py`)

`pydantic-settings` `BaseSettings` with prefix `COUNTER_`. So:
- `COUNTER_BACKEND=redis` overrides default
- `COUNTER_REDIS_URL=redis://host:6379/0`
- `COUNTER_APP_VERSION=0.1.1` (sourced from the K8s label at runtime)
- `COUNTER_LOG_LEVEL=INFO`

12-factor: all config from env, no files.

### 3.8 Tests (`tests/`)

**24 tests, 100% line coverage, gate set at 90%.**

| File | Coverage focus |
|---|---|
| `test_counter.py` | InMemoryCounter increment, value, restart tracking, ping; factory rejects bad backend names; factory builds Redis without connecting |
| `test_endpoints.py` | All HTTP routes via httpx ASGI transport against `create_app(settings)`; metrics format; 405 on unsupported methods |
| `test_redis_counter.py` | RedisCounter wired against `fakeredis.aioredis.FakeRedis` via a monkey-patched `from_url` — exercises real Redis protocol without a server. Covers increment, value (unset+set), `record_restart` independence from the counter, `ping` success + exception path, `close` delegating to `aclose` |

Lint: `ruff` (E/F/I/B/UP/SIM/RUF rules)
Types: `mypy --strict`
Async: `pytest-asyncio` with `asyncio_mode = "auto"`

---

## 4. Containerisation

### 4.1 Multi-stage Dockerfile

```dockerfile
# Builder: install deps into a venv
FROM python:3.13-slim AS builder
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY pyproject.toml ./
COPY app ./app
RUN pip install --upgrade pip && pip install . \
    && pip uninstall -y pip setuptools wheel   # strip build deps

# Runtime: distroless, no shell
FROM gcr.io/distroless/python3-debian13:nonroot AS runtime
ENV PYTHONPATH=/opt/venv/lib/python3.13/site-packages
COPY --from=builder /opt/venv /opt/venv
COPY --chown=nonroot:nonroot app /app/app
WORKDIR /app
USER nonroot
EXPOSE 8080
HEALTHCHECK CMD ["python", "-c", "..."]
ENTRYPOINT ["python", "-m", "uvicorn", "app.main:app", ...]
```

### 4.2 Why distroless?

- **No shell, no apt, no package manager** — drastically smaller attack
  surface than `python:3.13-slim` (which ships with bash, dpkg, etc.)
- **149 MB final image** — vs ~250 MB for the equivalent slim-based image
- **Non-root user `nonroot` (UID 65532)** baked in

### 4.3 Why strip pip/setuptools/wheel from the runtime venv?

These are install-time tools; the runtime doesn't import them. Removing
them:
- Cuts ~19 MB from the image
- Removes 3 transitive CVE sources (`jaraco.context`, `wheel`, `setuptools`'s
  bundled deps)

### 4.4 Why Python 3.13?

Started on 3.11; bumped to 3.13 to escape `CVE-2025-13836` in the Debian 12
`libpython3.11` that distroless was still shipping. The same distroless
project publishes `python3-debian13:nonroot` with Python 3.13.5 +
Debian 13 base — fixes the CVE and no upstream rebuild dependency.

### 4.5 Local dev compose

`service/docker-compose.yml` brings up Redis + counter-service together.
Verified persistence: counter survived a `docker compose restart
counter-service` (count stayed at 3 after restart) via AOF on Redis.

---

## 5. Kubernetes deployment

### 5.1 Why Kustomize (not Helm or raw YAML)?

- **DRY base + overlays**: `deploy/base/` is the canonical truth; the prod
  overlay just patches `images[].newTag` and stamps version labels. Adding
  staging would be a 10-line overlay.
- **Image-updater write-target**: `argocd-image-updater` writes the new tag
  to `deploy/overlays/prod/kustomization.yaml` — clean one-line diff.
- **Native everywhere**: kubectl, ArgoCD, kubeconform — no extra runtime.

Helm gives more powerful templating but is overkill for a single-environment
nano-service. Raw YAML loses the overlay story.

### 5.2 Namespace + Pod Security

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: prod
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

`restricted` is the strictest PSS profile. Forbids:
- root containers
- privilege escalation
- host network/PID/IPC
- privileged mode
- caps beyond a tiny allowed set
- writable root filesystem (warning)

Verified by accident during debugging — my `nettest` busybox pod was
rejected for not meeting the bar.

### 5.3 Deployment

Important fields:

```yaml
replicas: 3
strategy: { rollingUpdate: { maxSurge: 1, maxUnavailable: 0 } }
serviceAccountName: counter-service
automountServiceAccountToken: false
securityContext:
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 65532
  fsGroup: 65532
  seccompProfile: { type: RuntimeDefault }
topologySpreadConstraints:
  - { topologyKey: topology.kubernetes.io/zone, maxSkew: 1, ... }
  - { topologyKey: kubernetes.io/hostname,      maxSkew: 1, ... }
containers:
  - name: counter-service
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: { drop: [ALL] }
    env:
      - { name: COUNTER_BACKEND,  value: redis }
      - { name: COUNTER_REDIS_URL, value: redis://counter-redis.prod.svc.cluster.local:6379/0 }
      - name: COUNTER_APP_VERSION
        valueFrom:
          fieldRef: { fieldPath: metadata.labels['app.kubernetes.io/version'] }
    resources: { requests: {cpu: 50m, memory: 96Mi}, limits: {cpu: 500m, memory: 192Mi} }
    livenessProbe:  { httpGet: { path: /healthz } }
    readinessProbe: { httpGet: { path: /readyz } }
    startupProbe:   { httpGet: { path: /healthz }, failureThreshold: 30, periodSeconds: 2 }
```

**Why startup probe?** Lifespan can take a few seconds (cold Redis connection
warmup). Without it, the liveness probe would kill the pod before it could
serve. Startup probe holds liveness/readiness off until /healthz responds
or the 60s budget runs out.

**Why `maxUnavailable: 0`?** Always at least 3 ready during a rolling
update. PDB enforces it too (defense in depth).

**Why `automountServiceAccountToken: false` at both SA and pod level?**
The counter doesn't call the K8s API. Mounting a token gives an attacker
who breaks out of the container immediate K8s access. Belt and suspenders.

### 5.4 Service + Ingress

- Service: `ClusterIP` on 8080
- Ingress: ALB via AWS Load Balancer Controller
  ```yaml
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip   # pod IPs directly, no NodePort hop
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}]'
    alb.ingress.kubernetes.io/healthcheck-path: /healthz
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: "15"
  ```

`target-type: ip` keeps traffic inside the VPC CNI's pod network — no
hop through nodeport iptables rules.

### 5.5 HPA

```yaml
spec:
  minReplicas: 3
  maxReplicas: 10
  metrics:
    - { type: Resource, resource: { name: cpu,    target: {type: Utilization, averageUtilization: 70} } }
    - { type: Resource, resource: { name: memory, target: {type: Utilization, averageUtilization: 80} } }
  behavior:
    scaleDown: { stabilizationWindowSeconds: 300, ... }   # avoid flapping
    scaleUp:   { stabilizationWindowSeconds: 0,   policies: [{type: Percent, value: 100, periodSeconds: 30}] }
```

Aggressive scale-up (double in 30s) + slow scale-down (5min). Two metrics:
either CPU or memory hitting target triggers scale-up.

KEDA noted as a follow-up for request-rate-based scaling, but CPU tracks
well for this workload (Redis INCR is cheap).

### 5.6 PDB

`minAvailable: 2` with `minReplicas: 3` → autoscaler/node-drain can take at
most one replica out at a time.

### 5.7 NetworkPolicies (4 of them)

- **`default-deny-ingress`**: empty `podSelector` matches everything in the
  namespace; default-denies all inbound.
- **`counter-service-ingress`**: allow from `0.0.0.0/0` to port 8080 (the
  ALB terminates public traffic, target-type:ip means the source is the ALB
  in the VPC — but ipBlock 0.0.0.0/0 is conservative); plus allow from
  Prometheus pods (label `app.kubernetes.io/name: prometheus`) in
  `monitoring` namespace.
- **`counter-redis-ingress`**: allow ONLY from counter-service pods to
  Redis on 6379. **Added during the audit** — the absence of this policy
  caused 1+ hour of debugging where Redis was up but counter-service hung
  in the lifespan because default-deny-ingress was blocking the 6379
  connection.
- **`counter-service-egress`**: allow counter-service → counter-redis:6379,
  counter-service → kube-dns (UDP+TCP 53). Everything else denied.

Enforcement: **VPC CNI's network-policy mode**. Enabled via the addon
config:
```hcl
configuration_values = jsonencode({
  enableNetworkPolicy = "true"
  nodeAgent = { enabled = true }
  env = { ENABLE_POD_ENI = "true", ENABLE_PREFIX_DELEGATION = "true" }
})
```

### 5.8 Redis StatefulSet

- 1 replica (single SPOF — documented; Sentinel/Cluster is the upgrade path)
- AOF on with `appendfsync everysec` → at most 1s data loss on crash
- Encrypted gp3 PVC (1 GiB) via the EBS CSI driver using AWS-managed
  `aws/ebs` key
- Headless Service (`clusterIP: None`) for stable pod DNS
- Read-only root FS, non-root UID 999 (Redis's standard UID)

### 5.9 ServiceMonitor

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  labels:
    release: kube-prometheus-stack   # how the prom instance selects monitors
spec:
  endpoints: [ { port: http, path: /metrics, interval: 30s } ]
```

kube-prometheus-stack's Prometheus is configured with
`serviceMonitorSelectorNilUsesHelmValues: false` so it picks up
ServiceMonitors in any namespace, not just `monitoring`.

---

## 6. Infrastructure (Terraform)

### 6.1 Why split bootstrap vs prod?

The classic chicken-and-egg: the prod stack's state must live in S3 + KMS,
but who creates those? Three options:

| Approach | Verdict |
|---|---|
| **Tiny `bootstrap/` module with local state** (chosen) | Run once manually. Its own state file is gitignored. Clean: `terraform destroy` on prod cannot accidentally nuke the backend. |
| Single stack, `-migrate-state` after first apply | Works but the first apply is special-cased; surprising to next operator. |
| Manually-created bucket, no IaC for state | Loses reproducibility. |

### 6.2 State backend (`bootstrap/`)

- KMS CMK (rotation on, 30-day deletion window)
- S3 bucket (versioned, KMS-encrypted, 90-day non-current expiration,
  abort-incomplete-MPU after 7 days)
- No `aws_s3_bucket_public_access_block` — the SCP on this Check Point
  account denies `s3:PutBucketPublicAccessBlock`, AND new S3 buckets have
  it on by default since April 2023. Documented in code.
- **No DynamoDB lock table** — Terraform 1.10+ supports S3 native locking
  via `use_lockfile = true`, which writes a `.tflock` object atomically
  using S3 conditional writes. One fewer service, identical semantics.

### 6.3 VPC

- 3 AZs (`eu-west-2a/b/c`)
- 3 private subnets + 3 public subnets, derived via `cidrsubnet(...)` so
  changing CIDR is one variable change
- `single_nat_gateway = true` — cost trim (one NAT instead of 3, ~$0.045/hr
  saved). Documented trade-off: real prod wants per-AZ NAT for AZ-isolated
  egress on failure + no cross-AZ data charges.
- VPC endpoints for S3 (gateway), ECR (api+dkr), STS — keeps ECR pulls and
  IRSA token exchanges on the AWS backbone (saves NAT data charges + faster)
- Required tags on subnets for ALB/Karpenter discovery:
  - public: `kubernetes.io/role/elb: 1`
  - private: `kubernetes.io/role/internal-elb: 1`, `karpenter.sh/discovery: <cluster_name>`

### 6.4 EKS

Uses `terraform-aws-modules/eks/aws ~> 20.31`.

```hcl
cluster_upgrade_policy = { support_type = "STANDARD" }   # ASSIGNMENT REQUIREMENT
cluster_version = "1.34"                                  # current Standard-supported
authentication_mode = "API"                               # access entries, not aws-auth ConfigMap
enable_irsa = true
cluster_encryption_config = {
  resources        = ["secrets"]
  provider_key_arn = aws_kms_key.eks_secrets.arn         # secret-at-rest CMK
}
cluster_enabled_log_types = ["api", "audit", "authenticator"]
```

**Access entries** (replaces the legacy `aws-auth` ConfigMap):
- `bootstrap_admin` — my IAM user, cluster-admin scope. Why explicit?
  `enable_cluster_creator_admin_permissions = true` would auto-create one
  but bind to whoever applies first (me locally OR CI), so the two would
  race on the same `cluster_creator` key. Enumerating both wins eliminates
  the race.
- `github_actions` — the GH OIDC role, cluster-admin scope. Needed so the
  `kubernetes` + `helm` Terraform providers can refresh K8s resources
  during plan/apply.

Add-ons (managed via the cluster_addons block):
- `coredns`, `kube-proxy` — most_recent
- `vpc-cni` — most_recent, with `enableNetworkPolicy: true` at top-level
  (moved out of env in CNI v1.14+), pod-ENI and prefix-delegation enabled
- `aws-ebs-csi-driver` — with IRSA role attached

Managed node group:
- `AL2023_x86_64_STANDARD` AMI
- `t3.medium` × 2 (autoscaler can go to 6)
- gp3 EBS volumes, encrypted with AWS-managed key

### 6.5 ECR

- `image_tag_mutability = "IMMUTABLE"` — same tag cannot be overwritten.
  Forces every push to use a unique tag (the git SHA).
- `scan_on_push = true`
- KMS encryption with project CMK
- Lifecycle: expire untagged after 1 day, keep last 30 images

### 6.6 IAM / IRSA

Six IAM roles, all in `iam.tf`. The whole policy surface lives in
`policies/*.json.tpl` rendered via `templatefile()` — keeps Terraform clean,
keeps policies grep-able as standalone JSON IAM docs.

| Role | What it can do |
|---|---|
| `counter-service-prod-gha-ci` (the OIDC role) | PowerUserAccess (everything except IAM) + a scoped IAM policy granting IAM ops only on resources matching `counter-service-prod-*`, `default-eks-node-group-*`, and AWS-managed policies (read-only). Plus inline ECR push/pull and TF state R/W + KMS. |
| `counter-service-prod-aws-lbc` (IRSA) | AWS-managed `LoadBalancerControllerIAMPolicy` |
| `counter-service-prod-external-secrets` (IRSA) | Read AWS Secrets Manager under `counter-service/*` only |
| `counter-service-prod-cluster-autoscaler` (IRSA) | Cluster Autoscaler policy, scoped to this cluster |
| `counter-service-prod-ebs-csi` (IRSA) | EBS CSI driver policy |
| `counter-service-prod-image-updater` (IRSA) | `AmazonEC2ContainerRegistryReadOnly` (reads ECR for new tags) |

**Why use the GitHub OIDC provider as a `data` source, not a `resource`?**
The OIDC provider for `token.actions.githubusercontent.com` is
account-global — there can be only one per account. Other candidates
already created it. Trying to `resource` it errors `EntityAlreadyExists`.

**Why `templatefile()` for IAM policies?**
- Policies as standalone JSON files can be linted by external tooling
  (`cfn-policy-validator`, `iam-floyd`, parliament).
- Easier to review in PRs — IAM diffs show in JSON, not in nested HCL.
- `terraform plan` showed 0 IAM changes when migrating from inline data
  sources → templatefile, proving byte-equivalence.

### 6.7 Helm add-ons (in `addons.tf`)

| Release | Why |
|---|---|
| `aws-load-balancer-controller` | Provisions the ALB from our Ingress |
| `cluster-autoscaler` | Scales nodes 2→6 based on pending pods |
| `metrics-server` | Required for HPA's CPU/mem queries |
| `external-secrets` | Sync AWS Secrets Manager → K8s Secrets |
| `kube-prometheus-stack` | Prometheus + Grafana + the ServiceMonitor CRD |
| `argocd` | The CD control plane |
| `argocd-image-updater` | Watches ECR for new SHA tags, bumps kustomize |

**Two gotchas that bit during apply:**

1. The TF helm provider does NOT run `helm repo update` itself. On a clean
   runner this errors with `no cached repo found`. Fix: the
   `terraform.yml` workflow has a `Prime helm repo cache` step using
   `azure/setup-helm` + `helm repo add/update` before init.

2. The AWS LBC's mutating webhook intercepts Service create cluster-wide
   the moment it's installed. ESO's install creates its own webhook Service,
   which raced LBC's pods becoming ready. Fix: `depends_on = [helm_release.aws_lbc]`
   on the ESO release.

---

## 7. CI/CD

### 7.1 `service-ci.yml`

Three jobs:

| Job | Triggers | What it does |
|---|---|---|
| `test` | PR + push to main | `ruff check` → `mypy app` → `pytest` (coverage gate 90%) |
| `manifests-validate` | PR + push to main | `kustomize build deploy/overlays/prod` → `kubeconform -strict` |
| `build-and-push` | push to main only | OIDC to AWS → ECR login → `docker build` → `trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1` → `docker push <ecr>:<git-sha>` |

**Concurrency:** PRs cancel-in-progress; pushes do not.

**Why only push the immutable SHA tag?** ECR is IMMUTABLE. Initially the
workflow also pushed `:latest-main` for image-updater convenience, but
the second push fails ("tag already exists"). Dropped the moving tag —
image-updater discovers the SHA via the regex `^[0-9a-f]{40}$`.

### 7.2 `terraform.yml`

Two jobs:

| Job | Triggers | What it does |
|---|---|---|
| `plan` | PR + push to main + workflow_dispatch (always) | `terraform fmt -check` → `init` (S3 backend, OIDC to AWS) → `validate` → `plan -out=tfplan` → uploads artifact |
| `apply` | push to main + workflow_dispatch action=apply | depends on `plan`; runs `terraform apply -auto-approve`. Gated by GitHub `prod` environment for required reviewers. |

Plan runs on every trigger because apply `needs: plan` — if plan skipped, apply skipped.

**OIDC authentication, not access keys.** The role is scoped (via the OIDC sub claim) to:
- `repo:MichaelF21/counter-service:ref:refs/heads/main`
- `repo:MichaelF21/counter-service:pull_request`
- `repo:MichaelF21/counter-service:environment:prod`

So even if the role's policies were over-permissive, a fork or random branch can't assume it.

### 7.3 GitOps (Argo CD)

`gitops/apps/counter-service-app.yaml` defines an `Application`:
- Source: this repo, `deploy/overlays/prod` at `main`
- Destination: `prod` namespace
- Sync policy: automated + prune + selfHeal
- `ignoreDifferences` for the Redis StatefulSet's `volumeClaimTemplates`
  (Kustomize stamps version labels there but K8s rejects mutating VCT on
  a live StatefulSet — without this, the app is stuck OutOfSync forever)
- Annotations for `argocd-image-updater`:
  - `image-list: counter=...counter-service-prod`
  - `counter.update-strategy: newest-build`
  - `counter.allow-tags: regexp:^[0-9a-f]{40}$`
  - `write-back-method: git` + `write-back-target: kustomization`

CD round-trip (verified live):
1. Commit to main touching `service/`
2. `service-ci` builds and pushes `:<sha>` to ECR
3. `argocd-image-updater` polls ECR every 2min, sees new tag, would commit a tag bump to `deploy/overlays/prod/kustomization.yaml` (in this environment a manual deploy commit was used because the image-updater's ECR auth script has a format issue — known, documented follow-up)
4. Argo CD diff'd, rolling-updated the deployment, all PDB-compliant
5. ALB serves the new version

---

## 8. Observability

- **Logs**: structured JSON to stdout → captured by the EKS log agent (or kubectl logs)
- **Metrics**: Prometheus scrape via ServiceMonitor
- **Dashboard**: `observability/dashboards/counter-service.json` — 8 panels (counter value, restart count, rate, p50/95/99 latency, replicas ready, CPU/memory per pod)
- **Tracing**: not wired — noted as follow-up (OTel → ADOT → X-Ray)

---

## 9. Security posture (consolidated)

| Layer | Control |
|---|---|
| Container | Distroless, no shell/apt; non-root UID 65532; `readOnlyRootFilesystem`; all caps dropped; seccomp `RuntimeDefault`; no SA token mounted; build deps stripped from venv |
| Namespace | PSS `restricted` enforced |
| Network | Default-deny-ingress + 3 scoped allows; egress only to Redis + DNS; VPC CNI policy enforcement |
| Image | ECR IMMUTABLE + scan-on-push + KMS; Trivy gate fails on HIGH/CRITICAL (currently 0 findings) |
| State at rest | EKS secrets + ECR + S3 state encrypted with project KMS CMKs; EBS volumes with AWS-managed key |
| IAM | GitHub OIDC (no static keys); IRSA per workload, scoped to minimum API surface; CI role is PowerUserAccess + scoped IAM policy (not AdministratorAccess) |
| Secrets lifecycle | AWS Secrets Manager → ESO → K8s Secret; nothing in git |

---

## 10. Audit findings → fixes (the full history)

| # | Finding | Fix |
|---|---|---|
| 1 | service-ci push broken on every commit | Drop the `:latest-main` moving-tag push (ECR is IMMUTABLE) |
| 2 | terraform CI plan errored "cluster unreachable" | Add EKS access entry for the GH OIDC role with `AmazonEKSClusterAdminPolicy` |
| 3 | `enable_cluster_creator_admin_permissions = true` raced between local + CI | Removed the flag; explicit access entries for both my user (`bootstrap_admin`, parameterised via variable) + the CI role |
| 4 | Test coverage on `counter.py` was 41% (only constructor of RedisCounter exercised) | Added `tests/test_redis_counter.py` with 8 fakeredis-backed tests → 100% |
| 5 | Trivy: 3 HIGH (libpython, starlette, jaraco.context, wheel) | Bumped FastAPI 0.115→0.122 (pulls starlette 0.50, kills CVE-2025-62727); stripped pip/setuptools/wheel from runtime venv (kills jaraco + wheel CVEs); switched base distroless py-debian12 → py-debian13 with Python 3.13 (kills libpython CVE-2025-13836). Result: 0 HIGH. Trivy gate restored to fail-on-HIGH. |
| 6 | IAM CI role had `AdministratorAccess` | Replaced with `PowerUserAccess` + a scoped IAM policy template (`policies/github-actions-iam.json.tpl`) granting IAM ops only on `counter-service-prod-*` roles/policies, OIDC providers, service-linked roles |
| 7 | Argo CD app stuck `OutOfSync` on the Redis StatefulSet | Added `ignoreDifferences` for `/spec/volumeClaimTemplates` (Kustomize labels propagate there but K8s rejects mutating VCTs on a live StatefulSet) |
| 8 | Unused `aws_kms_key.ebs` (gp3 SC fell back to `aws/ebs`) | Deleted the key + alias + policy template; node block_device_mappings cleaned up |
| 9 | README drift (EKS 1.31, DynamoDB lock table, "everything CMK-encrypted") | Pass through every claim — now accurate |
| 10 | terraform helm provider couldn't find chart repos in clean runners | Added `azure/setup-helm` + `helm repo add/update` step to the workflow |
| 11 | ESO install raced AWS LBC's webhook | `depends_on = [helm_release.aws_lbc]` on ESO |
| 12 | argocd-image-updater config: wrong field name `credexpire` (should be `credsexpire`) | Fixed in addons.tf |
| 13 | Trivy action `@0.28.0` didn't exist | Pinned to `@v0.36.0` |
| 14 | service-ci `ECR_REPOSITORY: counter-service` (wrong name; we use `counter-service-prod`) | Fixed env var |
| 15 | EBS CMK didn't trust AutoScaling SLR → node group launched-and-terminated in a loop for 28 min | Added the SLR `Encrypt/Decrypt/CreateGrant` grants — eventually deleted the CMK entirely (above) |
| 16 | VPC-CNI addon rejected `ENABLE_NETWORK_POLICY` env var | Moved to top-level `enableNetworkPolicy` + `nodeAgent.enabled` (v1.14+ schema) |
| 17 | `aws_iam_openid_connect_provider.github` collided (already exists in account) | Switched to `data` source |
| 18 | ECR repo name `counter-service` taken by another candidate | Renamed to `counter-service-prod` (uses `var.cluster_name`) |
| 19 | SCP denied `s3:PutBucketPublicAccessBlock` | Dropped the resource (default BPA on new buckets is on) |
| 20 | EKS 1.31 needed Extended Support (denied by SCP) | Bumped to 1.34 |

---

## 11. Trade-offs an interviewer might drill on

### "Why Redis instead of just a file on a PVC?"
RWO PVC forces `replicas: 1` → blocks HA, blocks horizontal autoscaling.
Redis with `INCR` is atomic, lets 3+ replicas share state. SPOF is the
single Redis pod (documented, Sentinel/Cluster upgrade path noted).

### "Why not DynamoDB for the counter?"
Considered. Adds AWS service dependency + IAM surface + ~10ms latency vs
<1ms for in-cluster Redis. For a counter, overkill. Reasonable if we
ever wanted cross-region.

### "Why Cluster Autoscaler instead of Karpenter?"
CA was already configured via the EKS managed node group (which IS an ASG).
Karpenter is faster + more efficient but adds CRDs (NodePool, NodeClass)
and a substantial setup story. For a 2-6 node t3.medium fleet, CA is
adequate.

### "Why STANDARD support (other than the requirement)?"
EKS Extended Support charges $0.50/cluster/hour on top of the standard
$0.10. STANDARD requires running supported K8s versions and accepting
forced upgrades. The assignment account explicitly denies EXTENDED via SCP.

### "Why is the GitHub OIDC role's IAM scope still `PowerUserAccess`?"
PowerUserAccess covers everything except IAM. We need IAM (the role creates
other roles), so a separate inline policy adds IAM ops scoped to project
resources. The alternative (enumerating every EC2/EKS/KMS/etc. action) is
brittle — every new TF feature requires a policy update. PowerUserAccess +
scoped IAM is the assignment-grade compromise; a permissions boundary
would tighten further in real prod.

### "Why not use a SQL database for the bonus integration?"
That's Task 2.

### "Why JSON for IAM policies (templatefile) instead of HCL `aws_iam_policy_document`?"
- Linting: external IAM-policy linters (cfn-policy-validator, parliament) understand JSON, not HCL data sources
- Diff readability in PRs: changes show as JSON, no nesting
- Portability: a JSON IAM policy can be copy-pasted into the AWS console or a different IaC tool
- Symmetry: the same template structure works for KMS key policies, S3 bucket policies, etc.

### "What happens if the ALB health check fails?"
Pod is marked unhealthy on the target group → drained over 60s (idle
timeout) → traffic routes around it → kubelet's `livenessProbe` failure
on `/healthz` restarts the container. If all replicas fail, ALB returns
503 — HPA would scale up if metrics say so (won't help if it's a code
bug).

### "How long does a full apply from scratch take?"
~20-25 min: 5min VPC, 12min EKS cluster, 2min node group, 2min addons,
3min helm releases.

### "What's the steady-state cost?"
~$6-7/day: EKS control plane ($2.40/day), 2-3 t3.medium nodes (~$3/day),
single NAT (~$1.20/day), ALB (~$0.50/day), EBS+ECR+S3+KMS+CloudWatch all
tiny.

### "How do you roll back a bad deploy?"
- `argocd app rollback counter-service <prior-revision-id>` → ArgoCD syncs to a previous git revision
- OR `git revert <commit-sha> && git push` → next sync brings it back
- OR `kubectl rollout undo deployment/counter-service -n prod` → immediate, drifts from git (ArgoCD will resync to current main, so use this only for emergency stop)

---

## 12. Live verification (at the time of writing)

- **URL**: <http://k8s-prod-counters-5c27526452-245847380.eu-west-2.elb.amazonaws.com/>
- **GET /version** → `0.1.1`
- **GET /** → `counter-service v0.1.1\ncount: 36+`
- **ArgoCD**: Synced + Healthy
- **CI**: both workflows green on main
- **Trivy**: 0 HIGH/CRITICAL
- **Tests**: 24/24 at 100% coverage
- **Pods**: 3× counter-service + 1× redis, all Ready
- **Nodes**: 3× t3.medium across 3 AZs
- **Helm releases**: all 7 deployed

---

## 13. Things explicitly NOT done (with reasons)

- **TLS at the ALB**: assignment specifies port 80; ACM + HTTPS listener is a 5-line annotation change but not in scope
- **Tracing**: OTel/X-Ray noted as a follow-up; metrics + structured logs cover the observability requirement
- **Canary/blue-green**: rolling update with `maxUnavailable: 0` is the chosen strategy; canary via Argo Rollouts is a separate operator
- **Multi-region**: single-region assignment; multi-region would mean Route 53 health checks + global accelerator + cross-region Redis (or DynamoDB Global Table)
- **KEDA for request-rate scaling**: CPU-based HPA is adequate for the workload's profile (cheap atomic INCR)

---

## 14. PR history (the narrative)

Every fix was a separate PR, merge-and-recover style. Ordered:

1. `feat: initial counter-service implementation` — everything from scratch
2. `fix: post-apply corrections from real EKS provisioning` — KMS, VPC-CNI, image-updater field, ESO depends_on
3. `fix: redis ingress policy + AWS-managed EBS key` — found during pod-startup debugging
4. `fix(ci): trivy-action version + bump to v0.1.1 (CD demo)` — first version bump
5. `fix(ci): correct ECR repo name` — counter-service → counter-service-prod
6. `fix(ci): make Trivy gate warn-only for CD demo` — temporary, later reverted
7. `deploy: bump image tag to 72641a85 (v0.1.1 CD demo)` — manual stand-in for image-updater
8. `deploy: bump version label to 0.1.1` — wired the version through to /version
9. `docs: surface live URL + commit full evidence bundle`
10. `fix: unbreak both CI pipelines + refactor IAM policies to JSON templates` — the audit's first big fix
11. `fix(ci): terraform workflow plan conditional` — unblocks workflow_dispatch with action=apply
12. `fix(eks): enumerate access entries explicitly` — solves the cluster_creator race
13. `fix(eks): bootstrap_admin_arn as variable` — clean up
14. **`chore: address audit findings (security, testing, docs, cleanup)`** — the comprehensive cleanup

---

## 15. Cost-of-running reminder

Destroy when done: `cd infra/envs/prod && terraform destroy`. The
bootstrap state bucket stays unless you also `cd infra/bootstrap &&
terraform destroy` — that's the one manual step at the end.

If destroy hangs on resources Terraform can't see (orphaned LB target
groups, ENIs from the VPC CNI), the standard recipe is:
1. Delete the Argo CD application first → removes K8s resources
2. Delete the Ingress → AWS LBC tears down the ALB cleanly
3. Then `terraform destroy`
