# Lab 1b — IBM Concert: Instana Connection Setup

This lab provisions an **Instana observability connection** in IBM Concert 3.0.x, creates a **Testing environment**, and registers an **Instana ingestion job** — all automated via REST API and input CSV files.

---

## Files in this lab

| File | Type | Purpose |
|------|------|---------|
| `fix-instana-tls.sh` | Shell script | **One-time cluster fix** — patches the Concert TLS CA bundle, writes `insecure_ssl` to the appdb, and restarts pods. Run only if Instana uses a self-signed certificate. |
| `create-instana-connection.py` | Python script | Creates the Instana connection (credential) in Concert via the REST API. |
| `setup-concert-lab1b.py` | Python script | Creates the Concert environment and the Instana ingestion job via the REST API. |
| `instana-connections.csv` | Input CSV | One row per Instana connection to create. |
| `environments.csv` | Input CSV | One row per Concert environment to create. |
| `instana-jobs.csv` | Input CSV | One row per Instana ingestion job to create. |

---

## Prerequisites

- `oc` CLI installed and **logged in** to the OpenShift cluster
  ```bash
  oc login --token=<token> --server=https://<api-server>:6443
  oc whoami   # must succeed
  ```
- `python3` available (stdlib only — no pip installs required)
- `openssl` CLI available locally *(only required if Instana uses a self-signed certificate)*

---

## Step 0 — Set environment variables

These variables are required by both Python scripts. Set them once before running anything.

```bash
# Concert application URL
export CONCERT_URL=https://concert-concert.apps.<cluster>/concert

# IBM Solis Hub URL  (oc get routes -n concert-hub)
export CONCERT_HUB_URL=https://solis-hub-concert-hub.apps.<cluster>

# Concert login credentials
export CONCERT_USERNAME=<your-concert-username>
export CONCERT_PASSWORD=<your-concert-password>

# Skip TLS verification for the Concert API (set true if Concert uses a self-signed cert)
export CONCERT_SKIP_TLS=true
```

> **Tip:** Find the routes by running:
> ```bash
> oc get routes -n concert-hub
> oc get routes -n concert
> ```

---

## Step 1 — (If needed) Fix Instana self-signed TLS

> **Skip this step** if the Instana endpoint uses a certificate signed by a public CA.
> Run this step if Concert's ingestion fails with `x509: certificate signed by unknown authority`.

This script makes three changes to the cluster and must be run **before** creating the credential:

| # | Change | OCP Object |
|---|--------|-----------|
| 1 | Appends Instana CA cert(s) to Concert's TLS bundle | `secret/app-cfg-internal-tls` in `concert` namespace |
| 2 | Writes `insecure_ssl: "true"` to the credential row in appdb | PostgreSQL `ibm_roja_app.credentials` table |
| 3 | Rolling restart so pods mount the updated TLS bundle | `deployment/ibm-roja-app`, `deployment/ibm-roja-ingestion-processor` |

**Usage:**
```bash
chmod +x fix-instana-tls.sh

./fix-instana-tls.sh <instana_url> <credential_name> [concert_namespace]
```

**Example** (using the TechXchange lab values):
```bash
./fix-instana-tls.sh \
    https://unit0-techzone.150-240-162-27.nip.io \
    techxchange-instana
```

The script is **idempotent** — safe to run multiple times. It skips any CA certificate already present in the bundle and waits for the deployment rollout to complete before exiting.

---

## Step 2 — Edit the input CSV files

### `instana-connections.csv`

One row per Instana connection. The `name` value is the display name used in Concert and must match the `connection_name` column in `instana-jobs.csv`.

```
name,instana_url,api_key
techxchange-instana,https://unit0-techzone.150-240-162-27.nip.io,Fn3Jc9GeTZyudAU4nHfDNg
```

| Column | Required | Description |
|--------|----------|-------------|
| `name` | Yes | Display name for the connection in Concert |
| `instana_url` | Yes | Base HTTPS URL of the Instana backend |
| `api_key` | Yes | Instana REST API key |

---

### `environments.csv`

One row per Concert environment.

```
name,purpose,description
Testing,testing,Testing environment for Instana observability ingestion
```

| Column | Required | Description |
|--------|----------|-------------|
| `name` | Yes | Display name for the environment in Concert |
| `purpose` | No | Purpose tag — e.g. `testing`, `production` |
| `description` | No | Free-text description |

---

### `instana-jobs.csv`

One row per Instana ingestion job. `connection_name` and `environment_name` must match names already created (or being created) in earlier steps.

```
name,connection_name,environment_name,description
techxchange-instana-job,techxchange-instana,Testing,Instana discovery job for TechXchange lab
```

| Column | Required | Description |
|--------|----------|-------------|
| `name` | Yes | Display name for the ingestion job |
| `connection_name` | Yes | Name of an existing Instana connection (from `instana-connections.csv`) |
| `environment_name` | Yes | Name of an existing environment (from `environments.csv`) |
| `description` | No | Free-text description |

---

## Step 3 — Create the Instana connection

```bash
python3 create-instana-connection.py
# or with an explicit CSV path:
python3 create-instana-connection.py instana-connections.csv
```

**What it does:**
1. Locates the embedded Keycloak pod and retrieves bootstrap admin credentials
2. Obtains a Keycloak admin token, then the `concert-client` secret
3. Validates the Concert user credentials via Keycloak
4. Port-forwards to `ibm-solis-core-svc` → calls `handle_login` → gets a Hub-signed platform JWT
5. Reads the Concert instance ID from `solis-account-instances-cm`
6. Calls `POST /concert/core/api/v1/credentials` for each row in the CSV

> **Idempotent** — if a connection with the same name already exists it is skipped, not duplicated.

**API reference:** https://developer.ibm.com/apis/catalog/concert--ibm-concert-api/api/API--concert--ibm-concert-api-v3-0-0-0#create_credential

---

## Step 4 — Create the environment and ingestion job

```bash
python3 setup-concert-lab1b.py
# or with explicit CSV paths:
python3 setup-concert-lab1b.py environments.csv instana-jobs.csv
```

**What it does (Phase 1 — Environments):**
- Calls `POST /concert/core/api/v1/environments` for each row in `environments.csv`
- Skips rows where an environment with the same name already exists

**What it does (Phase 2 — Ingestion Jobs):**
- Looks up the Instana connection UUID by name (from Step 3)
- Looks up the environment UUID by name (from Phase 1)
- Calls `POST /concert/core/api/v1/ingestion_jobs` for each row in `instana-jobs.csv`
- Skips rows where a job with the same name already exists

> **Idempotent** — safe to re-run. Existing objects are skipped, not duplicated.

**API references:**
- https://developer.ibm.com/apis/catalog/concert--ibm-concert-api/api/API--concert--ibm-concert-api-v3-0-0-0#create_environment
- https://developer.ibm.com/apis/catalog/concert--ibm-concert-api/api/API--concert--ibm-concert-api-v3-0-0-0#create_ingestion_job

---

## Full run sequence (copy-paste)

```bash
cd Lab1b

# 0 — Set environment variables
export CONCERT_URL=https://concert-concert.apps.<cluster>/concert
export CONCERT_HUB_URL=https://solis-hub-concert-hub.apps.<cluster>
export CONCERT_USERNAME=<username>
export CONCERT_PASSWORD=<password>
export CONCERT_SKIP_TLS=true

# 1 — Fix TLS (only if Instana uses a self-signed certificate)
./fix-instana-tls.sh \
    https://unit0-techzone.150-240-162-27.nip.io \
    techxchange-instana

# 2 — Edit CSV files if needed (instana-connections.csv, environments.csv, instana-jobs.csv)

# 3 — Create the Instana connection in Concert
python3 create-instana-connection.py

# 4 — Create the environment and ingestion job in Concert
python3 setup-concert-lab1b.py
```

---

## Cluster changes summary

| Script | Writes to cluster? | What changes |
|--------|-------------------|--------------|
| `fix-instana-tls.sh` | **Yes** (one-time) | Patches `secret/app-cfg-internal-tls`, updates appdb credential row, restarts 2 deployments |
| `create-instana-connection.py` | **No** | REST API calls to Concert only |
| `setup-concert-lab1b.py` | **No** | REST API calls to Concert only |

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `x509: certificate signed by unknown authority` | Instana uses a self-signed cert | Run `fix-instana-tls.sh` (Step 1) |
| `HTTP 401` from Concert API | Platform JWT expired or wrong credentials | Re-check `CONCERT_USERNAME` / `CONCERT_PASSWORD` |
| `HTTP 400` creating credential | Concert could not reach Instana during validation | Verify `instana_url` is reachable from the cluster; check TLS fix was applied |
| `Keycloak pod not found` | Wrong `CONCERT_HUB_NS` | Run `oc get pods -n concert-hub` and confirm the namespace |
| `Port-forward not ready` | Port `18099` already in use | Set `export CONCERT_LOCAL_PORT=18100` (or any free port) |
| `Credential not found` in Step 4 | Step 3 not run yet, or name mismatch | Ensure `connection_name` in `instana-jobs.csv` matches `name` in `instana-connections.csv` exactly |
