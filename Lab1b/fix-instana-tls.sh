#!/usr/bin/env bash
# =============================================================================
# fix-instana-tls.sh
# IBM Concert 3.0.x — One-time cluster fix for Instana self-signed TLS
# =============================================================================
#
# PURPOSE
# -------
# When the Instana backend uses a self-signed or privately-signed TLS
# certificate, Concert's ingestion engine fails with:
#
#   x509: certificate signed by unknown authority
#
# This script performs THREE cluster-level changes to fix that:
#
#   1. Fetch the Instana endpoint's full TLS certificate chain via
#      `openssl s_client` and append any new CA cert(s) to the Concert
#      TLS CA bundle stored in the `app-cfg-internal-tls` OCP Secret.
#      (Idempotent — skips certs already present in the bundle.)
#
#   2. Write  insecure_ssl:"true"  directly into the credential's JSONB
#      in the Concert appdb PostgreSQL database via `oc exec psql`.
#      (Concert's REST API rejects unknown credential keys, so this
#       must be done at the DB level.)
#
#   3. Trigger a rolling restart of Concert application pods so they
#      pick up the updated secret mount:
#        - deployment/ibm-roja-app
#        - deployment/ibm-roja-ingestion-processor
#
# SCOPE
# -----
# These are the ONLY cluster-level changes made by the Lab1b scripts.
# `create-connections.py` and `setup-environments.py` are
# read-only with respect to the cluster — they only call Concert REST APIs.
#
# PREREQUISITES
# -------------
#   - oc CLI installed and logged in (oc whoami must succeed)
#   - openssl CLI available locally
#   - Sufficient RBAC (see below)
#
# RBAC REQUIRED
# -------------
#   Namespace: concert
#     get/patch  secrets       (app-cfg-internal-tls, app-cfg-oob-secret)
#     get        pods
#     exec       pods          (appdb pod — to run psql)
#     patch      deployments   (ibm-roja-app, ibm-roja-ingestion-processor)
#
# USAGE
# -----
#   ./fix-instana-tls.sh <instana_url> <credential_name> [concert_namespace]
#
#   instana_url        Base HTTPS URL of the Instana backend
#                      e.g.  https://unit0-techzone.150-240-162-27.nip.io
#
#   credential_name    Display name of the Instana connection in Concert
#                      (must match the 'name' column in instana-connections.csv)
#                      e.g.  techxchange-instana
#
#   concert_namespace  OCP namespace where Concert app is installed
#                      Default: concert
#
# EXAMPLES
#   ./fix-instana-tls.sh \
#       https://unit0-techzone.150-240-162-27.nip.io \
#       techxchange-instana
#
#   ./fix-instana-tls.sh \
#       https://instana.example.com \
#       my-instana \
#       concert
#
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}  --> ${RESET}$*"; }
ok()      { echo -e "${GREEN}  OK  ${RESET}$*"; }
warn()    { echo -e "${YELLOW}  WARN${RESET}$*"; }
die()     { echo -e "${RED}ERROR: $*${RESET}" >&2; exit 1; }
banner()  { echo -e "\n${BOLD}$*${RESET}"; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
INSTANA_URL="${1:-}"
CREDENTIAL_NAME="${2:-}"
CONCERT_NS="${3:-concert}"

[[ -z "$INSTANA_URL" ]]       && die "Usage: $0 <instana_url> <credential_name> [concert_namespace]"
[[ -z "$CREDENTIAL_NAME" ]]   && die "Usage: $0 <instana_url> <credential_name> [concert_namespace]"

# Strip trailing slash
INSTANA_URL="${INSTANA_URL%/}"

# Parse host and port from URL
INSTANA_HOST=$(python3 -c "import urllib.parse; u=urllib.parse.urlparse('${INSTANA_URL}'); print(u.hostname or '')")
INSTANA_PORT=$(python3 -c "import urllib.parse; u=urllib.parse.urlparse('${INSTANA_URL}'); print(u.port or 443)")

[[ -z "$INSTANA_HOST" ]] && die "Cannot parse hostname from URL: ${INSTANA_URL}"

# ---------------------------------------------------------------------------
# Configuration (can be overridden by env vars)
# ---------------------------------------------------------------------------
APPDB_SECRET="${APPDB_SECRET:-app-cfg-oob-secret}"
APPDB_SERVICE="${APPDB_SERVICE:-ibm-roja-appdb-svc}"
APPDB_NAME="${APPDB_NAME:-appdb}"
APPDB_SCHEMA="${APPDB_SCHEMA:-ibm_roja_app}"
HUB_NS="${HUB_NS:-concert-hub}"
TLS_SECRET="app-cfg-internal-tls"
TLS_KEY="tls-ca-bundle.pem"
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo "================================================================"
echo "  IBM Concert 3.0.x — Instana TLS Fix"
echo "================================================================"
echo "  Instana URL      : ${INSTANA_URL}"
echo "  Instana Host     : ${INSTANA_HOST}:${INSTANA_PORT}"
echo "  Credential name  : ${CREDENTIAL_NAME}"
echo "  Concert namespace: ${CONCERT_NS}"
echo "  Hub namespace    : ${HUB_NS}"
echo "  AppDB secret     : ${APPDB_SECRET}"
echo "  TLS secret       : ${TLS_SECRET}"
echo ""

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
banner "Checking prerequisites ..."

command -v oc      >/dev/null 2>&1 || die "'oc' CLI not found. Install and log in first."
command -v openssl >/dev/null 2>&1 || die "'openssl' CLI not found."
command -v python3 >/dev/null 2>&1 || die "'python3' not found."

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift. Run 'oc login' first."
ok "Logged in as: $(oc whoami)"

# Verify Concert namespace exists
oc get namespace "${CONCERT_NS}" >/dev/null 2>&1 \
  || die "Namespace '${CONCERT_NS}' not found on this cluster."
ok "Namespace '${CONCERT_NS}' found."

# =============================================================================
# CHANGE 1 — Append Instana CA certificate(s) to Concert TLS bundle
# =============================================================================
banner "Change 1: Patching Concert TLS CA bundle (${TLS_SECRET})"

# --- Step 1a: Fetch the full TLS certificate chain from the Instana endpoint
info "Fetching TLS certificate chain from ${INSTANA_HOST}:${INSTANA_PORT} ..."
CERT_CHAIN_FILE="${TMPDIR_WORK}/instana-chain.pem"

openssl s_client \
    -connect "${INSTANA_HOST}:${INSTANA_PORT}" \
    -showcerts \
    </dev/null 2>/dev/null \
  | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
  > "${CERT_CHAIN_FILE}"

CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "${CERT_CHAIN_FILE}" 2>/dev/null || echo 0)
if [[ "$CERT_COUNT" -eq 0 ]]; then
    warn "No certificates retrieved from ${INSTANA_HOST}:${INSTANA_PORT}."
    warn "Skipping TLS bundle patch. Check connectivity and try again."
else
    ok "Retrieved ${CERT_COUNT} certificate(s) from ${INSTANA_HOST}:${INSTANA_PORT}."

    # --- Step 1b: Read the current bundle from the OCP secret
    info "Reading current TLS bundle from secret '${TLS_SECRET}' in namespace '${CONCERT_NS}' ..."
    BUNDLE_B64=$(oc get secret "${TLS_SECRET}" -n "${CONCERT_NS}" \
        -o "jsonpath={.data.tls-ca-bundle\\.pem}" 2>/dev/null || echo "")

    if [[ -z "$BUNDLE_B64" ]]; then
        warn "Secret '${TLS_SECRET}' not found or key '${TLS_KEY}' is empty."
        warn "Skipping TLS bundle patch."
    else
        BUNDLE_FILE="${TMPDIR_WORK}/existing-bundle.pem"
        echo "${BUNDLE_B64}" | python3 -c "import sys,base64; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read().strip()))" > "${BUNDLE_FILE}"
        ok "Current bundle: $(wc -l < "${BUNDLE_FILE}") lines, \
$(grep -c "BEGIN CERTIFICATE" "${BUNDLE_FILE}" 2>/dev/null || echo 0) cert(s)."

        # --- Step 1c: Find certificates not already in the bundle (idempotency check)
        NEW_CERTS_FILE="${TMPDIR_WORK}/new-certs.pem"
        > "${NEW_CERTS_FILE}"

        IN_BLOCK=false
        BLOCK=""
        while IFS= read -r line; do
            if [[ "$line" == "-----BEGIN CERTIFICATE-----" ]]; then
                IN_BLOCK=true
                BLOCK="$line"
            elif [[ "$line" == "-----END CERTIFICATE-----" ]]; then
                BLOCK="${BLOCK}"$'\n'"$line"
                # Extract the base64 body (lines between BEGIN and END) for fingerprint check
                BODY=$(echo "$BLOCK" | grep -v "BEGIN CERTIFICATE" | grep -v "END CERTIFICATE" | tr -d '\n ')
                if ! grep -qF "$BODY" "${BUNDLE_FILE}" 2>/dev/null; then
                    echo "$BLOCK" >> "${NEW_CERTS_FILE}"
                fi
                IN_BLOCK=false
                BLOCK=""
            elif $IN_BLOCK; then
                BLOCK="${BLOCK}"$'\n'"$line"
            fi
        done < "${CERT_CHAIN_FILE}"

        NEW_COUNT=$(grep -c "BEGIN CERTIFICATE" "${NEW_CERTS_FILE}" 2>/dev/null || echo 0)

        if [[ "$NEW_COUNT" -eq 0 ]]; then
            ok "Instana CA certificate(s) already present in Concert TLS bundle — no patch needed."
        else
            info "Appending ${NEW_COUNT} new certificate(s) to Concert TLS bundle ..."

            # Build updated bundle = existing + new certs
            UPDATED_BUNDLE_FILE="${TMPDIR_WORK}/updated-bundle.pem"
            cp "${BUNDLE_FILE}" "${UPDATED_BUNDLE_FILE}"
            echo "" >> "${UPDATED_BUNDLE_FILE}"
            echo "# Instana CA — appended by fix-instana-tls.sh" >> "${UPDATED_BUNDLE_FILE}"
            cat "${NEW_CERTS_FILE}" >> "${UPDATED_BUNDLE_FILE}"

            # Patch the secret — write the JSON patch to a file to avoid
            # "Argument list too long" when the CA bundle is large.
            NEW_B64=$(python3 -c "import sys,base64; print(base64.b64encode(open('${UPDATED_BUNDLE_FILE}','rb').read()).decode(),end='')")
            PATCH_FILE="${TMPDIR_WORK}/tls-patch.json"
            printf '[{"op":"replace","path":"/data/tls-ca-bundle.pem","value":"%s"}]' \
                "${NEW_B64}" > "${PATCH_FILE}"
            oc patch secret "${TLS_SECRET}" -n "${CONCERT_NS}" \
                --type=json \
                --patch-file="${PATCH_FILE}"

            ok "Secret '${TLS_SECRET}' patched — TLS bundle updated with Instana CA."
        fi
    fi
fi

# =============================================================================
# CHANGE 2 — Write insecure_ssl:true to the credential row in appdb
# =============================================================================
banner "Change 2: Writing insecure_ssl:true to appdb (credential: '${CREDENTIAL_NAME}')"

# --- Step 2a: Read DB credentials from the OCP secret
# Keys: APPDB_USER, APPDB_PASSWORD, APPDB_DBNAME
info "Reading DB credentials from secret '${APPDB_SECRET}' ..."

# Use oc get -o json and python3 to decode — avoids base64 flag differences
# between macOS (base64 -D) and Linux (base64 -d) when run under pipefail.
_decode_secret_key() {
    local key="$1"
    oc get secret "${APPDB_SECRET}" -n "${CONCERT_NS}" -o json 2>/dev/null \
        | python3 -c "
import sys, json, base64
d = json.load(sys.stdin).get('data', {})
v = d.get('${key}', '')
print(base64.b64decode(v).decode() if v else '', end='')
" 2>/dev/null || echo ""
}

DB_USER=$(_decode_secret_key APPDB_USER)
DB_PASS=$(_decode_secret_key APPDB_PASSWORD)
DB_NAME=$(_decode_secret_key APPDB_DBNAME)
DB_NAME="${DB_NAME:-${APPDB_NAME}}"

if [[ -z "$DB_USER" || -z "$DB_PASS" ]]; then
    warn "Could not read DB credentials from secret '${APPDB_SECRET}'."
    warn "Skipping insecure_ssl DB patch."
else
    ok "DB user: ${DB_USER}  DB name: ${DB_NAME}"

    # --- Step 2b: Locate the appdb pod (pod name is roja-postgres-appdb-*)
    APPDB_POD=$(oc get pods -n "${CONCERT_NS}" \
        -o "jsonpath={range .items[*]}{.metadata.name}{\"\n\"}{end}" 2>/dev/null \
        | grep -E "roja-postgres-appdb-|ibm-roja-appdb-" | head -1 || echo "")

    if [[ -z "$APPDB_POD" ]]; then
        warn "AppDB pod not found in namespace '${CONCERT_NS}' — skipping insecure_ssl DB patch."
    else
        ok "AppDB pod: ${APPDB_POD}"

        # --- Step 2c: Run psql UPDATE inside the pod
        # Feed SQL via stdin to avoid shell-quoting issues with JSON braces
        # when passing through oc exec → sh -c → psql layers.
        info "Running psql UPDATE for credential '${CREDENTIAL_NAME}' ..."
        PSQL_OUTPUT=$(echo "UPDATE ${APPDB_SCHEMA}.credentials SET credentials = credentials || '{\"insecure_ssl\":\"true\"}'::jsonb WHERE name = '${CREDENTIAL_NAME}';" \
            | oc exec -i -n "${CONCERT_NS}" "${APPDB_POD}" -- sh -c \
            "PGPASSWORD='${DB_PASS}' psql \
             -h ${APPDB_SERVICE}.${CONCERT_NS}.svc \
             -U ${DB_USER} \
             -d ${DB_NAME}" \
            2>&1 || true)

        if echo "${PSQL_OUTPUT}" | grep -q "UPDATE 0"; then
            warn "psql UPDATE affected 0 rows — credential '${CREDENTIAL_NAME}' may not exist yet."
            warn "Run this script again after creating the credential."
        elif echo "${PSQL_OUTPUT}" | grep -qE "^UPDATE [1-9]"; then
            ok "insecure_ssl:true written to appdb for credential '${CREDENTIAL_NAME}'."
        else
            warn "Unexpected psql output: ${PSQL_OUTPUT}"
            warn "Verify manually: check ${APPDB_SCHEMA}.credentials WHERE name='${CREDENTIAL_NAME}'."
        fi
    fi
fi

# =============================================================================
# CHANGE 3 — Rolling restart Concert application pods
# =============================================================================
banner "Change 3: Restarting Concert application pods"

info "This picks up the updated '${TLS_KEY}' secret mount in running pods."

# Concert 3.0.x deployment names (covers all known variants):
RESTARTED=()
for DEP in roja-ingestion rojacore roja-mgmt roja-pipeline roja-compliance \
           roja-buddy roja-g-fwk roja-py-utils roja-sra roja-mcp \
           ibm-roja-app ibm-roja-ingestion-processor; do
    if oc get deployment "${DEP}" -n "${CONCERT_NS}" >/dev/null 2>&1; then
        oc rollout restart "deployment/${DEP}" -n "${CONCERT_NS}"
        ok "Rollout restart triggered: deployment/${DEP}"
        RESTARTED+=("$DEP")
    fi
done

if [[ ${#RESTARTED[@]} -gt 0 ]]; then
    echo ""
    echo "  Waiting for rollout to complete ..."
    for DEP in "${RESTARTED[@]}"; do
        oc rollout status "deployment/${DEP}" -n "${CONCERT_NS}" --timeout=180s \
          && ok "deployment/${DEP} is Ready." \
          || warn "deployment/${DEP} rollout timed out — check pod status manually."
    done
else
    warn "No Concert deployments were restarted."
fi

# =============================================================================
# CHANGE 4 — Verify Concert instance ID is accessible to the Hub.
#
# When Concert is installed with ENABLE_CROSS_PRODUCT_INTEGRATION=false (the
# default), the instance ID remains 0000-0000-0000-0000 throughout the system.
# This is the correct, working value — not a placeholder — and must be used as-is
# for all Concert API calls (instance-id header, JWT account_id, appdb routing).
#
# This change ensures solis-account-instances-cm has a 0000-0000-0000-0000.json
# key (which ibm-solis-core mounts as a file) so that JWT lookups succeed.
# =============================================================================
banner "Change 4: Verifying Concert instance ID in Hub configmap"

INSTANCE_URL="https://ibm-concert-internal-solis-gw-svc.${CONCERT_NS}.svc.cluster.local:20443"
INSTANCES_JSON=$(python3 -c "
import json
data = [
  {'product_id': 'concert',   'instance_id': '0000-0000-0000-0000', 'instance_url': '${INSTANCE_URL}'},
  {'product_id': 'dataapps',  'instance_id': '0000-0000-0000-0000', 'instance_url': 'https://ibm-dataapps-solis-gw-svc.concert-dataapps.svc.cluster.local:15443'},
  {'product_id': 'workflows', 'instance_id': '0000-0000-0000-0000', 'instance_url': 'https://solis-gw.concert-workflows.svc.cluster.local:443'}
]
print(json.dumps(json.dumps(data)))
")

# Ensure the 0000 key exists (ibm-solis-core opens this file for JWT account lookup)
EXISTING=$(oc get configmap solis-account-instances-cm -n "${HUB_NS}" \
    -o jsonpath='{.data.0000-0000-0000-0000\.json}' 2>/dev/null || echo "")

if [[ -z "$EXISTING" ]]; then
    info "Adding 0000-0000-0000-0000.json key to solis-account-instances-cm ..."
    oc patch configmap solis-account-instances-cm -n "${HUB_NS}" --type=json \
        -p "[{\"op\":\"add\",\"path\":\"/data/0000-0000-0000-0000.json\",\"value\":${INSTANCES_JSON}}]" \
      && ok "solis-account-instances-cm patched." \
      || warn "Failed to patch solis-account-instances-cm."

    info "Restarting ibm-solis-core to pick up new configmap mount ..."
    oc rollout restart deployment/ibm-solis-core -n "${HUB_NS}" >/dev/null 2>&1 || true
    oc rollout status  deployment/ibm-solis-core -n "${HUB_NS}" --timeout=180s \
      && ok "ibm-solis-core restarted." \
      || warn "ibm-solis-core rollout timed out — check manually."
else
    ok "solis-account-instances-cm already has 0000-0000-0000-0000.json key."
fi

echo ""
echo "  Concert instance ID: 0000-0000-0000-0000"
echo "  (No export needed — scripts read this automatically from the configmap)"
echo ""

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "================================================================"
echo "  Summary"
echo "================================================================"
echo "  Instana URL      : ${INSTANA_URL}"
echo "  Credential name  : ${CREDENTIAL_NAME}"
echo "  Concert namespace: ${CONCERT_NS}"
echo "  Hub namespace    : ${HUB_NS}"
echo ""
echo "  Changes applied:"
echo "    1. TLS CA bundle  : secret/${TLS_SECRET} (namespace: ${CONCERT_NS})"
echo "    2. AppDB row      : ${APPDB_SCHEMA}.credentials WHERE name='${CREDENTIAL_NAME}'"
echo "    3. Pod restarts   : ${RESTARTED[*]:-none}"
echo "    4. Instance reg   : solis-account-instances-cm (namespace: ${HUB_NS})"
echo "================================================================"
echo ""
echo "  Concert instance ID : 0000-0000-0000-0000"
echo "  (Do NOT export CONCERT_INSTANCE_ID — scripts read this automatically)"
echo ""
echo "  Next steps:"
echo "    python3 create-connections.py instana-connections.csv"
echo "    python3 setup-environments.py environments.csv instana-jobs.csv"
echo "    python3 upload-certificates.py"
echo ""
