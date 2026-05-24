# counter-service

> Nano-service home assignment for Check Point. A Python counter service that
> counts `POST` requests and returns the running total on `GET`. Containerised,
> deployed to EKS via Argo CD, and managed end-to-end through GitHub Actions.

**Live URL** (HTTP, port 80):
<http://k8s-prod-counters-5c27526452-245847380.eu-west-2.elb.amazonaws.com/>

```bash
$ curl http://k8s-prod-counters-5c27526452-245847380.eu-west-2.elb.amazonaws.com/
counter-service v0.2.0
count: 38

$ curl -X POST http://k8s-prod-counters-5c27526452-245847380.eu-west-2.elb.amazonaws.com/
count: 39

$ curl -X POST http://k8s-prod-counters-5c27526452-245847380.eu-west-2.elb.amazonaws.com/ingest \
    -H 'content-type: application/json' \
    -d '{"date":"2026-05-24","counter_values":42,"restart_count":3}'
ingested            # writes to the Crossplane-provisioned Postgres table — see Task 2 below
```

The ALB will be torn down when this AWS account is reclaimed; full evidence
(curl sessions, kubectl outputs, CI logs, CD round-trip from v0.1.0 → v0.2.0
propagating live) is committed under `evidence/` and `crossplane/evidence/`.

**Task 2** (Crossplane API for declarative Postgres provisioning) is built on top of
the same cluster — see [`crossplane/README.md`](crossplane/README.md).

Fork of [shainberg/counter-service](https://github.com/shainberg/counter-service)
(upstream was empty — service is authored from scratch in this repo).

---

## Repository layout

```
counter-service/
├── service/                  # Python app: FastAPI + Redis + optional Postgres ingest
│   ├── app/                  #   source (main, counter, ingest, metrics, config, logging)
│   ├── tests/                #   33 pytest tests, 96.6% line coverage (gate 90%)
│   ├── Dockerfile            #   multi-stage; distroless py-debian13 runtime (~149 MB)
│   └── pyproject.toml        #   deps + ruff + mypy strict + pytest config
├── infra/                    # Terraform (1.10+)
│   ├── bootstrap/            #   one-shot: KMS-encrypted versioned S3 state bucket
│   └── envs/prod/            #   VPC, EKS, ECR, IAM (JSON-templated), Helm add-ons
│       └── policies/         #   IAM trust + permissions docs as standalone .json.tpl
├── deploy/                   # Kustomize manifests
│   ├── base/                 #   Deployment, Service, Ingress, HPA, PDB,
│   │   └── redis/            #   NetworkPolicies, ServiceMonitor, Redis
│   └── overlays/prod/        #   prod image + version labels + Task 2 ingest wiring
├── crossplane/               # Task 2: XAppDatabase API
│   ├── prereq/               #   in-cluster Postgres StatefulSet
│   ├── platform/             #   Providers, Functions, XRD, Composition
│   ├── examples/             #   minimal, two-tables, counter-data XRs
│   └── README.md             #   deep-dive on Task 2
├── gitops/apps/              # Argo CD Application resource (the CD entrypoint)
├── observability/dashboards/ # Grafana dashboard JSON
├── .github/workflows/        # GH Actions: service-ci, terraform
└── evidence/                 # kubectl outputs, curl sessions, CD round-trip log
```

---

## Architecture

```
                                  Internet
                                     │
                                     ▼
                   ┌──────────────────────────────────┐
                   │   AWS ALB (internet-facing :80)  │  ← provisioned by
                   └──────────────────────────────────┘    AWS Load Balancer
                                     │                     Controller from
                                     ▼                     our Ingress
                   ┌──────────────────────────────────┐
                   │  Service: counter-service:8080   │
                   └──────────────────────────────────┘
                                     │
              ┌──────────────────────┼──────────────────────┐
              ▼                      ▼                      ▼
   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
   │ counter-service  │  │ counter-service  │  │ counter-service  │
   │  Pod (AZ-a)      │  │  Pod (AZ-b)      │  │  Pod (AZ-c)      │
   │ FastAPI/uvicorn  │  │ FastAPI/uvicorn  │  │ FastAPI/uvicorn  │
   └────────┬─────────┘  └────────┬─────────┘  └────────┬─────────┘
            └───────────────┬─────┴───────────────┬─────┘
                            ▼                     │
                  ┌──────────────────┐            │ /metrics
                  │  Redis (PVC, AOF)│            │ scrape
                  │   StatefulSet    │            ▼
                  └──────────────────┘   ┌──────────────────┐
                                         │   Prometheus     │
                                         │   + Grafana      │
                                         └──────────────────┘

Source code commit → GH Actions builds image → pushes to ECR
                  → argocd-image-updater bumps tag in this repo
                  → Argo CD reconciles → rolling update in prod ns

Optional /ingest endpoint (Task 2):
   counter-service Pod ──asyncpg──> Postgres (db namespace)
                       └─ DB, schema, user, table all provisioned by an
                          XAppDatabase Crossplane Composition; the
                          connection Secret is published into the prod
                          namespace and mounted as env vars.
                          See crossplane/README.md for full detail.
```

---

## How to provision the cluster

The cluster is fully described as Terraform. Two `terraform apply`s away from a
working stack.

### 0. Workstation prerequisites

| Tool       | Version (tested) | Install                                      |
|------------|------------------|----------------------------------------------|
| AWS CLI v2 | 2.34+            | `winget install Amazon.AWSCLI`               |
| Terraform  | 1.10+            | `winget install Hashicorp.Terraform`         |
| kubectl    | 1.34+            | bundled with Docker Desktop / `winget`       |
| Helm       | 3.16+            | `winget install Helm.Helm`                   |
| eksctl     | 0.226+           | `winget install eksctl.eksctl` (optional)    |
| Python     | 3.13+            | `winget install Python.Python.3.13`          |
| Docker     | 29+              | Docker Desktop                               |
| gh         | 2.92+            | `winget install GitHub.cli`                  |

### 1. AWS credentials

```bash
aws configure --profile chkp-apollo   # paste Access Key ID + Secret
export AWS_PROFILE=chkp-apollo
aws sts get-caller-identity           # should return account 4793, region eu-west-2
```

### 2. Bootstrap the Terraform state backend

```bash
cd infra/bootstrap
terraform init
terraform apply \
  -var "state_bucket_name=counter-service-tfstate-<your-suffix>"
# Outputs: state_bucket, kms_key_arn — save them.
```

This is the **only** Terraform apply you run by hand. It creates the
KMS-encrypted, versioned S3 bucket that the rest of the IaC will use as its
remote backend. State locking is handled by S3 itself (Terraform 1.10+
`use_lockfile = true`), no DynamoDB table needed. From this point on the
`terraform` workflow in GitHub Actions takes over.

### 3. Configure GitHub repository secrets

In the repo settings → Secrets and variables → Actions, add:

| Secret                   | Source                                           |
|--------------------------|--------------------------------------------------|
| `AWS_OIDC_ROLE_ARN`      | `aws_iam_role.github_actions.arn` (TF output)    |
| `TF_STATE_BUCKET`        | output of step 2                                 |

Bootstrap is chicken-and-egg: the GitHub OIDC role is created by the prod TF,
but the prod TF needs OIDC creds to apply. For the very first run, apply the
prod env once locally (`aws sso login` / your admin creds), then add the
secrets and let CI take over.

### 4. Apply the prod environment

Push to `main` — the `terraform` workflow runs `plan` on every PR and `apply`
on every push to `main`, gated by the `prod` GitHub environment (configure
required reviewers there for two-person control).

Or locally for the first run:

```bash
cd infra/envs/prod
terraform init \
  -backend-config="bucket=<state_bucket from step 2>"
terraform apply
```

This provisions, in eu-west-2:

- VPC across 3 AZs, with private subnets + single NAT (cost-trim, document trade-off below)
- EKS 1.34 cluster, **`support_type = STANDARD`** (assignment hard requirement)
  - Managed node group: 2 × `t3.medium` (min 2, max 6), gp3 EBS volumes encrypted with the AWS-managed `aws/ebs` key
  - Secret-at-rest encrypted with a project-scoped KMS CMK
  - IRSA enabled, OIDC provider exposed
  - Two EKS access entries (bootstrap operator + GitHub Actions OIDC role) for kubectl/Helm access
  - Add-ons: CoreDNS, kube-proxy, VPC-CNI (network-policy enforcement on), EBS CSI
- ECR repo `counter-service-prod` (the bare `counter-service` name was already taken in this shared account) — KMS-encrypted, immutable tags, scan-on-push, 30-image retention
- Cluster add-ons via Helm:
  - AWS Load Balancer Controller (ALB provisioning)
  - Cluster Autoscaler (node scale 2→6)
  - metrics-server (HPA input)
  - kube-prometheus-stack (Prometheus + Grafana + ServiceMonitor watcher)
  - External Secrets Operator (Secrets Manager → K8s Secret)
  - Argo CD + argocd-image-updater (CD)
- GitHub Actions OIDC role (no static keys in CI)

### 5. Bootstrap Argo CD apps

Once `terraform apply` completes, point kubectl at the cluster and apply the
Argo CD Application:

```bash
aws eks update-kubeconfig --name counter-service-prod --region eu-west-2
kubectl apply -f gitops/apps/counter-service-app.yaml
```

Argo CD takes over from here.

---

## How to deploy and test

### Trigger a deploy

```bash
echo "// touch $(date)" >> service/app/main.py
git commit -am "demo: bump version"
git push
```

What happens:

1. `service-ci` workflow runs: ruff → mypy → pytest → docker build → Trivy (fail-on-HIGH) → push image to ECR with tag `<commit-sha>`.
2. `argocd-image-updater` polls ECR (every ~2 min) and is configured to commit a tag bump to `deploy/overlays/prod/kustomization.yaml`. *Known limitation*: the ECR auth helper script in the current chart needs a one-line output-format tweak before the auto-bump completes, so the demo flow has been driven by small `deploy/v*` PRs (see commit history) — the end result on the cluster is identical to what image-updater would produce.
3. Argo CD reconciles the Application; rolling update in the `prod` namespace.
4. `curl http://<alb-host>/version` returns the new version string.

### Smoke-test

```bash
ALB=$(kubectl get ingress counter-service -n prod -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl http://$ALB/                          # counter-service vX.Y.Z\ncount: N
curl -X POST http://$ALB/                  # count: N+1
curl -X POST http://$ALB/                  # count: N+2
curl http://$ALB/                          # ... count: N+2
curl http://$ALB/healthz                   # ok
curl http://$ALB/readyz                    # ready
curl http://$ALB/version                   # X.Y.Z
curl http://$ALB/metrics | head            # Prometheus exposition

# Task 2 ingest endpoint — writes into the Crossplane-provisioned Postgres
curl -X POST http://$ALB/ingest -H 'content-type: application/json' \
  -d '{"date":"2026-05-24","counter_values":42,"restart_count":3}'   # ingested
```

### Verify HA and scaling

```bash
kubectl get deploy,svc,ingress,hpa,pdb,networkpolicy -n prod
kubectl get pods -n prod -o wide              # spread across AZs
kubectl delete pod -n prod -l app.kubernetes.io/name=counter-service  # PDB protects
kubectl drain $(kubectl get nodes -o name | head -1) --ignore-daemonsets  # graceful

# Generate load and watch HPA scale up
ab -n 100000 -c 50 http://$ALB/               # or `hey`, `wrk`
kubectl get hpa -n prod -w
```

### Verify CD round-trip

```bash
# Bump the version
sed -i 's/__version__ = "0.2.0"/__version__ = "0.2.1"/' service/app/__init__.py
git commit -am "bump 0.2.1"
git push

# Watch the chain
gh run watch                                  # CI build
kubectl -n prod logs -l app.kubernetes.io/name=counter-service --tail=20 -f
curl http://$ALB/version                      # should flip to 0.2.1
```

### Observability

```bash
# Grafana (admin/admin — rotate before opening to the team)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# Browse to http://localhost:3000 — import observability/dashboards/counter-service.json.

# Structured logs
kubectl logs -n prod -l app.kubernetes.io/name=counter-service | jq .
```

---

## How to configure credentials and secrets safely

- **AWS access from CI** — GitHub Actions uses OIDC against the
  `counter-service-prod-gha-ci` IAM role. No long-lived access keys live in GH.
  The role is scoped via the OIDC `sub` claim to `MichaelF21/counter-service`
  on `main`, `pull_request`, and `environment:prod` contexts only.
  Permissions:
  - AWS managed `PowerUserAccess` (everything except IAM) for the bulk of the TF refresh/apply surface
  - A scoped inline IAM policy (`policies/github-actions-iam.json.tpl`) granting IAM ops **only** on resources matching `counter-service-prod-*`, `default-eks-node-group-*`, the project OIDC provider, and read of AWS-managed policies
  - A separate inline policy (`policies/github-actions-inline.json.tpl`) for ECR push/pull on the counter-service-prod repo + R/W on the TF state bucket + KMS for state
  A compromised CI role cannot touch unrelated IAM principals in this shared account.
- **Application secrets** — managed via External Secrets Operator. ESO has IRSA
  permissions to read secrets under `counter-service/*` in AWS Secrets Manager
  only. To add a secret:
  ```bash
  aws secretsmanager create-secret --name counter-service/foo --secret-string ...
  # ExternalSecret CR in deploy/base/external-secrets/ syncs it into prod ns.
  ```
- **Terraform state** — encrypted at rest with a project-scoped KMS CMK, S3
  versioning + 90-day non-current expiration. State locking via S3 conditional
  writes (`use_lockfile = true`, Terraform 1.10+) — no DynamoDB table needed.
- **TLS to ALB** — currently HTTP only (assignment specifies port 80). In real
  prod, add ACM cert + HTTPS listener annotations on the Ingress.
- **Kubeconfig & local state** — `.gitignore` excludes `kubeconfig*`, `*.csv`,
  `.env*`, `*.tfstate*`, `.terraform/`.

---

## How to run the pipeline

| Trigger | Workflow | What it does |
|---|---|---|
| PR touching `service/` or `deploy/` | `service-ci` (test, manifests-validate) | ruff + mypy + pytest, kustomize render + kubeconform |
| Push to `main` touching `service/` or `deploy/` | `service-ci` full | + build + Trivy + push image to ECR |
| PR touching `infra/` | `terraform` (plan only) | fmt-check + init + validate + plan, uploads plan artifact |
| Push to `main` touching `infra/` | `terraform` (apply) | plan → apply, gated by `prod` environment reviewers |
| `workflow_dispatch` | manual plan / apply / destroy | uses input `action` |

Pre-merge: every PR runs lint, type-check, tests, manifest validation, and
Terraform plan. Apply is post-merge only.

---

## Notes on HA, scaling, persistence, and trade-offs

### High availability

- **3 replicas** of counter-service, `topologySpreadConstraints` across both AZs and nodes (`maxSkew: 1`).
- **PodDisruptionBudget** `minAvailable: 2` blocks voluntary disruptions (node drains, autoscaler scale-downs) that would drop us to 1 replica.
- **Rolling updates** with `maxSurge=1, maxUnavailable=0` — always at least 3 ready during deploys.
- **Multi-AZ control plane**: EKS managed across all 3 AZs by default; node group spans the 3 private subnets.
- **NAT trade-off**: `single_nat_gateway = true` for assignment cost-trim. For real prod, flip to `single_nat_gateway = false` so each AZ has its own NAT (no cross-AZ data charges, and AZ-isolated egress on NAT failure).

### Scaling

- **Workload**: HPA v2 watches CPU (70% target) + memory (80% target), `minReplicas: 3, maxReplicas: 10`. Scale-up reacts within 30s; scale-down has a 5-min stabilization window to avoid flapping.
- **Nodes**: Cluster Autoscaler with `auto-discovery` against the EKS managed node group; min 2, max 6 `t3.medium`.
- **Future**: KEDA for request-rate-based scaling (Prometheus query against `counter_http_requests_total`). Would scale ahead of CPU saturation under bursty traffic. Not wired by default — counter increments are cheap (Redis `INCR`) so CPU-based scaling tracks load adequately for this workload.

### Persistence: trade-off discussion

Three options were considered; the implemented choice is **Redis in-cluster**.

| Option | How | Pros | Cons |
|---|---|---|---|
| **Redis (chosen)** | Single-replica StatefulSet with AOF on, 1 GiB encrypted gp3 PVC. `INCR` is atomic. | Sub-ms reads/writes; multiple service replicas safely increment the same key; survives pod/node loss via the PVC; tiny resource footprint. | Single Redis pod = single SPOF for writes during failover (~10-30s of unavailability on pod reschedule). AOF gives at-most-1-second data loss. Upgrade path: Sentinel or Cluster mode. |
| **File on PVC** | `RWO` PVC mounted in counter-service, atomically rewritten on every POST. | Simplest; no extra component. | Forces `replicas: 1` because RWO can't be shared. Blocks HA, blocks horizontal autoscaling. Bad for the brief. |
| **DynamoDB** | `UpdateItem` with `ADD` for atomic increment. | Fully managed, multi-region capable, encrypted. | Adds AWS service dependency, more IAM surface, ~10ms latency vs <1ms for in-cluster Redis. Overkill for a counter; reasonable if we ever wanted true cross-region. |

Why Redis won: meets the HA/multi-replica requirement, atomic increments via `INCR`, minimal moving parts, and lets us still demonstrate PVC persistence (the StatefulSet's `volumeClaimTemplate`). The trade-off comments in `deploy/base/redis/redis-statefulset.yaml` flag the SPOF and document the Sentinel/Cluster upgrade path.

### Failure modes considered

| Failure | What happens |
|---|---|
| counter-service pod crash | Liveness probe failure → kubelet restart; PDB keeps 2 replicas serving. |
| counter-service node drain | Pod evicted; topology spread + 3 replicas → 2 stay up; ALB routes around the draining target. |
| Redis pod crash | StatefulSet reschedules within ~10s; PVC reattached; AOF replays. Counter resumes from last fsync (≤1s data loss). |
| ECR pull failure | `imagePullPolicy: IfNotPresent` + node-level credential cache (IRSA via node role) — already-pulled images stay running; transient registry errors don't cascade. |
| ALB target unhealthy | `/healthz` probe drives deregistration within 15s; HPA may add replicas if all targets are draining. |
| Argo CD desync | Self-heal + retry with exponential backoff; manual rollback via `argocd app rollback` or `git revert`. |

### Security posture

- **Container**: distroless base (Python 3.13 on Debian 13, no shell, no apt, **149 MB**), non-root UID 65532, `readOnlyRootFilesystem`, all caps dropped, `seccompProfile: RuntimeDefault`, no service-account token mounted. Build-only deps (pip, setuptools, wheel) are stripped from the runtime venv to remove transitive CVEs.
- **Namespace**: `pod-security.kubernetes.io/enforce: restricted` — any future workload here must meet the same bar.
- **Network**: default-deny ingress in `prod` ns; per-pod allowlists open only the paths the workloads actually need (ALB+Prometheus → counter-service:8080; counter-service → counter-redis:6379; counter-service → postgres.db:5432; counter-service → kube-dns).
- **Image registry**: immutable ECR tags + scan-on-push, KMS-encrypted with project CMK; Trivy gate in CI **fails the build on HIGH/CRITICAL** (currently 0 findings).
- **State**: EKS secrets + ECR + S3 state encrypted with project-scoped KMS CMKs. EBS volumes (node root disks and Redis PVC) use the AWS-managed `aws/ebs` key — the CSI driver requires a customer-managed key policy that grants both the AutoScaling SLR and the CSI IRSA role, which is more setup than the encryption-at-rest requirement actually needs.
- **IAM**: GH OIDC + IRSA, no long-lived keys anywhere. IRSA roles for AWS LBC, ESO, Cluster Autoscaler, EBS CSI, ArgoCD image-updater — each scoped to the minimum AWS API surface. All IAM trust + permissions policies live as `.json.tpl` files under `infra/envs/prod/policies/`, rendered via `templatefile()`.
- **Secrets**: AWS Secrets Manager → ESO → K8s Secret; nothing in git.

---

## Evidence

CLI captures of the live cluster + delivery pipeline:

| File | What it shows |
|---|---|
| `evidence/kubectl-prod.txt` | `kubectl get all,ingress,hpa,pdb,networkpolicy -n prod -o wide` + nodes + helm releases + argocd app + terraform outputs |
| `evidence/live-alb-session.txt` | curl session through the public ALB — GET, POSTs, GET, /healthz, /readyz, /version, /metrics |
| `evidence/cd-demo-roundtrip.txt` | commit → CI → tag bump → ArgoCD sync → live ALB serving new version (0.1.0 → 0.1.1 round trip) |
| `evidence/local-compose-smoke.txt` | docker-compose run proving Redis persistence across counter-service restarts |
| `crossplane/evidence/task2-live.txt` | XR + composed MRs Ready, psql `\dt`, `/ingest` writes rows |

CI runs are visible at `gh run list --repo MichaelF21/counter-service` — every push to `main` since the
audit cleanup has both `service-ci` and `terraform` workflows green.

---

## Local development

```bash
cd service
py -3.13 -m venv .venv
.venv\Scripts\activate         # or source .venv/bin/activate on *nix
pip install -e ".[dev]"

# Run with in-memory backend
uvicorn app.main:app --reload

# Run with local Redis
docker run -d --name dev-redis -p 6379:6379 redis:7-alpine
COUNTER_BACKEND=redis COUNTER_REDIS_URL=redis://localhost:6379/0 uvicorn app.main:app --reload

# Tests + coverage
pytest

# Lint + types
ruff check app tests
mypy app

# Docker
docker build --build-arg APP_VERSION=dev -t counter-service:dev .
docker run --rm -p 8080:8080 counter-service:dev
```

---

## License

MIT (inherited from upstream).
