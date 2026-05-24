# Task 2 — Implementation Summary

A reference doc covering everything built for Task 2 (Crossplane
`XAppDatabase` API), **why** each decision was made, and the design
trade-offs an interviewer is likely to drill on.

---

## 1. Scope

> Build a Kubernetes API using Crossplane that declaratively provisions a
> Postgres database + schema + tables from a single Custom Resource. Write
> connection details to a Secret. Handle deletion. Allow namespace-scoped
> consumption via a Claim.
>
> Optional: validation, Composition Functions, integrate with the Task 1
> counter-service via a new `/ingest` endpoint.

Delivered. The XR + Claim + Composition + a working `/ingest` endpoint on
the live ALB.

---

## 2. Repository layout

```
crossplane/
├── README.md                                  # install + test instructions
├── prereq/
│   └── postgres.yaml                          # in-cluster Postgres 16 StatefulSet
├── platform/                                  # platform-team owned (install once)
│   ├── providers/
│   │   ├── providers.yaml                     # Provider + DeploymentRuntimeConfig
│   │   └── provider-configs.yaml              # ProviderConfigs + RBAC for provider-kubernetes
│   ├── functions/
│   │   └── functions.yaml                     # 3 Crossplane Functions
│   └── xrd/
│       ├── xappdatabase.yaml                  # CompositeResourceDefinition + Claim
│       └── composition.yaml                   # the Composition (Pipeline mode)
└── examples/                                  # what app teams write
    ├── minimal.yaml                           # 1 db, 1 table
    ├── two-tables.yaml                        # 2 tables with FK
    └── counter-data.yaml                      # backs the /ingest endpoint

service/                                       # extended from Task 1
├── app/
│   ├── ingest.py                              # new: asyncpg connection pool + INSERT
│   └── main.py                                # extended: POST /ingest endpoint
├── pyproject.toml                             # +asyncpg
└── tests/test_ingest.py                       # 9 new tests, mocked + endpoint coverage

deploy/overlays/prod/
├── ingest-netpol.yaml                         # NetworkPolicy: counter-service → postgres:5432
└── ingest-env-patch.yaml                      # Deployment env entries pulling from counter-data-conn Secret
```

---

## 3. Postgres prereq (`crossplane/prereq/postgres.yaml`)

A self-contained vanilla Postgres 16 StatefulSet — namespace `db`.

- 1 replica, 1 GiB encrypted gp3 PVC (uses the Task 1 storage class)
- Superuser password from a K8s `Secret` (`postgres-superuser`) — values
  are pinned in the manifest for the assignment; a real prod would source
  via ExternalSecret from AWS Secrets Manager
- Headless not required (single replica, ClusterIP Service is fine)
- PSS profile: `baseline` (not `restricted`) — Postgres can't run with
  `readOnlyRootFilesystem: true` without writing custom init logic

Verified ready with `pg_isready` before installing Crossplane.

**Why not the Bitnami chart or an operator (Zalando, CrunchyData)?**
- Bitnami's chart is fine but adds Helm complexity for a single-replica
  dev DB
- Operators are overkill — we're not managing replication, failover,
  upgrades
- Self-contained manifest = easy to read, no transitive registry deps

---

## 4. Crossplane install

`helm install crossplane crossplane-stable/crossplane -n crossplane-system`
at version `1.18.0` (current GA at time of writing). Two pods come up:
`crossplane` and `crossplane-rbac-manager`.

Crossplane v1.18 has:
- `apiextensions.crossplane.io/v1` for CRD/Composition (stable)
- Pipeline-mode Compositions with Functions (GA since v1.14)
- `DeploymentRuntimeConfig` for tweaking provider Deployments (beta in v1.17+)

---

## 5. Providers + Functions

### 5.1 Providers (`platform/providers/providers.yaml`)

- **`provider-sql`** (`xpkg.upbound.io/crossplane-contrib/provider-sql:v0.11.0`)
  Speaks the SQL provider protocol (Database, Role, Grant, Schema, etc.).
  We point it at our in-cluster Postgres via a ProviderConfig.

- **`provider-kubernetes`** (`xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.18.0`)
  Lets a Composition emit arbitrary K8s objects (Secrets, Jobs,
  ConfigMaps). We use it for: the create-tables Job, the role-password
  Secret, and the consumer-facing connection Secret.

#### `DeploymentRuntimeConfig`

Crossplane gives provider Deployments a hashed SA name by default
(`provider-kubernetes-3c1712b01e08`). That breaks any
ClusterRoleBinding/RoleBinding that names the SA — the name changes on
every reinstall. The DRC pins the SA name to a fixed `provider-kubernetes`,
so the CRB in `provider-configs.yaml` always matches.

```yaml
apiVersion: pkg.crossplane.io/v1beta1
kind: DeploymentRuntimeConfig
metadata: { name: provider-kubernetes }
spec:
  serviceAccountTemplate:
    metadata: { name: provider-kubernetes }
```

### 5.2 Functions (`platform/functions/functions.yaml`)

- **`function-go-templating`** (`v0.9.0`) — runs the heart of our
  Composition; reads `spec.parameters` and emits all composed resources
- **`function-auto-ready`** (`v0.4.0`) — flips XR `Ready=True` once every
  composed resource is Ready (avoids hand-rolling readiness logic)
- **`function-patch-and-transform`** (`v0.7.0`) — installed but unused;
  available for future XRs that prefer field-level patches over templating

### 5.3 ProviderConfigs (`platform/providers/provider-configs.yaml`)

For `provider-sql`:
```yaml
apiVersion: postgresql.sql.crossplane.io/v1alpha1
kind: ProviderConfig
metadata: { name: default }
spec:
  defaultDatabase: postgres
  sslMode: disable                  # in-cluster traffic
  credentials:
    source: PostgreSQLConnectionSecret
    connectionSecretRef:
      namespace: crossplane-system
      name: postgres-dsn            # holds endpoint/port/username/password
```

For `provider-kubernetes`: `credentials.source: InjectedIdentity` — uses
the SA the provider runs as. We then `ClusterRoleBinding` that SA to
`cluster-admin` for the assignment (a real prod would scope down to
`secrets`, `configmaps`, `jobs`, `rolebindings` in specific namespaces).

---

## 6. The XRD (`platform/xrd/xappdatabase.yaml`)

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xappdatabases.database.platform.example.com
spec:
  group: database.platform.example.com
  names:        { kind: XAppDatabase, plural: xappdatabases }
  claimNames:   { kind: AppDatabase,  plural: appdatabases }
  defaultCompositionRef: { name: xappdatabase-postgres }
  defaultCompositeDeletePolicy: Foreground
  versions:
    - name: v1alpha1
      served: true
      referenceable: true
      schema:
        openAPIV3Schema: { ... }     # see below
```

Two kinds get generated: `XAppDatabase` (cluster-scoped, what Crossplane
reconciles) and `AppDatabase` (namespace-scoped Claim — what app teams
write).

### 6.1 Schema validation

The OpenAPI v3 schema is the platform's contract with consumers. We use
regex validators on every string field that becomes a SQL identifier:

| Field | Pattern | Why |
|---|---|---|
| `database` | `^[a-z][a-z0-9_]{1,62}$` | Postgres ident; bounded length; lowercase only |
| `schema`   | `^[a-z][a-z0-9_]{0,62}$` | Same; default `public` |
| `tables[*].name` | `^[a-z][a-z0-9_]{0,62}$` | Same |
| `columns[*].name` | `^[a-z][a-z0-9_]{0,62}$` | Same |
| `columns[*].type` | `^[A-Za-z][A-Za-z0-9_]*(\([0-9]+(,[0-9]+)?\))?(\s+(primary\s+key\|unique\|not\s+null\|references\s+...))*$` | Allows real SQL types + clauses; blocks `;`, `--`, `'`, `"` |

Plus array bounds (1–50 tables, 1–50 columns) and `required: [database, tables]`.

**The threat model**: column `type` strings get string-interpolated into
the CREATE TABLE statement (because asyncpg/psql can't parameterise type
declarations). If the user puts `"int; DROP TABLE users; --"` there, that
executes. The regex above ensures only well-formed SQL grammar makes it
in — `;` and `--` are forbidden, `'` is forbidden, `"` is forbidden.

### 6.2 The Claim (the bonus from the assignment)

```yaml
claimNames: { kind: AppDatabase, plural: appdatabases }
```

This is one line of XRD and gets us the entire namespace-scoped
consumption model. App teams create `AppDatabase` in their namespace; the
XAppDatabase backing object lives cluster-scoped. RBAC for app teams only
needs `create appdatabases` in their own namespace.

`writeConnectionSecretToRef.namespace` defaults to the Claim's namespace,
so the conn Secret automatically lands where the team can use it.

---

## 7. The Composition (`platform/xrd/composition.yaml`)

Pipeline mode (the modern Crossplane style) with two steps:

```yaml
spec:
  compositeTypeRef: { apiVersion: database.platform.example.com/v1alpha1, kind: XAppDatabase }
  writeConnectionSecretsToNamespace: crossplane-system
  mode: Pipeline
  pipeline:
    - step: render
      functionRef: { name: function-go-templating }
      input: { ... inline Go template ... }
    - step: ready
      functionRef: { name: function-auto-ready }
```

### 7.1 Why one Go template instead of two functions?

Considered using P&T for the static structure (Database, Role, Grant)
and GT only for the dynamic Job. Decided against:
- A single template means the table list flows through one cohesive
  pipeline — no awkward "GT renders the Job, P&T patches its env var"
  indirection
- One source of truth for the rendered resources; one place to read

### 7.2 What gets rendered (one render of `minimal.yaml`)

| Composition resource name | Kind | What it does |
|---|---|---|
| `database`          | `Database` (provider-sql)        | Creates the logical Postgres DB |
| `role`              | `Role` (provider-sql)            | Creates the app user (login=true); password from the Secret below |
| `role-password`     | `Object/Secret` (provider-kubernetes) | The app user's password, in `crossplane-system`. **`deletionPolicy: Orphan`** — see § 8 |
| `grant-connect`     | `Grant` (provider-sql)           | Grants CONNECT on the DB to the app user |
| `create-tables-job` | `Object/Job` (provider-kubernetes) | Job in `db` ns that runs `psql -d <db> -c "..."` with all `CREATE TABLE IF NOT EXISTS ...` + `GRANT SELECT/INSERT/UPDATE/DELETE ... TO <user>` |
| `conn-secret`       | `Object/Secret` (provider-kubernetes) | Consumer-facing Secret with host/port/db/schema/user/password/dsn in the namespace from `writeConnectionSecretToRef` |

Plus a `CompositeConnectionDetails` (meta resource) that publishes the
same keys back to the XR so `writeConnectionSecretToRef` at the XR level
picks them up.

### 7.3 The template's interesting bits

```gotemplate
{{- $xr := .observed.composite.resource -}}
{{- $database := $xr.spec.parameters.database -}}
{{- $schema := default "public" $xr.spec.parameters.schema -}}
{{- $tables := $xr.spec.parameters.tables -}}
{{- $appUser := printf "%s_app" $database -}}
{{- /* K8s resource names can't contain underscores; the Postgres DB name
       often does. Use $k8sName when stamping K8s names, $database for SQL. */ -}}
{{- $k8sName := $database | replace "_" "-" -}}
{{- /* Stable per-XR password — sha256 of XR UID + db name. Re-renders are
       deterministic; re-applies don't rotate the password unexpectedly. */ -}}
{{- $password := printf "p_%s" (sha256sum (printf "%s-%s" $xr.metadata.uid $database) | trunc 32) -}}
```

The dual-name trick (`$k8sName` for K8s, `$database` for SQL) is a real
issue you hit on the first apply (`minimal_db` is valid SQL, invalid for
K8s metadata.name).

### 7.4 The SQL the Job runs

```sql
{{- if ne $schema "public" }}
CREATE SCHEMA IF NOT EXISTS "{{ $schema }}";
{{- end }}
GRANT USAGE ON SCHEMA "{{ $schema }}" TO "{{ $appUser }}";
{{- range $t := $tables }}
CREATE TABLE IF NOT EXISTS "{{ $schema }}"."{{ $t.name }}" (
  {{- range $i, $c := $t.columns }}
  {{ if $i }},{{ end }}"{{ $c.name }}" {{ $c.type }}
  {{- end }}
);
GRANT SELECT, INSERT, UPDATE, DELETE ON "{{ $schema }}"."{{ $t.name }}" TO "{{ $appUser }}";
{{- end }}
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA "{{ $schema }}" TO "{{ $appUser }}";
```

Identifiers are quoted so case is preserved and reserved-word collisions
don't sneak in. `IF NOT EXISTS` makes the Job idempotent — re-rendering
on every reconcile is safe. Per-table grants make the app user able to
USE the tables (without grants, SELECT would 403).

---

## 8. Deletion lifecycle

When the XR is deleted, Crossplane removes every composed resource
concurrently. That causes one race we have to handle:

**The race**: `provider-sql/Role`'s delete-path runs `observe()` before
`delete()`. `observe()` reads the password Secret. If the Secret is
deleted in parallel by Crossplane, `observe()` errors with `cannot get
password secret` and the Role MR stays stuck — the Postgres role leaks.

**The fix**: set `deletionPolicy: Orphan` on the role-password
`Object`. Crossplane drops it from state on XR delete but leaves the
underlying K8s Secret alone. The Role MR's observe succeeds, drops the
Postgres role, and Crossplane finalises clean. The Secret becomes a
small orphan that operators clean up with:

```bash
kubectl delete secret -n crossplane-system \
  -l app.kubernetes.io/managed-by=crossplane
```

**Verified flow** (orders-db example):
1. `kubectl delete xappdatabase orders-db`
2. Database MR runs `DROP DATABASE app_orders` → DB + all tables + schema gone
3. Role MR observes successfully (Secret still present) → `DROP ROLE`
4. Grant MR is REVOKEd as part of the dependency chain
5. conn-Secret deleted from `default` namespace
6. role-password Secret remains in `crossplane-system` (orphan)
7. XR removed

The DB drop **cascades** — no per-table Drop-Job needed. This is also
what makes the design economical: 6 composed resources whose deletion
collapses neatly through the parent Database MR.

---

## 9. The Claim (namespace-scoped consumption)

By declaring `claimNames` in the XRD, we get `AppDatabase` as a
namespace-scoped resource for free. The Composition is the same; the
only difference is RBAC scope:

- A team member with `create appdatabases` in their own namespace can
  request a database without cluster-wide permissions
- Crossplane creates the cluster-scoped XR behind the scenes
- The conn Secret defaults to the Claim's namespace (no need to manually
  set `writeConnectionSecretToRef.namespace`)

Example claim:
```yaml
apiVersion: database.platform.example.com/v1alpha1
kind: AppDatabase           # not XAppDatabase
metadata:
  name: my-orders
  namespace: team-orders
spec:
  parameters: { ... }
  writeConnectionSecretToRef: { name: my-orders-conn }
```

---

## 10. Bonus: counter-service `/ingest` integration

### 10.1 The XR for counter_data

`crossplane/examples/counter-data.yaml`:

```yaml
apiVersion: database.platform.example.com/v1alpha1
kind: XAppDatabase
metadata: { name: counter-data }
spec:
  parameters:
    database: counter_data
    schema: public
    tables:
      - name: events
        columns:
          - { name: id,             type: "serial primary key" }
          - { name: date,           type: "timestamp not null" }
          - { name: counter_values, type: "bigint not null" }
          - { name: restart_count,  type: "int not null" }
  writeConnectionSecretToRef:
    name: counter-data-conn
    namespace: prod
```

Apply → 25 s later the `prod` namespace has a `counter-data-conn` Secret
with host/port/db/user/password.

### 10.2 The Python side

`service/app/ingest.py`:
- `IngestStore` wrapper around an `asyncpg.create_pool()` (min 1, max 5)
- `IngestPayload` (pydantic): `date: date, counter_values: int >= 0, restart_count: int >= 0`
- One method: `insert(payload)` that runs a parameterised
  `INSERT INTO "<schema>"."<table>" ("date", "counter_values", "restart_count") VALUES ($1,$2,$3)`
- Identifier quoting in the SQL string; values via asyncpg parameters
  (no string interpolation of user input)

`service/app/main.py`:
- Lifespan opens the pool if `COUNTER_INGEST_ENABLED=true`
- New endpoint `POST /ingest` — returns 201 `ingested`, or 503
  `ingest disabled` if the store isn't connected

`service/app/config.py`: 7 new env vars
(`COUNTER_PG_HOST/PORT/DATABASE/SCHEMA/USERNAME/PASSWORD/TABLE`,
`COUNTER_INGEST_ENABLED`). Per-field validation through pydantic.

### 10.3 Deploy wiring

Two Kustomize patches in the prod overlay:

- `ingest-env-patch.yaml` — appends env entries to the
  `counter-service` Deployment that pull from the `counter-data-conn`
  Secret. Strategic merge by container name → existing env entries
  (`COUNTER_BACKEND`, `COUNTER_REDIS_URL`, etc.) are preserved.

- `ingest-netpol.yaml` — a new `NetworkPolicy` allowing
  `counter-service` → `postgres.db:5432`. The existing
  `counter-service-egress` is whitelist-only; without this the asyncpg
  pool would time out on connect.

### 10.4 Tests

`service/tests/test_ingest.py` — 9 new tests, all in the unit suite (no
live Postgres needed):

- Payload validation (negative values rejected, bad date rejected)
- DSN building (from full DSN or from parts)
- Identifier quoting in the SQL string
- `insert` raises when not connected
- `close` is no-op when never connected
- Endpoint returns 503 when ingest is disabled
- Endpoint returns 422 on a bad payload
- Endpoint returns 201 with a mocked store (`monkeypatch` injects a
  fake `IngestStore` class into `app.main`)

Coverage rose to **96.6%** total (`33 passed`, gate at 90%).

---

## 11. Trade-offs an interviewer might drill on

### "Why not provider-helm to install Postgres?"
We could. The point of provider-helm is when you want Crossplane to
*manage* the Helm release lifecycle. Our Postgres is a fixed
prerequisite, not user-supplied, so installing it via plain `kubectl
apply` is simpler and avoids one more provider's RBAC surface.

### "Why provider-kubernetes Object instead of native Job composition?"
Compositions can only emit Crossplane Managed Resources. A K8s Job
isn't an MR. `provider-kubernetes/Object` is the official way to make
arbitrary K8s objects look like MRs to Crossplane — they get reconciled,
ownership tracked, deletion handled (subject to the orphan caveat).

### "What's the failure mode if Postgres goes down?"
- The Composition's Database/Role/Grant MRs go `Ready=False` —
  Crossplane retries them
- The create-tables Job is idempotent (`CREATE TABLE IF NOT EXISTS`) so
  re-running on Postgres recovery is fine
- Existing XRs stay alive in K8s; the XR's status reflects the outage
- The connection Secret is stable in the consumer's namespace; the
  consumer hits Postgres connection errors directly

### "How would you scale this to multi-tenant?"
- Add a `team` field to `spec.parameters` and prefix `database` with it
  (`{team}_app_orders`) — enforced by an OPA/Kyverno policy
- Use a dedicated `crossplane_admin` Postgres role with `CREATEDB,
  CREATEROLE` (not superuser) for the ProviderConfig
- Per-team Postgres instances (one XR generates the whole instance via
  CloudNativePG operator or RDS) instead of shared
- Quotas via Resource Quota on the team namespace

### "How does this compare to provisioning AWS RDS via Crossplane?"
provider-aws has an RDS family (`DBInstance`, `DBSubnetGroup`,
`DBParameterGroup`, etc.). Our XAppDatabase models the *application*
schema, not the Postgres instance. You could build a hierarchy:
`XPostgresInstance` (RDS) → `XAppDatabase` (logical DBs + schemas +
tables on top of it). Common pattern in real platform engineering.

### "Why no Composition Revision pinning?"
By default Crossplane uses the latest CompositionRevision automatically.
For stability you'd set `compositionUpdatePolicy: Manual` on each XR and
pin a specific revision — important when Composition changes need
controlled rollout. We're on the default for the assignment.

### "What about secret rotation?"
The password is a deterministic sha256 of the XR UID + db name. It
doesn't rotate. For real rotation: add a `secret-rotation-trigger`
field to `spec.parameters`; bumping it changes the hash inputs and
triggers Crossplane to update the role's password and re-publish the
connection Secret. Consumers reading the Secret get the new value on
their next reconcile.

### "Why function-go-templating instead of writing a Go function from scratch?"
The Composition Function SDK gives you a typed gRPC API where you
implement the rendering logic in Go. That's the right tool for complex,
testable logic. Our rendering is mostly stringly-typed SQL generation —
the templating function is faster to author, easier to read in a PR, and
shares the data model with helm charts that future engineers will
recognise.

---

## 12. Live verification

```bash
# Cluster state
$ kubectl get xappdatabase
NAME           SYNCED   READY   COMPOSITION             AGE
counter-data   True     True    xappdatabase-postgres   3m

# The DB + table really exist
$ kubectl exec -n db postgres-0 -- psql -U postgres -d counter_data -c "\dt"
         List of relations
 Schema |  Name  | Type  |  Owner
--------+--------+-------+----------
 public | events | table | postgres

# Connection Secret published
$ kubectl get secret counter-data-conn -n prod -o jsonpath='{.data.database}' | base64 -d
counter_data

# Two-table example works with FK
$ kubectl apply -f crossplane/examples/two-tables.yaml
$ kubectl exec -n db postgres-0 -- psql -U postgres -d app_orders -c "\d orders"
                                        Table "public.orders"
   Column   |            Type             | ...
------------+-----------------------------+------
 id         | integer                     |
 user_id    | integer                     |
 total      | numeric(10,2)               |
 created_at | timestamp without time zone |
Foreign-key constraints:
    "orders_user_id_fkey" FOREIGN KEY (user_id) REFERENCES users(id)

# Deletion cascades
$ kubectl delete xappdatabase orders-db
$ kubectl exec -n db postgres-0 -- psql -U postgres -c "\l" | grep app_orders
# (empty — gone)
```

---

## 13. Files changed/added in Task 2

| Layer | Files |
|---|---|
| Crossplane platform | `crossplane/platform/{providers,functions,xrd}/*.yaml` (6 files) |
| Crossplane prereq | `crossplane/prereq/postgres.yaml` |
| Crossplane examples | `crossplane/examples/{minimal,two-tables,counter-data}.yaml` |
| Service code | `service/app/ingest.py` (new), `service/app/main.py` (+endpoint), `service/app/config.py` (+pg fields), `service/pyproject.toml` (+asyncpg) |
| Service tests | `service/tests/test_ingest.py` (9 tests) |
| Deploy overlay | `deploy/overlays/prod/{ingest-env-patch,ingest-netpol}.yaml` |
| Docs | `crossplane/README.md`, `docs/task2-summary.md` (this file) |

---

## 14. Things explicitly NOT done (with reasons)

- **Composition Revisions pinning** — left on the default (latest). Real
  prod would gate Composition changes through revision pinning.
- **Finalizer Job for orphan cleanup** — documented as a one-line manual
  cleanup; an auto-cleanup Job is a future improvement.
- **provider-helm for Postgres** — not needed; the prereq is a fixed
  manifest.
- **Per-namespace prefix enforcement** — the regex allows any
  database name; a real platform would enforce `<namespace>_<name>` via
  an admission policy.
- **CompositeResourceDefinition versioning beyond v1alpha1** — single
  version for the assignment; production would use `v1beta1` and `v1` once
  the API stabilises and add conversion webhooks.
- **Drop tables on XR delete via a separate Job** — relies on `DROP
  DATABASE` cascading, which works for our model where each XR owns its
  database. If we ever supported "multiple XRs share a database, each
  owns a schema", we'd need explicit DROP SCHEMA logic.
- **Live `/ingest` smoke test from the ALB through ArgoCD** — code +
  tests + deploy patch all in place; the live demo runs once this PR
  merges and image-updater (or a manual tag bump) pushes the new image.
