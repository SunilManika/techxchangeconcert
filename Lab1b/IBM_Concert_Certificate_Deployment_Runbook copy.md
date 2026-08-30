# IBM Concert 3.0.x Certificate Management Demo Deployment Runbook

This runbook deploys and validates an IBM Concert certificate-management demo on OpenShift. It covers the complete path from OpenShift access and optional Concert installation through OIDC user provisioning, Concert API-key configuration, environment creation, certificate ingestion, and UI verification.

The supported certificate uploader uses a Concert API key (`C_API_KEY`). It does not use the internal Solis `handle_login` JWT flow.

## 1. Result

After completing this runbook:

- IBM Concert is reachable through its OpenShift route.
- Lab users can sign in through the embedded Keycloak realm.
- The target Concert environment exists and is visible to the API-key owner.
- The sample certificate CSV is accepted by the ingestion API.
- Ingestion event IDs are captured for troubleshooting.
- Certificate records are confirmed through the Concert API and displayed under **Operations > Certificates**.

## 2. Scope and execution paths

Use the path appropriate for the environment:

| Situation | Start at |
| --- | --- |
| Concert is not installed | Step 5 — Optional one-time Concert installation |
| Concert is installed but OIDC/users are not configured | Step 6 — Post-install authentication and users |
| Concert and users already work | Step 7 — Install the corrected uploader |
| The API key and target environment already exist | Step 11 — Upload certificates |

For a certificate-only demonstration, `create-connections.py`, `fix-instana-tls.sh`, and Instana ingestion jobs are not required.

## 3. Required files

Recommended lab structure:

```text
Lab1a/
├── install-concert.sh             # Run once only, if Concert is not installed
├── setup-concert.sh               # Post-install route/OIDC configuration
├── add-concert-users.sh           # Standalone user updates
└── concert-users.csv              # Lab users

Lab1b/
├── upload-certificates.py         # Corrected C_API_KEY uploader
├── concert-certificates.csv       # Sample certificate inventory
└── environments.csv               # Environment definitions/reference
```

The corrected uploader is supplied as `upload-certificates.py` with this runbook.

## 4. Prerequisites

Run the deployment from a workstation that has network access to the OpenShift API and routes.

Required commands:

```text
oc
curl
jq
python3
openssl
nc
```

Validate them:

```bash
for command in oc curl jq python3 openssl nc; do
  command -v "${command}" >/dev/null || echo "Missing command: ${command}"
done
```

Validate Python:

```bash
python3 --version
```

Log in to OpenShift before executing any cluster automation:

```bash
oc login https://api.<cluster-domain>:6443
```

For the current lab cluster, the API address is:

```bash
oc login https://api.itz-qia7l8.infra01-lb.wdc07.techzone.ibm.com:6443
```

Confirm the session and permissions:

```bash
oc whoami
oc whoami --show-server
oc auth can-i get pods -n concert
oc auth can-i get pods -n concert-hub
```

## 5. Optional one-time Concert installation

Skip this section when the `concert` and `concert-hub` namespaces already contain a working installation.

From the directory containing `install-concert.sh`:

```bash
chmod +x install-concert.sh
./install-concert.sh
```

Important:

- Run the installer only once for a given Concert instance.
- Use an IBM Concert 3.0.x package version approved for the lab.
- Enter the entitlement key and initial administrator password interactively when possible; do not commit them to scripts or CSV files.
- Do not proceed if required IBM route or Keycloak setup helpers are missing. Resolve the installer directory before continuing.

Verify namespaces:

```bash
oc get namespace concert
oc get namespace concert-hub
```

Verify workloads:

```bash
oc get pods -n concert
oc get pods -n concert-hub
```

All required pods must be `Running` or successfully `Completed` before continuing.

Verify routes:

```bash
oc get route -n concert
oc get route -n concert-hub
```

## 6. Post-install authentication and users

### 6.1 Set deployment variables

For the current lab instance:

```bash
export CONCERT_HUB_NS="concert-hub"
export CONCERT_NS="concert"
export CONCERT_REALM="concert-realm"
export CONCERT_CLIENT_ID="concert-client"

export CONCERT_URL="https://concert-concert.apps.itz-qia7l8.infra01-lb.wdc07.techzone.ibm.com/concert"
export CONCERT_HUB_URL="https://solis-hub-concert-hub.apps.itz-qia7l8.infra01-lb.wdc07.techzone.ibm.com"
```

`CONCERT_HUB_URL` must be the `solis-hub` route. Do not set it to the Concert application route.

### 6.2 Run post-install setup

```bash
cd Lab1a
chmod +x setup-concert.sh add-concert-users.sh
./setup-concert.sh
```

The post-install setup must verify:

- The Concert and Hub routes are reachable.
- The `concert-realm` realm exists.
- The `concert-client` client exists.
- The external redirect URI includes `<Concert URL>/platform_hub/*`.
- Hub OIDC configuration points to the external Keycloak route.
- Required Hub and Concert deployments successfully roll out.

The existence of a realm alone is not proof of complete OIDC configuration. IBM's supplied `setup-keycloak.sh` should be used when creating a new realm/client configuration.

### 6.3 Provision users

Example `concert-users.csv` header:

```csv
username,email,first_name,last_name,password
```

Protect the file because it contains temporary passwords:

```bash
chmod 600 concert-users.csv
```

If `setup-concert.sh` already processed `concert-users.csv`, do not immediately run the standalone user script again. Use the standalone script only when adding or updating users later:

```bash
./add-concert-users.sh concert-users.csv
```

Validate user provisioning in the output:

```text
Failures: 0
```

### 6.4 Validate browser login

Open a private browser window:

```text
https://concert-concert.apps.itz-qia7l8.infra01-lb.wdc07.techzone.ibm.com
```

Sign in using a provisioned Keycloak user. When changing group or role mappings, log out all existing sessions and start a new private browser session.

`fix-concert-auth.sh` is an OIDC remediation utility, not part of the certificate API authentication flow. The corrected certificate uploader does not inspect or depend on the internal Hub JWT role.

## 7. Install the corrected certificate uploader

Replace the existing `Lab1b/upload-certificates.py` with the corrected version and make it executable:

```bash
cd Lab1b
chmod +x upload-certificates.py
python3 -m py_compile upload-certificates.py
```

Display its options:

```bash
python3 upload-certificates.py --help
```

The corrected script must identify its authentication mechanism as:

```text
Authentication   : C_API_KEY
```

If the script prints `Automated JWT`, `Mode A`, `handle_login`, or `role: User`, it is the old version and must be replaced.

## 8. Generate and export a Concert API key

Sign in to Concert as the user who will own the API key. Generate a Concert API key and record both:

- API key secret
- Concert instance ID

The API key is shown as a secret and must not be shared in chat, source control, screenshots, or lab documentation.

Export the values locally:

```bash
export CONCERT_API_KEY="<new-concert-api-key>"
export CONCERT_INSTANCE_ID="0000-0000-0000-0000"
```

For the current deployment, `0000-0000-0000-0000` is the configured Concert instance ID and is valid.

The supported API headers are:

```text
Authorization: C_API_KEY <api-key>
InstanceID: <instance-id>
```

Do not use `ZenApiKey` and do not use the internal `handle_login` token.

## 9. Configure TLS verification

### Lab-only route certificate bypass

For a disposable lab with an untrusted OpenShift route certificate:

```bash
export CONCERT_SKIP_TLS="true"
```

### Preferred trusted CA configuration

For a persistent or production-like deployment:

```bash
export CONCERT_SKIP_TLS="false"
export CONCERT_CA_BUNDLE="/absolute/path/to/openshift-route-ca.pem"
```

Do not leave TLS verification disabled outside a controlled lab.

## 10. Create and verify the Concert environment

The certificate upload metadata must reference a Concert environment that exists and is visible to the API-key owner. The certificate CSV `Namespace` column is certificate metadata; it is not automatically a Concert environment.

Set the environment:

```bash
export CONCERT_ENV_NAME="retail-demo"
```

Derive the API base URL:

```bash
export CONCERT_BASE="${CONCERT_URL%/concert}"
```

The following `curl` examples use `-k` for the current disposable lab. For a trusted deployment, remove `-k` and use `--cacert "${CONCERT_CA_BUNDLE}"` when a custom CA bundle is required.

### 10.1 List visible environments

```bash
curl -ksS \
  "${CONCERT_BASE}/concert/core/api/v1/environments" \
  -H "Authorization: C_API_KEY ${CONCERT_API_KEY}" \
  -H "InstanceID: ${CONCERT_INSTANCE_ID}" |
jq '.. | objects | select(.name?) | {id, name, purpose}'
```

If `retail-demo` is already listed, continue to Step 10.3.

### 10.2 Create `retail-demo`

```bash
curl -ksS -w '\nHTTP %{http_code}\n' \
  -X POST \
  "${CONCERT_BASE}/concert/core/api/v1/environments" \
  -H "Authorization: C_API_KEY ${CONCERT_API_KEY}" \
  -H "InstanceID: ${CONCERT_INSTANCE_ID}" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  --data '{
    "name": "retail-demo",
    "purpose": "production",
    "description": "Retail demo environment for certificate and SBOM ingestion"
  }'
```

Expected result:

```text
HTTP 200
```

or:

```text
HTTP 201
```

Interpret other responses as follows:

| HTTP status | Action |
| --- | --- |
| 400 | Review the response body and environment payload. |
| 401 | Regenerate or correctly export the API key. |
| 403 | Use an administrator account or grant the API-key owner permission to create environments. |
| 409 | The environment probably exists; verify object-level visibility/access instead of creating it again. |

### 10.3 Verify exact visibility

```bash
curl -ksS \
  "${CONCERT_BASE}/concert/core/api/v1/environments" \
  -H "Authorization: C_API_KEY ${CONCERT_API_KEY}" \
  -H "InstanceID: ${CONCERT_INSTANCE_ID}" |
jq '.. | objects | select(.name? == "retail-demo") | {id, name, purpose}'
```

This command must return the `retail-demo` environment. If it does not, use **Inventory > Environments > retail-demo > Collaborators** in the Concert UI and grant the API-key owner an appropriate role.

For a quick test, an already-visible environment such as `Testing` can be used instead:

```bash
export CONCERT_ENV_NAME="Testing"
```

## 11. Validate and upload the certificate CSV

Confirm the file is present:

```bash
cd Lab1b
ls -l concert-certificates.csv upload-certificates.py
```

Run the upload:

```bash
python3 upload-certificates.py concert-certificates.csv
```

Expected preflight output includes:

```text
Authentication   : C_API_KEY
Environment      : retail-demo
Environment check: enabled
Read 7 certificate row(s) across 1 environment(s): retail-demo
Environment preflight passed.
```

Expected ingestion output includes:

```text
Upload accepted with HTTP 202.
Event ID   : <event-id>
Record path: <record-path>
```

The script then polls the certificate API until the seven certificate serial numbers appear.

### Exit codes

| Exit code | Meaning | Action |
| --- | --- | --- |
| 0 | Upload accepted and all certificates confirmed | Continue to UI verification. |
| 1 | Validation, authentication, upload, or verification failure | Correct the reported error before rerunning. |
| 2 | Upload accepted but processing was not confirmed before timeout | Search the Event log and inspect pipeline logs. |

Capture the exit code when automating the lab:

```bash
python3 upload-certificates.py concert-certificates.csv
UPLOAD_RC=$?
echo "Certificate upload exit code: ${UPLOAD_RC}"
```

Do not report a completed import when the exit code is `2`.

## 12. Verify certificate ingestion

### 12.1 Verify with the Concert API

```bash
curl -ksS \
  "${CONCERT_BASE}/concert/core/api/v1/certificates" \
  -H "Authorization: C_API_KEY ${CONCERT_API_KEY}" \
  -H "InstanceID: ${CONCERT_INSTANCE_ID}" |
jq '.pagination, (.certificates[]? | {
  name,
  serial_number,
  valid_from,
  valid_to,
  namespace
})'
```

The pagination `total_count` must be greater than zero, and the uploaded serial numbers should be present.

### 12.2 Verify in the Concert UI

Open Concert in a private browser session and navigate to:

```text
Operations > Certificates
```

Select or filter for the target environment as required.

### 12.3 Verify the ingestion event

Navigate to:

```text
Administration > Event log
```

Search using the event ID or generated upload filename printed by the uploader. Open the event to review its status and subordinate processing events.

## 13. Troubleshooting

### Environment does not exist or is not visible

Example:

```text
Visible environments: Testing
retail-demo does not exist or is not visible
```

Resolution:

1. Create `retail-demo` using Step 10.2, or use `Testing`.
2. Grant the API-key owner access under the environment's **Collaborators** page.
3. Repeat the exact visibility check in Step 10.3.

### HTTP 401 or 403

Check:

- Header type is exactly `C_API_KEY`.
- `CONCERT_API_KEY` contains the current unrevoked key.
- `CONCERT_INSTANCE_ID` matches the instance ID displayed with the key.
- The API-key owner has the required instance- and object-level permissions.

### HTTP 202 but certificates do not appear

HTTP 202 means the file was staged, not fully processed.

1. Search the Concert Event log using the returned event ID.
2. Check background processing logs:

```bash
oc logs -n concert deployment/roja-pipeline \
  --all-containers=true --since=30m |
grep -Ei 'certificate|error|failed|401|403|event'
```

```bash
oc logs -n concert deployment/rojacore \
  --all-containers=true --since=30m |
grep -Ei 'certificate|error|failed|401|403'
```

3. Verify that the target environment is still visible to the API-key owner.
4. Do not repeatedly upload the same file until the previous event status is known.

### Old script still prints `JWT role: User`

This indicates that the previous uploader is still installed. Replace it with the corrected `C_API_KEY` version from Step 7. The corrected uploader does not call `handle_login` and does not require:

```text
CONCERT_USERNAME
CONCERT_PASSWORD
CONCERT_HUB_URL
```

### Exit code 2

Increase the polling period only after checking the Event log:

```bash
export CONCERT_POLL_TIMEOUT="600"
export CONCERT_POLL_INTERVAL="10"
python3 upload-certificates.py concert-certificates.csv
```

## 14. Optional SBOM upload

After the environment and API authentication are validated, the same values can be reused by a corrected SBOM uploader:

```bash
export CONCERT_API_KEY="<new-concert-api-key>"
export CONCERT_INSTANCE_ID="0000-0000-0000-0000"
export CONCERT_ENV_NAME="retail-demo"

python3 ../Lab1c/upload-sbom.py
```

The SBOM uploader must also use:

```text
Authorization: C_API_KEY <api-key>
```

and must not use `ZenApiKey` or `handle_login`.

## 15. Complete execution order

### Existing Concert installation

```text
1. oc login
2. Export Concert and Hub URLs
3. Run setup-concert.sh if post-install OIDC setup is incomplete
4. Provision/update users only when required
5. Validate private-browser login
6. Install and compile the corrected upload-certificates.py
7. Generate/export CONCERT_API_KEY and CONCERT_INSTANCE_ID
8. Configure trusted CA or lab-only TLS bypass
9. Create and verify the retail-demo environment
10. Upload concert-certificates.csv
11. Check the script exit code
12. Verify the event, API records, and Concert UI
```

### New Concert installation

```text
1. oc login
2. Run install-concert.sh once
3. Validate pods and routes
4. Run setup-concert.sh
5. Provision users
6. Validate private-browser login
7. Continue with Steps 6-12 from the existing-installation sequence
```

Use `&&` when chaining commands so processing stops after a failure. Do not use semicolons for the deployment sequence.

## 16. Security cleanup

After the deployment or lab session:

```bash
unset CONCERT_API_KEY
unset CONCERT_PASSWORD
unset CONCERT_ADMIN_PASSWORD
```

Additional requirements:

- Revoke and regenerate any API key or password exposed in chat, terminal recordings, screenshots, or shared logs.
- Do not commit `concert-users.csv`, API keys, passwords, Keycloak secrets, or entitlement keys to source control.
- Use `chmod 600` on local files containing temporary credentials.
- Replace `CONCERT_SKIP_TLS=true` with a trusted CA bundle for persistent environments.
- Use separate API keys for administrators and lab automation where possible.

## 17. IBM references

- [API reference and authentication](https://www.ibm.com/docs/en/concert/3.0.x?topic=api-reference-authentication)
- [Uploading certificate details](https://www.ibm.com/docs/en/concert/3.0.x?topic=certificates-uploading-certificate-details)
- [Integrating OpenID Connect with Keycloak on Kubernetes](https://www.ibm.com/docs/en/concert/3.0.x?topic=idp-integrating-openid-connect-keycloak-kubernetes)
- [Granting access to applications and environments](https://www.ibm.com/docs/en/concert/3.0.x?topic=roles-granting-access-applications-environments)
- [Event log](https://www.ibm.com/docs/en/concert/3.0.x?topic=event-log)
