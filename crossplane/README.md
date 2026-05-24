# Crossplane: `XAppDatabase` API for Postgres tables

A Kubernetes-native API that lets application teams provision a Postgres
database + schema + tables + connection Secret with a single YAML.

```yaml
apiVersion: database.platform.example.com/v1alpha1
kind: AppDatabase            # the Claim — namespace-scoped, for app teams
metadata: { name: orders-db, namespace: my-team }
spec:
  parameters:
    database: app_orders
    tables:
      - name: users
        columns:
          - { name: id,    type: "serial primary key" }
          - { name: email, type: "varchar(255) not null unique" }
  writeConnectionSecretToRef: { name: orders-db-conn }
```

Apply that → a few seconds later the team's namespace has an
`orders-db-conn` Secret with `host`, `port`, `database`, `schema`, `username`,
`password`, `dsn`. They mount it as env vars or via ESO and they're done.

---

## What's in this directory

```
crossplane/
├── prereq/
│   └── postgres.yaml          # Vanilla Postgres 16 StatefulSet (in-cluster prereq)
├── platform/                  # Platform-team owned — install once
│   ├── providers/
│   │   ├── providers.yaml          # Provider + DeploymentRuntimeConfig
│   │   └── provider-configs.yaml   # ProviderConfig + RBAC
│   ├── functions/
│   │   └── functions.yaml          # 3 Crossplane Functions
│   └── xrd/
│       ├── xappdatabase.yaml       # CompositeResourceDefinition + Claim
│       └── composition.yaml        # Composition (Pipeline mode)
├── examples/                  # What app teams write
│   ├── minimal.yaml                # 1 db, 1 table
│   ├── two-tables.yaml             # 2 tables with FK relationship
│   └── counter-data.yaml           # Used by counter-service /ingest
└── README.md
```

---

## Install (top to bottom)

Prereqs: an EKS cluster (see Task 1) and `kubectl` pointed at it.

```bash
# 1. Postgres (the "existing PostgreSQL instance" the assignment refers to).
kubectl apply -f crossplane/prereq/postgres.yaml
kubectl wait --for=condition=Ready pod/postgres-0 -n db --timeout=2m

# 2. Crossplane core.
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system --create-namespace \
  --version 1.18.0 --wait

# 3. Providers + Functions.
kubectl apply -f crossplane/platform/providers/providers.yaml
kubectl apply -f crossplane/platform/functions/functions.yaml
kubectl wait --for=condition=Healthy provider --all --timeout=5m
kubectl wait --for=condition=Healthy function --all --timeout=5m

# 4. ProviderConfigs + RBAC.
kubectl apply -f crossplane/platform/providers/provider-configs.yaml

# 5. The platform API (CRD + Composition).
kubectl apply -f crossplane/platform/xrd/xappdatabase.yaml
kubectl apply -f crossplane/platform/xrd/composition.yaml
```

That's it — the `AppDatabase` and `XAppDatabase` kinds are now usable.

---

## Test it

```bash
kubectl apply -f crossplane/examples/minimal.yaml
kubectl get xappdatabase                  # wait for READY=True

# Verify the database + table are real:
kubectl exec -n db postgres-0 -- psql -U postgres -d minimal_db -c "\dt"

# Verify the consumer's Secret:
kubectl get secret minimal-db-conn -n default -o yaml

# Delete it — DB + role + secret should all disappear (one orphan Secret remains, see below)
kubectl delete xappdatabase minimal-db
```

For a multi-table example with a foreign key:

```bash
kubectl apply -f crossplane/examples/two-tables.yaml
kubectl exec -n db postgres-0 -- psql -U postgres -d app_orders -c "\dt"
```

---

## How it works (the Composition)

```
                       ┌─────────────────────────────────┐
   AppDatabase   ──>   │ XAppDatabase (cluster-scoped)   │
   (Claim)             └─────────────────────────────────┘
                                       │
                                       │  Composition pipeline:
                                       ▼
              ┌────────────────────────────────────────────────────┐
              │ 1. function-go-templating  (the renderer)          │
              │    Reads spec.parameters and emits:                │
              │      - Database (provider-sql)                     │
              │      - Role (provider-sql)                         │
              │      - Grant (provider-sql)                        │
              │      - Object/Secret with the app password         │
              │      - Object/Job that runs psql with all the      │
              │        CREATE TABLE statements                     │
              │      - Object/Secret with host:port:db:user:pwd    │
              │        in the consumer's namespace                 │
              │      - CompositeConnectionDetails for the XR       │
              └────────────────────────────────────────────────────┘
                                       │
                                       ▼
              ┌────────────────────────────────────────────────────┐
              │ 2. function-auto-ready                             │
              │    Flips XR.status.ready=True once every resource  │
              │    above reports ready.                            │
              └────────────────────────────────────────────────────┘
```

### Why provider-sql for DB/Role/Grant but Jobs for tables?

`provider-sql` natively models `Database`, `Role`, `Grant`, `Schema`,
`Extension`, `DefaultPrivilege` — Crossplane reconciles them with proper
drift detection and clean delete semantics. But there is **no Table MR** in
provider-sql; arbitrary DDL has to go through some kind of executor.

Two options for tables:

| Approach | Pros | Cons |
|---|---|---|
| **Jobs that run `psql`** (chosen) | Standard K8s pattern; idempotent via `CREATE TABLE IF NOT EXISTS`; one place to read all the SQL | Need to handle the deletion cycle (dropped via the parent Database drop, not via a separate Drop-job) |
| Per-table custom MRs (e.g., a homegrown provider extension) | Each table reconciled individually | Big engineering effort to write a provider just for tables |

We rely on the **parent Database drop cascading** to remove all tables —
when `XAppDatabase` is deleted, the `Database` MR's deletion runs
`DROP DATABASE`, which removes the schema and all tables inside. So no
explicit Drop-table Job is needed.

### Why `function-go-templating` for the dynamic parts?

Tables are user-supplied (`spec.parameters.tables[]`). To turn that array
into one `psql -c "CREATE TABLE..."` invocation per table, we need a
template language with `range`. Go templates inside Crossplane's pipeline
mode give us that without leaving the Composition manifest:

```gotemplate
{{- range $t := $tables }}
CREATE TABLE IF NOT EXISTS "{{ $schema }}"."{{ $t.name }}" (
  {{- range $i, $c := $t.columns }}
  {{ if $i }},{{ end }}"{{ $c.name }}" {{ $c.type }}
  {{- end }}
);
{{- end }}
```

Compare to function-patch-and-transform, which can't dynamically size the
output list — you'd be forced into either a fixed-size patch (capped table
count) or a custom function.

---

## Deletion lifecycle

When the XR (or Claim) is deleted:

| Resource | What Crossplane does | What ends up in Postgres |
|---|---|---|
| `Grant` | provider-sql REVOKEs | Gone |
| `Database` | provider-sql `DROP DATABASE` (cascade) | Database, schema, all tables, all data — gone |
| `Role` | provider-sql `DROP ROLE` | Gone — *as long as the password Secret is still readable* (see below) |
| `Job` (create-tables) | K8s deletes the Job object | Job pod logs lost; the DB was already dropped |
| `Object`/conn-Secret | K8s deletes the Secret in the consumer's namespace | n/a |
| `Object`/role-password Secret | **kept** (`deletionPolicy: Orphan`) | n/a — the orphan stays in `crossplane-system` |

### Why the role-password Secret is intentionally orphaned

`provider-sql/Role`'s delete-path runs `observe` first, which reads the
password Secret. If Crossplane deletes that Secret in parallel (the default
for sibling composed resources), the Role MR's delete fails with `cannot
get password secret`, and the Postgres role leaks.

Setting `deletionPolicy: Orphan` on the Secret's `Object` MR keeps the
Secret around long enough for the Role MR to finish its delete. The
Postgres role is dropped cleanly; the now-pointless Secret stays as a
small artifact.

**Cleanup snippet** (run after `kubectl delete xappdatabase`):

```bash
kubectl delete secret -n crossplane-system \
  -l app.kubernetes.io/managed-by=crossplane
```

A future improvement: wire a finalizer Job into the Composition that runs
the cleanup as part of the XR delete. The pattern is documented in the
upstream provider-kubernetes README.

---

## Validation

The XRD's OpenAPI v3 schema validates incoming requests **before any
Composition runs**:

- `database`, `schema`, table names, column names must match `^[a-z][a-z0-9_]{1,62}$`
  (Postgres-safe identifiers; blocks injection vectors in identifier slots).
- `tables` array: 1–50 entries, each with 1–50 columns.
- `column.type` matches a restricted grammar:
  `^[A-Za-z][A-Za-z0-9_]*(\([0-9]+(,[0-9]+)?\))?(\s+(primary\s+key|unique|not\s+null|references\s+...))*$`
  Allows `serial primary key`, `varchar(255) not null unique`,
  `int references users`, `numeric(10,2)`, etc. Rejects anything with
  semicolons, comments, or quote marks — the only SQL-injection vector that
  survives templating is via the `type` field.

A bad request gets rejected by the API server with a clear validation
error; nothing ever reaches provider-sql.

---

## Bonus: counter-service `/ingest` integration

`crossplane/examples/counter-data.yaml` provisions a database `counter_data`
with an `events(date, counter_values, restart_count)` table; the connection
Secret is published into the `prod` namespace.

The Task 1 counter-service consumes it via env vars (see
`deploy/overlays/prod/ingest-env-patch.yaml`) and exposes a new endpoint:

```bash
curl -X POST http://<alb>/ingest -H 'content-type: application/json' \
  -d '{"date": "2026-05-24", "counter_values": 42, "restart_count": 3}'
# -> 201 ingested
```

Implementation lives in `service/app/ingest.py` (asyncpg pool, parameterised
INSERT). Tests in `service/tests/test_ingest.py`. The endpoint returns 503
gracefully when `COUNTER_INGEST_ENABLED=false`, so the service still works
even when Crossplane isn't installed.

---

## Trade-offs an interviewer might drill on

### "Why not use Composition Functions only — drop function-patch-and-transform entirely?"
We did. The Composition uses `function-go-templating` (renders dynamic
SQL) and `function-auto-ready` (flips readiness based on composed
resources). `function-patch-and-transform` is loaded but not used in
this Composition; it's there in case future, simpler XRs want it.

### "Why install Crossplane via Helm and not via Argo CD like everything else?"
Bootstrap order. Argo CD needs the cluster running first; Crossplane is
installed by the same Terraform that runs early in the pipeline. A real
prod setup would put Crossplane in the platform's "first-wave" GitOps app,
applied before any tenant apps.

### "Why a `Claim` if you could just use the XR directly?"
Claims are namespace-scoped → application teams can create one without
needing cluster-wide RBAC. The XR is what Crossplane reconciles
internally; the Claim is the consumer-facing object. Same shape, different
scope.

### "What happens if two `XAppDatabase`s pick the same `spec.parameters.database`?"
The second one's `Database` MR fails to create — Postgres returns
"database already exists". Both XRs go ReconcileError. The XRD validation
doesn't enforce uniqueness across resources (would require an external
controller). Real prod would prefix the DB name with the claim's namespace
(already supported by the schema; just enforce it in policy).

### "What if a database is in use when the XR is deleted?"
provider-sql's `DROP DATABASE` fails if there are open connections. We
don't terminate them. The user has to `kubectl delete xappdatabase` again
after closing clients. A real prod composition would issue
`SELECT pg_terminate_backend(...)` via a pre-delete hook Job.

### "Why does provider-sql need a superuser? Isn't that overscoped?"
Yes. The ProviderConfig credential is the postgres superuser because
creating new databases requires `CREATEDB` privilege. For a multi-tenant
platform you'd create a dedicated `crossplane_admin` Postgres role with
the minimum required privileges (CREATEDB, CREATEROLE) and use that.

### "Why one Composition for everything instead of nested XRs?"
Simplicity. With ~6 composed resources this fits in one template. If we
grew to "platform-wide database service" with sharding/replication/IAM
wiring, we'd split into XPostgresInstance + XAppDatabase + XAppRole and
have the Compositions reference each other.

---

## Cleanup (when done)

```bash
# Delete any XAppDatabases first (so Postgres state is cleaned up):
kubectl delete xappdatabase --all
# Orphaned password Secrets:
kubectl delete secret -n crossplane-system -l app.kubernetes.io/managed-by=crossplane
# Then tear down platform + prereqs:
kubectl delete -f crossplane/platform/xrd/composition.yaml
kubectl delete -f crossplane/platform/xrd/xappdatabase.yaml
kubectl delete -f crossplane/platform/providers/provider-configs.yaml
kubectl delete -f crossplane/platform/functions/functions.yaml
kubectl delete -f crossplane/platform/providers/providers.yaml
helm uninstall crossplane -n crossplane-system
kubectl delete -f crossplane/prereq/postgres.yaml
```
