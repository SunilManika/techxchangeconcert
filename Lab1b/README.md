# Lab 1b — IBM Concert: Instana Connection Setup

This lab provisions an **Instana observability connection** in IBM Concert 3.0.x, creates a **Testing environment**, registers an **Instana ingestion job**, and uploads a **certificate inventory** — all automated via REST API and input CSV files.

---

## Files in this lab

| File | Type | Purpose |
|------|------|---------|
| `fix-instana-tls.sh` | Shell script | **One-time cluster fix** — patches the Concert TLS CA bundle, writes `insecure_ssl` to the appdb, and restarts pods. Run only if Instana uses a self-signed certificate. |
| `create-connections.py` | Python script | Creates the Instana connection (credential) in Concert via the REST API. |
| `setup-environments.py` | Python script | Creates the Concert environment and the Instana ingestion job via the REST API. |
| `upload-certificates.py` | Python script | Uploads the certificate inventory CSV to Concert via the ingestion API. |
| `instana-connections.csv` | Input CSV | One row per Instana connection to create. |
| `environments.csv` | Input CSV | One row per Concert environment to create. |
| `instana-jobs.csv` | Input CSV | One row per Instana ingestion job to create. |
| `concert-certificates.csv` | Input CSV | Certificate inventory to upload (grouped by `Namespace` column). |

---

## Prerequisites

- `oc` CLI installed and **logged in** to the OpenShift cluster
  ```bash
  oc login -u kubeadmin -p LqLfP-sQQUg-79RoS-ioEHR \
      https://api.itz-qia7l8.infra01-lb.wdc07.techzone.ibm.com:6443 \
      --insecure-skip-tls-verify
  oc whoami   # must succeed
  ```
- `python3` available (stdlib only — no pip installs required)
- `openssl` CLI available locally *(only required if Instana uses a self-signed certificate)*

---

## Step 0 — Set environment variables

Set these five variables once before running any script. They are the only variables required.

```bash
# Concert application URL  (include /concert path suffix)
export CONCERT_URL="https://concert-concert.apps.itz-qia7l8.infra01-lb.wdc07.techzone.ibm.com/concert"

# IBM Solis Hub URL — the solis-hub route, NOT the concert-concert route
export CONCERT_HUB_URL="https://solis-hub-concert-hub.apps.itz-qia7l8.infra01-lb.wdc07.techzone.ibm.com"

# Concert admin credentials — MUST be the original admin user that bootstrapped Concert.
# Lab users added via add-concert-users.sh can log into the UI but cannot be used here.
export CONCERT_USERNAME="sunga027@in.ibm.com"
export CONCERT_PASSWORD="Concert@2026"

# Skip TLS verification (OCP uses a Let's Encrypt cert; Python's CA bundle may not include it)
export CONCERT_SKIP_TLS="true"

# Concert instance ID (fixed for OLM/operator installs)
export CONCERT_INSTANCE_ID="0000-0000-0000-0000"
```

> **Note:** `CONCERT_HUB_URL` points to the separate `solis-hub` route (namespace `concert-hub`), **not** the Concert application route. The scripts use this URL to port-forward to Keycloak and the Hub internal service.
>
> **Note:** `CONCERT_USERNAME` must be the Concert admin account (`sunga027@in.ibm.com`), not a lab user account. The upload scripts authenticate the data ingestion pipeline, which requires admin-level Concert RBAC — lab user accounts do not have this permission.

---

## Step 1 — (If needed) Fix Instana self-signed TLS

> **Skip this step** if the Instana endpoint uses a certificate signed by a public CA.

This script makes four changes to the cluster and must be run **before** creating the credential:

| # | Change | OCP Object |
|---|--------|-----------|
| 1 | Appends Instana CA cert(s) to Concert's TLS bundle | `secret/app-cfg-internal-tls` in `concert` ns |
| 2 | Writes `insecure_ssl: "true"` to the credential row in appdb | PostgreSQL `ibm_roja_app.credentials` table |
| 3 | Rolling restart so pods pick up the updated TLS secret mount | Concert application deployments |
| 4 | Ensures `solis-account-instances-cm` has the Concert instance entry | `configmap/solis-account-instances-cm` in `concert-hub` ns |

**Usage:**
```bash
chmod +x fix-instana-tls.sh

./fix-instana-tls.sh <instana_url> <credential_name> [concert_namespace]
```

**Example:**
```bash
./fix-instana-tls.sh \
    https://unit0-techzone.150-240-162-27.nip.io \
    techxchange-instana
```

The script is **idempotent** — safe to run multiple times.

---

## Step 2 — Verify the input CSV files

### `instana-connections.csv`

```
name,instana_url,api_key
techxchange-instana,https://unit0-techzone.150-240-162-27.nip.io,<instana-api-key>
```

| Column | Required | Description |
|--------|----------|-------------|
| `name` | Yes | Display name — must match `connection_name` in `instana-jobs.csv` |
| `instana_url` | Yes | Base HTTPS URL of the Instana backend |
| `api_key` | Yes | Instana REST API key |

### `environments.csv`

```
name,purpose,description
Testing,testing,Testing environment for Instana observability ingestion
```

### `instana-jobs.csv`

```
name,connection_name,environment_name,description
techxchange-instana-job,techxchange-instana,Testing,Instana discovery job for TechXchange lab
```

| Column | Required | Description |
|--------|----------|-------------|
| `connection_name` | Yes | Must match `name` in `instana-connections.csv` exactly |
| `environment_name` | Yes | Must match `name` in `environments.csv` exactly |

### `concert-certificates.csv`

Standard Concert certificate inventory CSV. The `Namespace` column value is used as the Concert `env_name` for each upload group.

---

## Step 3 — Create the Instana connection

```bash
python3 create-connections.py
```

**What it does:**
1. Port-forwards to `ibm-solis-hub-gw-svc` → gets Keycloak admin token
2. Retrieves the `concert-client` secret from Keycloak
3. Validates Concert user credentials
4. Port-forwards to `ibm-solis-core-svc` → calls `handle_login` → gets a Hub-signed platform JWT
5. Reads the Concert instance ID from `solis-account-instances-cm`
6. Calls `POST /concert/core/api/v1/credentials` for each row in the CSV

> **Idempotent** — existing connections are skipped, not duplicated.

---

## Step 4 — Create environment and ingestion job

```bash
python3 setup-environments.py
```

**Phase 1 — Environments:** calls `POST /concert/core/api/v1/environments` per row in `environments.csv`.

**Phase 2 — Ingestion Jobs:** looks up credential and environment IDs by name, then calls `POST /concert/core/api/v1/ingestion_jobs` per row in `instana-jobs.csv`.

> **Idempotent** — existing objects are skipped.

---

## Step 5 — Upload certificate inventory

```bash
python3 upload-certificates.py
```

**What it does:**
1. Uses the same auth flow as steps 3–4 (Keycloak → `handle_login` → platform JWT)
2. Groups the CSV rows by the `Namespace` column value
3. Calls `POST /ingestion/api/v1/upload_files` once per group with `data_type=certificate`
4. Polls `GET /concert/core/api/v1/certificates` until uploaded serial numbers appear (confirms async pipeline completed)

> **Idempotent** — re-uploading the same CSV is safe; Concert deduplicates on serial number.

---

## Full run sequence

```bash
cd Lab1b

# 0 — Log in to OpenShift and set environment variables
oc login -u kubeadmin -p LqLfP-sQQUg-79RoS-ioEHR \
    https://api.itz-qia7l8.infra01-lb.wdc07.techzone.ibm.com:6443 \
    --insecure-skip-tls-verify

export CONCERT_URL="https://concert-concert.apps.itz-qia7l8.infra01-lb.wdc07.techzone.ibm.com/concert"
export CONCERT_HUB_URL="https://solis-hub-concert-hub.apps.itz-qia7l8.infra01-lb.wdc07.techzone.ibm.com"
export CONCERT_USERNAME="sunga027@in.ibm.com"
export CONCERT_PASSWORD="Concert@2026"
export CONCERT_SKIP_TLS="true"
export CONCERT_INSTANCE_ID="0000-0000-0000-0000"

# 1 — Fix TLS (only if Instana uses a self-signed certificate)
./fix-instana-tls.sh \
    https://unit0-techzone.150-240-162-27.nip.io \
    techxchange-instana

# 2 — Create the Instana connection in Concert
python3 create-connections.py

# 3 — Create the environment and ingestion job
python3 setup-environments.py environments.csv instana-jobs.csv

# 4 — Upload certificate inventory
python3 upload-certificates.py
```

---

## Optional environment variables

These are only needed if your cluster differs from the defaults. You do **not** need to set them for a standard TechXchange lab install.

| Variable | Default | Override when |
|----------|---------|---------------|
| `CONCERT_HUB_NS` | `concert-hub` | Hub installed in a different namespace |
| `CONCERT_REALM` | `concert-realm` | Keycloak realm has a different name |
| `CONCERT_LOCAL_PORT` | `18099` | Port 18099 is already in use on your machine |
| `CONCERT_KC_LOCAL_PORT` | `18443` | Port 18443 is already in use on your machine |
| `CONCERT_POLL_TIMEOUT` | `120` | Certificate pipeline is slow (increase to e.g. `300`) |
| `CONCERT_POLL_INTERVAL` | `5` | Change polling frequency in seconds |
| `CONCERT_ENV_NAME` | *(from CSV)* | Override the env_name for all certificate uploads |

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `x509: certificate signed by unknown authority` | Instana uses a self-signed cert | Run `fix-instana-tls.sh` (Step 1) |
| `HTTP 401 — instance ID Not Found` from upload | Platform JWT has `"role": "User"` instead of `"Admin"` | User not in Keycloak `admin` group, or `oidc-group-membership-mapper` missing — run `fix-concert-auth.sh` |
| `HTTP 401` from Concert API | Wrong credentials or expired JWT | Re-check `CONCERT_USERNAME` / `CONCERT_PASSWORD` |
| `HTTP 400` creating credential | Concert could not reach Instana during validation | Verify `instana_url` is reachable from the cluster; confirm TLS fix was applied |
| `Keycloak pod not found` | Wrong namespace | Run `oc get pods -n concert-hub` to confirm pod names |
| `Port-forward not ready` | Port already in use | `export CONCERT_LOCAL_PORT=18100` and/or `export CONCERT_KC_LOCAL_PORT=18444` |
| `Credential not found` in Step 4 | Step 3 not run, or name mismatch | Ensure `connection_name` in `instana-jobs.csv` matches `name` in `instana-connections.csv` exactly |
| `Concert instance ID not found` | `solis-account-instances-cm` missing the key | Re-run `fix-instana-tls.sh` — Change 4 creates the key |
