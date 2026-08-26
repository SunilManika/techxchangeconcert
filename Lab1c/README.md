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
            concert ingestion API  POST /ingestion/api/v1/upload_files
```

> If you are using the **pre-generated `.cdx.json` files** included in this directory, skip Step 1 and go directly to Step 2.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| `trivy` | [Install Trivy](https://trivy.dev/latest/getting-started/installation/) — used by `generate-sbom.sh` |
| `cyclonedx` CLI | [Install CycloneDX CLI](https://github.com/CycloneDX/cyclonedx-cli/releases) — converts CycloneDX 1.7 → 1.6 |
| `jq` | JSON processor — used by `generate-sbom.sh` for output reporting |
| Docker / container registry access | Required to pull images during SBOM generation |
| Concert API access | `CONCERT_URL` reachable and credentials available |

```bash
# Verify prerequisites
trivy --version
cyclonedx --version
jq --version
```

---

## Step 0 — Set environment variables

Set these once in your shell before uploading SBOMs to Concert.

```bash
# Concert application URL
export CONCERT_URL=https://concert-concert.apps.<cluster>/concert

# Concert login credentials
export CONCERT_USERNAME=<your-concert-username>
export CONCERT_PASSWORD=<your-concert-password>

# Skip TLS verification if Concert uses a self-signed cert
export CONCERT_SKIP_TLS=true
```

> **Find the Concert URL:**
> ```bash
> oc get routes -n concert    # → CONCERT_URL host
> ```

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

### Example output

```
==================================================
Scanning image: docker.io/sunilmanika/retail-backend:1.0.0
==================================================
Trivy CycloneDX version:
1.7
Vulnerabilities detected:
42
Final CycloneDX version:
1.6
Vulnerabilities in final file:
42
Generated: retail-backend.cdx.json
...
==================================================
Completed
==================================================
-rw-r--r--  1 user  staff  142K retail-backend.cdx.json
-rw-r--r--  1 user  staff   98K retail-frontend.cdx.json
-rw-r--r--  1 user  staff   87K retail-jmeter.cdx.json
-rw-r--r--  1 user  staff  115K retail-postgresql.cdx.json
```

### SBOM format details

| Field | Value |
|-------|-------|
| `bomFormat` | `CycloneDX` |
| `specVersion` | `1.6` |
| Scanner | Trivy `0.74.0` (Aqua Security) |
| `--scanners` | `vuln` (vulnerability data only; no secrets or misconfigs) |
| Component type | `container` |

---

## Step 2 — Upload SBOMs to Concert

Upload each `.cdx.json` file to Concert using the ingestion API endpoint `POST /ingestion/api/v1/upload_files`.

### Using the Concert UI

1. Log in to Concert and navigate to **Ingestion** → **Upload files**
2. Select `data_type = sbom`
3. Upload each `.cdx.json` file in turn

### Using the Concert REST API (curl)

First, obtain a bearer token:

```bash
# Get a Keycloak token via oc port-forward (same auth flow as Lab1b)
# Or use an existing API key:
export CONCERT_API_KEY=<your-ZenApiKey>
export CONCERT_INSTANCE_ID=<concert-instance-id>
```

Upload each SBOM file:

```bash
for FILE in retail-backend.cdx.json retail-frontend.cdx.json \
            retail-jmeter.cdx.json retail-postgresql.cdx.json; do

  APP_NAME=$(basename "$FILE" .cdx.json)

  curl -sk -X POST \
    "${CONCERT_URL}/ingestion/api/v1/upload_files" \
    -H "Authorization: ZenApiKey ${CONCERT_API_KEY}" \
    -H "X-Auth-Instance-Id: ${CONCERT_INSTANCE_ID}" \
    -F "data_type=sbom" \
    -F "metadata={\"app_name\":\"${APP_NAME}\"}" \
    -F "file=@${FILE};type=application/json"

  echo "Uploaded: $FILE"
done
```

> A successful upload returns HTTP **202 Accepted** with an `event_ids` array. Concert processes the SBOM asynchronously — allow 1–2 minutes for the data to appear in the UI.

### Poll upload status

```bash
# Replace <event_id> with the value returned by the upload call
curl -sk \
  "${CONCERT_URL}/ingestion/api/v1/upload_status?event_id=<event_id>" \
  -H "Authorization: ZenApiKey ${CONCERT_API_KEY}" \
  -H "X-Auth-Instance-Id: ${CONCERT_INSTANCE_ID}" \
  | jq .
```

Status values: `pending` → `processing` → `completed` | `failed`

---

## Full run sequence (copy-paste)

```bash
cd Lab1c

# ── Step 0: Environment variables ───────────────────────────────────────────
export CONCERT_URL=https://concert-concert.apps.<cluster>/concert
export CONCERT_USERNAME=<username>
export CONCERT_PASSWORD=<password>
export CONCERT_SKIP_TLS=true

# ── Step 1: (Optional) Regenerate SBOMs ─────────────────────────────────────
# Skip this block if using the pre-generated .cdx.json files.
chmod +x generate-sbom.sh
./generate-sbom.sh

# ── Step 2: Upload SBOMs to Concert ─────────────────────────────────────────
# Using API key auth (set these if not using username/password flow):
export CONCERT_API_KEY=<your-ZenApiKey>
export CONCERT_INSTANCE_ID=<concert-instance-id>

for FILE in retail-backend.cdx.json retail-frontend.cdx.json \
            retail-jmeter.cdx.json retail-postgresql.cdx.json; do

  APP_NAME=$(basename "$FILE" .cdx.json)

  curl -sk -X POST \
    "${CONCERT_URL}/ingestion/api/v1/upload_files" \
    -H "Authorization: ZenApiKey ${CONCERT_API_KEY}" \
    -H "X-Auth-Instance-Id: ${CONCERT_INSTANCE_ID}" \
    -F "data_type=sbom" \
    -F "metadata={\"app_name\":\"${APP_NAME}\"}" \
    -F "file=@${FILE};type=application/json"

  echo "Uploaded: $FILE"
done
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `trivy: command not found` | Trivy not installed | [Install Trivy](https://trivy.dev/latest/getting-started/installation/) |
| `cyclonedx: command not found` | CycloneDX CLI not installed | [Download CycloneDX CLI](https://github.com/CycloneDX/cyclonedx-cli/releases) and add to `PATH` |
| `No such file or directory: *.tmp.cdx.json` | Trivy scan failed before producing output | Check Docker access / image pull credentials; re-run `generate-sbom.sh` |
| `specVersion` stays `1.7` after convert | Old CycloneDX CLI version | Upgrade the CLI — `cyclonedx convert --output-version v1_6` requires v0.26+ |
| HTTP `401` uploading to Concert | Invalid or expired API key | Re-generate the ZenApiKey in the Concert UI |
| HTTP `400` uploading SBOM | Wrong `data_type` or malformed JSON | Verify `data_type=sbom` and that the file is valid JSON — `jq . retail-backend.cdx.json` |
| HTTP `202` returned but nothing visible in Concert UI | Async processing not finished | Wait 1–2 minutes and refresh. Poll `upload_status` with the returned `event_id`. |
| `Processing status = failed` | Concert rejected SBOM content | Verify `specVersion` is `1.6` (`jq .specVersion retail-backend.cdx.json`); re-generate if needed |

---

## API reference

- [Upload Files — IBM Concert API](https://developer.ibm.com/apis/catalog/concert--ibm-concert-api/api/API--concert--ibm-concert-api-v3-0-0-0#upload_files)
- [Upload Status — IBM Concert API](https://developer.ibm.com/apis/catalog/concert--ibm-concert-api/api/API--concert--ibm-concert-api-v3-0-0-0#upload_status)
