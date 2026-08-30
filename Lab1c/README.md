# Lab 1c — IBM Concert: SBOM Generation and Ingestion

This lab generates a **Software Bill of Materials (SBOM)** for each retail application container image using [Trivy](https://trivy.dev/) and uploads the resulting CycloneDX 1.6 files to IBM Concert via the ingestion API.

- Scan four container images for vulnerabilities and package manifests
- Produce one CycloneDX 1.6 SBOM file per image
- Upload each SBOM to Concert so it appears in the **Applications** and **Vulnerabilities** views

No manual Concert UI interaction is required.

---

## Files in this lab

| File | Type | Purpose |
|------|------|---------|
| `generate-sbom.sh` | Shell script | Scans all four retail images with Trivy, converts CycloneDX 1.7 → 1.6, and writes one `.cdx.json` file per image. |
| `upload-sbom.py` | Python script | Uploads all `.cdx.json` SBOMs to Concert using the same automated JWT auth flow as Lab1b (no API key needed). *(Generated during lab setup — see INSTALL.md Lab 1c)* |
| `retail-backend.cdx.json` | CycloneDX SBOM | Pre-generated SBOM for `sunilmanika/retail-backend:1.0.0` |
| `retail-frontend.cdx.json` | CycloneDX SBOM | Pre-generated SBOM for `sunilmanika/retail-frontend:1.0.0` |
| `retail-jmeter.cdx.json` | CycloneDX SBOM | Pre-generated SBOM for `sunilmanika/retail-jmeter:1.0.1` |
| `retail-postgresql.cdx.json` | CycloneDX SBOM | Pre-generated SBOM for `sunilmanika/retail-postgresql:1.0.0` |

> **Pre-generated files:** The four `.cdx.json` files are already included. You only need to run `generate-sbom.sh` if you want to regenerate them (e.g. to pick up newer vulnerability data or scan different image tags).

---

## Container images scanned

| Image | Tag |
|-------|-----|
| `docker.io/sunilmanika/retail-postgresql` | `1.0.0` |
| `docker.io/sunilmanika/retail-frontend` | `1.0.0` |
| `docker.io/sunilmanika/retail-jmeter` | `1.0.1` |
| `docker.io/sunilmanika/retail-backend` | `1.0.0` |

---

## Execution sequence

```
Step 0   Set environment variables
   │
Step 1   (Optional) Regenerate SBOMs
   │        generate-sbom.sh  ← pulls images, runs Trivy, converts to CycloneDX 1.6
   │
Step 2   Upload SBOMs to Concert
            upload-sbom.py  ← automated JWT auth, multipart upload, polls for visibility
```

> If you are using the **pre-generated `.cdx.json` files** included in this directory, skip Step 1 and go directly to Step 2.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| `python3` | stdlib only — no pip installs required |
| Concert API key | Generated from Concert UI → Settings → API Keys |
| `trivy` | [Install Trivy](https://trivy.dev/latest/getting-started/installation/) — only for `generate-sbom.sh` |
| `cyclonedx` CLI | [Install CycloneDX CLI](https://github.com/CycloneDX/cyclonedx-cli/releases) — only for `generate-sbom.sh` |

---

## Step 0 — Set environment variables

These are the same API key variables used for `upload-certificates.py` in Lab1b — no `oc` login or Keycloak credentials required.

```bash
export CONCERT_URL="https://concert-concert.apps.itz-pi5sqq.hub04-lb.techzone.ibm.com/concert"
export CONCERT_API_KEY="<paste-api-key-here>"       # Concert UI → Settings → API Keys
export CONCERT_INSTANCE_ID="0000-0000-0000-0000"
export CONCERT_ENV_NAME="retail-demo"
export CONCERT_SKIP_TLS="true"
```

---

## Step 1 — (Optional) Regenerate SBOMs

> **Skip this step** if you are using the pre-generated `.cdx.json` files already in this directory.

```bash
chmod +x generate-sbom.sh
./generate-sbom.sh
```

### What it does

For each of the four images the script:

1. Runs `trivy image --scanners vuln --format cyclonedx` to produce a CycloneDX 1.7 SBOM with vulnerability data
2. Reports the detected CycloneDX spec version and vulnerability count
3. Converts the output from CycloneDX 1.7 → **1.6** using `cyclonedx convert --output-version v1_6` (Concert requires 1.6)
4. Removes the temporary 1.7 file
5. Reports the final spec version and vulnerability count of the converted file

### Output files

| Output file | Source image |
|-------------|-------------|
| `retail-backend.cdx.json` | `docker.io/sunilmanika/retail-backend:1.0.0` |
| `retail-frontend.cdx.json` | `docker.io/sunilmanika/retail-frontend:1.0.0` |
| `retail-jmeter.cdx.json` | `docker.io/sunilmanika/retail-jmeter:1.0.1` |
| `retail-postgresql.cdx.json` | `docker.io/sunilmanika/retail-postgresql:1.0.0` |

---

## Step 2 — Upload SBOMs to Concert

```bash
cd Lab1c
python3 upload-sbom.py
```

**What it does:**

1. Validates `CONCERT_API_KEY`, `CONCERT_INSTANCE_ID`, and `CONCERT_ENV_NAME` are set
2. Validates each `.cdx.json` file (`specVersion: 1.6` required)
3. Calls `POST /concert/ingestion/api/v1/upload_files` with `data_type=sbom` and `metadata={"env_name":"<env>"}` for each file — authenticated with `Authorization: C_API_KEY <key>`
4. Polls `GET /concert/core/api/v1/applications` until each application appears in Concert

> **Idempotent** — re-running is safe; Concert deduplicates on SBOM content.

### Command-line options

| Usage | Description |
|-------|-------------|
| `python3 upload-sbom.py` | Upload all `*.cdx.json` files in the current directory |
| `python3 upload-sbom.py retail-backend.cdx.json` | Upload a single file |
| `python3 upload-sbom.py --app-name retail-api retail-backend.cdx.json` | Override the app name |
| `python3 upload-sbom.py --interactive` | Prompt for app name per file |
| `python3 upload-sbom.py --no-poll` | Upload without waiting for visibility confirmation |

### Environment variable overrides

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CONCERT_URL` | ✅ | — | Concert app URL |
| `CONCERT_API_KEY` | ✅ | — | Concert API key |
| `CONCERT_INSTANCE_ID` | ✅ | — | Concert instance ID |
| `CONCERT_ENV_NAME` | ✅ | — | Target environment name |
| `CONCERT_SKIP_TLS` | — | `false` | Skip TLS verification |
| `CONCERT_CA_BUNDLE` | — | — | Path to PEM CA bundle |
| `CONCERT_POLL_TIMEOUT` | — | `180` | Seconds to wait for application to appear |
| `CONCERT_POLL_INTERVAL` | — | `10` | Seconds between visibility poll attempts |

---

## Full run sequence (copy-paste)

```bash
cd Lab1c

# ── Step 0: Set environment variables (same API key as upload-certificates.py)
export CONCERT_URL="https://concert-concert.apps.itz-pi5sqq.hub04-lb.techzone.ibm.com/concert"
export CONCERT_API_KEY="<paste-api-key-here>"
export CONCERT_INSTANCE_ID="0000-0000-0000-0000"
export CONCERT_ENV_NAME="retail-demo"
export CONCERT_SKIP_TLS="true"

# ── Step 1: (Optional) Regenerate SBOMs ─────────────────────────────────────
# Skip this block if using the pre-generated .cdx.json files.
chmod +x generate-sbom.sh
./generate-sbom.sh

# ── Step 2: Upload SBOMs to Concert ─────────────────────────────────────────
python3 upload-sbom.py
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `trivy: command not found` | Trivy not installed | [Install Trivy](https://trivy.dev/latest/getting-started/installation/) |
| `cyclonedx: command not found` | CycloneDX CLI not installed | [Download CycloneDX CLI](https://github.com/CycloneDX/cyclonedx-cli/releases) and add to `PATH` |
| `specVersion` stays `1.7` after convert | Old CycloneDX CLI version | Upgrade the CLI — `cyclonedx convert --output-version v1_6` requires v0.26+ |
| `specVersion is X.X, expected 1.6` | SBOM not converted | Re-run `generate-sbom.sh`; ensure `cyclonedx` CLI is on `PATH` |
| `CONCERT_API_KEY is not set` | API key not exported | Generate from Concert UI → Settings → API Keys |
| `CONCERT_ENV_NAME is not set` | Env name not exported | `export CONCERT_ENV_NAME=retail-demo` |
| `HTTP 401` from Concert API | Wrong or expired API key | Regenerate key in Concert UI |
| `HTTP 403` from Concert API | API key user lacks Admin role | Regenerate key as `sunga027@in.ibm.com` (Admin role) |
| `HTTP 400` uploading SBOM | Wrong `data_type` or malformed JSON | Verify `data_type=sbom`; check file with `jq . retail-backend.cdx.json` |
| `HTTP 202` returned but nothing in Concert UI | Async processing not finished | Wait 1–2 minutes and refresh — `upload-sbom.py` polls automatically |

---

## API reference

- [Upload Files — IBM Concert API](https://developer.ibm.com/apis/catalog/concert--ibm-concert-api/api/API--concert--ibm-concert-api-v3-0-0-0#upload_files)
