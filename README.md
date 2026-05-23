# counter-service

> Nano-service home assignment for Check Point. A Python counter service that
> counts `POST` requests and returns the running total on `GET`. Containerised,
> deployed to EKS via Argo CD, and managed end-to-end through GitHub Actions.

Fork of [shainberg/counter-service](https://github.com/shainberg/counter-service)
(upstream was empty — service is authored from scratch in this repo).

---

## Repository layout

```
counter-service/
├── service/                  # Python app: FastAPI + Redis backend
│   ├── app/                  #   source
│   ├── tests/                #   pytest suite (16 tests, 92% cov)
│   ├── Dockerfile            #   multi-stage; distroless runtime (~168 MB)
│   └── pyproject.toml        #   deps + ruff + mypy + pytest config
├── infra/                    # Terraform
│   ├── bootstrap/            #   one-shot: S3 + DynamoDB state backend
│   └── envs/prod/            #   VPC, EKS, ECR, IAM, Helm add-ons
├── deploy/                   # Kustomize manifests
│   ├── base/                 #   Deployment, Service, Ingress, HPA, PDB,
│   │   └── redis/            #   NetworkPolicies, ServiceMonitor, Redis
│   └── overlays/prod/        #   prod image override + version labels
├── gitops/apps/              # Argo CD Application resource (the CD entrypoint)
├── observability/dashboards/ # Grafana dashboard JSON
├── .github/workflows/        # GH Actions: service-ci, terraform
└── evidence/                 # Screenshots / kubectl outputs for submission
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
```

---

## How to provision the cluster

The cluster is fully described as Terraform. Two `terraform apply`s away from a
working stack.

### 0. Workstation prerequisites

| Tool       | Version (tested) | Install                                      |
|------------|------------------|----------------------------------------------|
| AWS CLI v2 | 2.34+            | `winget install Amazon.AWSCLI`               |
| Terraform  | 1.9+             | `winget install Hashicorp.Terraform`         |
| kubectl    | 1.34+            | bundled with Docker Desktop / `winget`       |
| Helm       | 4.1+             | `winget install Helm.Helm`                   |
| eksctl     | 0.226+           | `winget install eksctl.eksctl` (optional)    |
| Python     | 3.11             | `winget install Python.Python.3.11`          |
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
# Outputs: state_bucket, lock_table, kms_key_arn — save them.
```

This is the **only** Terraform apply you run by hand. It creates the
KMS-encrypted, versioned S3 bucket and the DynamoDB lock table that the rest of
the IaC will use. From this point on the `terraform` workflow in GitHub Actions
takes over.

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
  -backend-config="bucket=<state_bucket from step 2>" \
  -backend-config="dynamodb_table=<lock_table from step 2>"
terraform apply
```

This provisions, in eu-west-2:

- VPC across 3 AZs, with private subnets + single NAT (cost-trim, document trade-off below)
- EKS 1.31 cluster, **`support_type = STANDARD`** (assignment hard requirement)
  - Managed node group: 2 × `t3.medium` (min 2, max 6), encrypted gp3 EBS, KMS CMK
  - Secret-at-rest encrypted with project-scoped KMS CMK
  - IRSA enabled, OIDC provider exposed
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

1. `service-ci` workflow runs: ruff → mypy → pytest → docker build → Trivy → push image to ECR with tag `<commit-sha>`.
2. `argocd-image-updater` polls ECR (every ~2 min), sees the new tag, opens a commit on `main` that bumps `images[0].newTag` in `deploy/overlays/prod/kustomization.yaml`.
3. Argo CD reconciles the Application; rolling update in the `prod` namespace.
4. `curl http://<alb-host>/` returns the new version string.

### Smoke-test

```bash
ALB=$(kubectl get ingress counter-service -n prod -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl http://$ALB/                          # counter-service vX.Y.Z\ncount: 0
curl -X POST http://$ALB/                  # count: 1
curl -X POST http://$ALB/                  # count: 2
curl http://$ALB/                          # ... count: 2
curl http://$ALB/healthz                   # ok
curl http://$ALB/readyz                    # ready
curl http://$ALB/version                   # X.Y.Z
curl http://$ALB/metrics | head            # Prometheus exposition
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
sed -i 's/version = "0.1.0"/version = "0.1.1"/' service/app/__init__.py
git commit -am "bump 0.1.1"
git push

# Watch the chain
gh run watch                                  # CI build
kubectl -n prod logs -l app.kubernetes.io/name=counter-service --tail=20 -f
curl http://$ALB/version                      # should flip to 0.1.1
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
  The role is locked down to ECR push/pull on the counter-service repo and is
  scoped via the OIDC sub claim to `MichaelF21/counter-service` on `main`,
  `pull_request`, and `environment:prod` contexts only.
- **Application secrets** — managed via External Secrets Operator. ESO has IRSA
  permissions to read secrets under `counter-service/*` in AWS Secrets Manager
  only. To add a secret:
  ```bash
  aws secretsmanager create-secret --name counter-service/foo --secret-string ...
  # ExternalSecret CR in deploy/base/external-secrets/ syncs it into prod ns.
  ```
- **Terraform state** — encrypted at rest with project-scoped KMS CMK, S3
  versioning + 90-day non-current expiration, DynamoDB lock table with PITR.
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

- **Container**: distroless base (no shell, no apt, ~168 MB), non-root UID 65532, `readOnlyRootFilesystem`, all caps dropped, `seccompProfile: RuntimeDefault`, no service-account token mounted.
- **Namespace**: `pod-security.kubernetes.io/enforce: restricted` — any future workload here must meet the same bar.
- **Network**: default-deny ingress; only ALB and Prometheus can reach :8080. Egress restricted to Redis + DNS.
- **Image registry**: immutable ECR tags + scan-on-push, KMS-encrypted; Trivy gate blocks merges on HIGH/CRITICAL CVEs.
- **State**: all storage encrypted with project-scoped KMS CMKs (EBS, EKS secrets, ECR, S3 state, DynamoDB).
- **IAM**: GH OIDC + IRSA, no long-lived keys anywhere. Each component has a scoped role.
- **Secrets**: AWS Secrets Manager → ESO → K8s Secret; nothing in git.

---

## Evidence

Screenshots and `kubectl` outputs collected in `evidence/`:

- `evidence/ci-success.png` — GH Actions service-ci green run, image pushed to ECR.
- `evidence/cd-sync.png` — Argo CD UI showing synced + healthy Application.
- `evidence/kubectl-prod.txt` — `kubectl get deploy,svc,ingress,hpa,pdb,networkpolicy,pods -n prod -o wide`.
- `evidence/curl-counter.txt` — terminal session showing GET → POST → POST → GET working through the live ALB.
- `evidence/version-bump.txt` — commit → CI → image-updater commit → live ALB serving the new version string.
- `evidence/grafana.png` — dashboard with metrics visible.

---

## Local development

```bash
cd service
py -3.11 -m venv .venv
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
