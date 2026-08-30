#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# IBM Concert 3.0.x - End-to-End OpenShift Installer
#
# Target:
#   - OpenShift Container Platform
#   - x86_64 / amd64
#   - Local Concert Platform Hub
#   - IBM Concert
#   - Concert Data Apps
#   - Concert Workflows
#   - Secure Coder (configurable)
#   - Keycloak/OIDC initialization
#
# Assumptions:
#   1. You have already authenticated to the target cluster with `oc login`.
#   2. The current OpenShift user has cluster-admin privileges.
#   3. The cluster has dynamic RWO and RWX storage.
#   4. Internet access is available to GitHub and IBM entitled registries.
#
# Typical usage:
#   chmod +x install-concert.sh
#   ./install-concert.sh
#
# Non-interactive example:
#   CONCERT_ADMIN_USER=admin \
#   CONCERT_ADMIN_PASSWORD='StrongPassword' \
#   IBM_ENTITLEMENT_KEY='...' \
#   ./install-concert.sh
#
# Optional overrides:
#   CONCERT_VERSION=3.0.0
#   BASE_DIR=/opt
#   INSTALL_DATAAPPS=true
#   INSTALL_WORKFLOWS=true
#   INSTALL_SECURECODER=true
#   WORKFLOWS_INSTALL_ALL_INTEGRATIONS=true
#   ENABLE_AI=false
#   ENABLE_BUDDY=true
#   ENABLE_CROSS_PRODUCT_INTEGRATION=false
#   BLOCK_STORAGE_CLASS=<rwo-sc>
#   FILE_STORAGE_CLASS=<rwx-sc>
#   CONFIGURE_SSO=true
###############################################################################

CONCERT_VERSION="${CONCERT_VERSION:-3.0.0}"
BASE_DIR="${BASE_DIR:-/opt}"
INSTALL_DIR="${INSTALL_DIR:-${BASE_DIR}/ibm-concert}"
PACKAGE_NAME="${PACKAGE_NAME:-ibm-concert-x86.tar.gz}"
DOWNLOAD_URL="${DOWNLOAD_URL:-https://github.com/IBM/Concert/releases/download/v${CONCERT_VERSION}/${PACKAGE_NAME}}"

HUB_NS="${HUB_NS:-concert-hub}"
CONCERT_NS="${CONCERT_NS:-concert}"
DATAAPPS_NS="${DATAAPPS_NS:-concert-dataapps}"
WORKFLOWS_NS="${WORKFLOWS_NS:-concert-workflows}"
SECURECODER_NS="${SECURECODER_NS:-concert-securecoder}"

INSTALL_DATAAPPS="${INSTALL_DATAAPPS:-true}"
INSTALL_WORKFLOWS="${INSTALL_WORKFLOWS:-true}"
INSTALL_SECURECODER="${INSTALL_SECURECODER:-true}"
WORKFLOWS_INSTALL_ALL_INTEGRATIONS="${WORKFLOWS_INSTALL_ALL_INTEGRATIONS:-true}"
ENABLE_AI="${ENABLE_AI:-false}"
ENABLE_BUDDY="${ENABLE_BUDDY:-true}"
ENABLE_CROSS_PRODUCT_INTEGRATION="${ENABLE_CROSS_PRODUCT_INTEGRATION:-false}"
CONFIGURE_SSO="${CONFIGURE_SSO:-true}"

CONCERT_REALM="${CONCERT_REALM:-concert-realm}"
CONCERT_CLIENT_ID="${CONCERT_CLIENT_ID:-concert-client}"

LOG_FILE="${LOG_FILE:-/tmp/ibm-concert-install-$(date +%Y%m%d-%H%M%S).log}"

###############################################################################
# Helpers
###############################################################################

log()  { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[SUCCESS] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

bool_true() {
  [[ "${1,,}" == "true" || "${1,,}" == "yes" || "$1" == "1" ]]
}

set_param() {
  local key="$1"
  local value="$2"
  local file="$3"

  if grep -qE "^${key}=" "$file"; then
    sed -i.bak -E "s|^${key}=.*$|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

get_default_sc() {
  oc get sc -o json | jq -r '
    .items[]
    | select(
        .metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true"
        or
        .metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true"
      )
    | .metadata.name
  ' | head -1
}

discover_file_sc() {
  local candidates=(
    "ocs-storagecluster-cephfs"
    "ocs-external-storagecluster-cephfs"
  )

  local sc
  for sc in "${candidates[@]}"; do
    if oc get sc "$sc" >/dev/null 2>&1; then
      printf '%s\n' "$sc"
      return 0
    fi
  done

  oc get sc -o json | jq -r '
    .items[]
    | select(
        (.provisioner | ascii_downcase | contains("cephfs"))
        or
        (.metadata.name | ascii_downcase | contains("cephfs"))
      )
    | .metadata.name
  ' | head -1
}

wait_deployment_if_present() {
  local ns="$1"
  local deployment="$2"

  if oc get deployment "$deployment" -n "$ns" >/dev/null 2>&1; then
    log "Waiting for deployment ${ns}/${deployment}..."
    oc rollout status "deployment/${deployment}" -n "$ns" --timeout=15m
  fi
}

###############################################################################
# Preflight
###############################################################################

echo "================================================================"
echo " IBM Concert ${CONCERT_VERSION} - OpenShift Installation"
echo "================================================================"

require_cmd oc
require_cmd curl
require_cmd jq
require_cmd tar
require_cmd sed
require_cmd grep

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift. Run oc login first."

CURRENT_USER="$(oc whoami)"
API_SERVER="$(oc whoami --show-server)"
log "OpenShift user: ${CURRENT_USER}"
log "API server: ${API_SERVER}"

if [[ "$(oc auth can-i '*' '*' --all-namespaces 2>/dev/null || true)" != "yes" ]]; then
  die "The current OpenShift user does not have cluster-admin-level permissions."
fi

ARCH="$(oc get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || true)"
[[ "$ARCH" == "amd64" || "$ARCH" == "x86_64" ]] || \
  die "This script targets x86_64/amd64. Detected architecture: ${ARCH:-unknown}"

ok "Detected supported x86_64/amd64 OpenShift cluster."

if bool_true "$INSTALL_WORKFLOWS"; then
  require_cmd helm
  log "Helm: $(helm version --short 2>/dev/null || true)"
fi

APPS_DOMAIN="$(oc get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
[[ -n "$APPS_DOMAIN" ]] || die "Could not determine OpenShift apps domain."
log "OpenShift apps domain: ${APPS_DOMAIN}"

###############################################################################
# Credentials
###############################################################################

CONCERT_ADMIN_USER="${CONCERT_ADMIN_USER:-admin}"

if [[ -z "${CONCERT_ADMIN_PASSWORD:-}" ]]; then
  read -r -s -p "Concert initial admin password: " CONCERT_ADMIN_PASSWORD
  echo
fi

[[ -n "$CONCERT_ADMIN_PASSWORD" ]] || die "Concert admin password cannot be empty."

if [[ -z "${IBM_ENTITLEMENT_KEY:-}" ]]; then
  read -r -s -p "IBM Entitlement Key: " IBM_ENTITLEMENT_KEY
  echo
fi

[[ -n "$IBM_ENTITLEMENT_KEY" ]] || die "IBM Entitlement Key cannot be empty."

###############################################################################
# Storage discovery
###############################################################################

BLOCK_STORAGE_CLASS="${BLOCK_STORAGE_CLASS:-$(get_default_sc)}"
[[ -n "$BLOCK_STORAGE_CLASS" ]] || \
  die "No default block storage class was found. Set BLOCK_STORAGE_CLASS explicitly."

if ! oc get sc "$BLOCK_STORAGE_CLASS" >/dev/null 2>&1; then
  die "StorageClass '${BLOCK_STORAGE_CLASS}' does not exist."
fi

FILE_STORAGE_CLASS="${FILE_STORAGE_CLASS:-$(discover_file_sc)}"

if bool_true "$ENABLE_BUDDY"; then
  [[ -n "$FILE_STORAGE_CLASS" ]] || \
    die "Buddy requires FILE_STORAGE_CLASS_CONCERT. Set FILE_STORAGE_CLASS to an RWX storage class."

  oc get sc "$FILE_STORAGE_CLASS" >/dev/null 2>&1 || \
    die "File StorageClass '${FILE_STORAGE_CLASS}' does not exist."
fi

log "Block storage class: ${BLOCK_STORAGE_CLASS}"
if [[ -n "$FILE_STORAGE_CLASS" ]]; then
  log "File/RWX storage class: ${FILE_STORAGE_CLASS}"
fi

###############################################################################
# Download and extract
###############################################################################

mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

if [[ ! -x "${INSTALL_DIR}/bin/setup" ]]; then
  log "IBM Concert installer not found at ${INSTALL_DIR}. Downloading ${DOWNLOAD_URL}"

  TMP_PACKAGE="/tmp/${PACKAGE_NAME}"
  curl -fL "$DOWNLOAD_URL" -o "$TMP_PACKAGE"

  log "Extracting package..."
  tar xfz "$TMP_PACKAGE" -C "$BASE_DIR"

  [[ -x "${INSTALL_DIR}/bin/setup" ]] || \
    die "Extraction completed, but ${INSTALL_DIR}/bin/setup was not found."
else
  log "Existing installer found at ${INSTALL_DIR}; download skipped."
fi

###############################################################################
# Configure params.ini
###############################################################################

PARAMS="${INSTALL_DIR}/etc/params.ini"
SAMPLE="${INSTALL_DIR}/etc/sample-params/concert-dataapps-workflows-k8s-params.ini"

[[ -f "$SAMPLE" ]] || \
  die "Expected sample parameters file not found: $SAMPLE"

if [[ -f "$PARAMS" ]]; then
  cp "$PARAMS" "${PARAMS}.preinstall.$(date +%Y%m%d-%H%M%S).bak"
fi

cp "$SAMPLE" "$PARAMS"

log "Configuring ${PARAMS}..."

set_param LICENSE_ACCEPTANCE y "$PARAMS"
set_param INSTALL_EKS false "$PARAMS"
set_param INSTALL_VM false "$PARAMS"

set_param REG_USER cp "$PARAMS"
set_param IMAGE_REGISTRY_PREFIX cp.icr.io/cp "$PARAMS"

set_param INSTALL_CONCERT true "$PARAMS"
set_param INSTALL_DATAAPPS "$INSTALL_DATAAPPS" "$PARAMS"
set_param INSTALL_WORKFLOWS "$INSTALL_WORKFLOWS" "$PARAMS"
set_param INSTALL_SECURECODER "$INSTALL_SECURECODER" "$PARAMS"

# Local Hub
set_param HUB_URL "" "$PARAMS"
set_param HUB_ACCESS_KEY "" "$PARAMS"
set_param HUB_NS "$HUB_NS" "$PARAMS"
set_param STORAGE_CLASS_HUB "$BLOCK_STORAGE_CLASS" "$PARAMS"

# Concert
set_param CONCERT_NS "$CONCERT_NS" "$PARAMS"
set_param STORAGE_CLASS_CONCERT "$BLOCK_STORAGE_CLASS" "$PARAMS"
set_param ENABLE_BUDDY "$ENABLE_BUDDY" "$PARAMS"

if [[ -n "$FILE_STORAGE_CLASS" ]]; then
  set_param FILE_STORAGE_CLASS_CONCERT "$FILE_STORAGE_CLASS" "$PARAMS"
fi

# Data Apps
set_param DATAAPPS_NS "$DATAAPPS_NS" "$PARAMS"
set_param STORAGE_CLASS_DATAAPPS "$BLOCK_STORAGE_CLASS" "$PARAMS"

# Workflows
set_param WORKFLOWS_NS "$WORKFLOWS_NS" "$PARAMS"
set_param WORKFLOWS_INSTANCE_ADDRESS "$APPS_DOMAIN" "$PARAMS"
set_param WORKFLOWS_INSTALL_ALL_INTEGRATIONS "$WORKFLOWS_INSTALL_ALL_INTEGRATIONS" "$PARAMS"

# Secure Coder
set_param SECURECODER_NS "$SECURECODER_NS" "$PARAMS"
set_param SECURECODER_MEND_ENABLED FALSE "$PARAMS"

# Optional capabilities
set_param ENABLE_AI "$ENABLE_AI" "$PARAMS"
set_param ENABLE_CROSS_PRODUCT_INTEGRATION "$ENABLE_CROSS_PRODUCT_INTEGRATION" "$PARAMS"

echo
echo "---------------- Active installation parameters ----------------"
grep -vE '^[[:space:]]*(#|$)' "$PARAMS" | \
  grep -E '^(INSTALL_|REG_USER|IMAGE_REGISTRY_PREFIX|HUB_NS|CONCERT_NS|DATAAPPS_NS|WORKFLOWS_NS|SECURECODER_NS|STORAGE_CLASS_|FILE_STORAGE_CLASS_CONCERT|ENABLE_BUDDY|ENABLE_AI|ENABLE_CROSS_PRODUCT_INTEGRATION|WORKFLOWS_INSTANCE_ADDRESS|WORKFLOWS_INSTALL_ALL_INTEGRATIONS)='
echo "----------------------------------------------------------------"
echo

###############################################################################
# IBM registry connectivity
###############################################################################

log "Validating IBM entitled registry credentials..."

TOKEN_STATUS="$(
  curl -sS -o /dev/null -w '%{http_code}' \
    -u "cp:${IBM_ENTITLEMENT_KEY}" \
    https://cp.icr.io/v2/ || true
)"

if [[ "$TOKEN_STATUS" != "200" && "$TOKEN_STATUS" != "401" ]]; then
  warn "Registry endpoint returned HTTP ${TOKEN_STATUS}. Installer will perform the definitive registry validation."
fi

###############################################################################
# Install
###############################################################################

log "Starting IBM Concert installation."
log "Console output is also saved to ${LOG_FILE}"

set +e
"${INSTALL_DIR}/bin/setup" \
  --license_acceptance=y \
  --username="$CONCERT_ADMIN_USER" \
  --password="$CONCERT_ADMIN_PASSWORD" \
  --registry_password="$IBM_ENTITLEMENT_KEY" \
  2>&1 | tee "$LOG_FILE"

SETUP_RC=${PIPESTATUS[0]}
set -e

if [[ "$SETUP_RC" -ne 0 ]]; then
  echo
  warn "IBM Concert setup returned exit code ${SETUP_RC}."
  warn "Review: ${LOG_FILE}"
  warn "Also review installer logs under ${INSTALL_DIR}/localstorage/logs/"
  exit "$SETUP_RC"
fi

ok "IBM Concert installer completed successfully."

###############################################################################
# Create Concert OpenShift route
###############################################################################

CONCERT_ROUTE_SCRIPT="${INSTALL_DIR}/ibm-concert-k8s/ocp-route.sh"

if [[ -x "$CONCERT_ROUTE_SCRIPT" ]]; then
  if ! oc get route concert -n "$CONCERT_NS" >/dev/null 2>&1; then
    log "Creating IBM Concert OpenShift route..."
    "$CONCERT_ROUTE_SCRIPT" "$CONCERT_NS"
  else
    log "Concert route already exists."
  fi
else
  warn "Concert route helper not found: ${CONCERT_ROUTE_SCRIPT}"
fi

###############################################################################
# Create Platform Hub OpenShift route
###############################################################################

HUB_ROUTE_SCRIPT="${INSTALL_DIR}/concert-hub/bin/ocp-route.sh"

if [[ -x "$HUB_ROUTE_SCRIPT" ]]; then
  if ! oc get route solis-hub -n "$HUB_NS" >/dev/null 2>&1; then
    log "Creating Platform Hub OpenShift route..."
    "$HUB_ROUTE_SCRIPT" "$HUB_NS"
  else
    log "Platform Hub route already exists."
  fi
else
  warn "Hub route helper not found: ${HUB_ROUTE_SCRIPT}"
fi

###############################################################################
# Resolve URLs
###############################################################################

CONCERT_HOST="$(oc get route concert -n "$CONCERT_NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
HUB_HOST="$(oc get route solis-hub -n "$HUB_NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)"

[[ -n "$CONCERT_HOST" ]] || die "Concert route host could not be determined."
[[ -n "$HUB_HOST" ]] || die "Hub route host could not be determined."

CONCERT_URL="https://${CONCERT_HOST}"
HUB_URL="https://${HUB_HOST}"
KC_URL="${HUB_URL}/sys/internal/kc"

log "Concert URL: ${CONCERT_URL}"
log "Platform Hub URL: ${HUB_URL}"
log "Keycloak URL: ${KC_URL}"

###############################################################################
# Validate Keycloak route
###############################################################################

KC_MASTER_STATUS="$(curl -ks -o /dev/null -w '%{http_code}' "${KC_URL}/realms/master" || true)"
[[ "$KC_MASTER_STATUS" == "200" ]] || \
  die "External Keycloak endpoint is not healthy. HTTP ${KC_MASTER_STATUS}: ${KC_URL}/realms/master"

ok "External Keycloak endpoint is reachable."

###############################################################################
# Initialize Keycloak/OIDC
###############################################################################

if bool_true "$CONFIGURE_SSO"; then
  SETUP_KEYCLOAK="${INSTALL_DIR}/concert-hub/bin/setup-keycloak.sh"
  [[ -x "$SETUP_KEYCLOAK" ]] || \
    die "Keycloak setup helper not found: ${SETUP_KEYCLOAK}"

  REALM_STATUS="$(curl -ks -o /dev/null -w '%{http_code}' "${KC_URL}/realms/${CONCERT_REALM}" || true)"

  if [[ "$REALM_STATUS" != "200" ]]; then
    log "Initializing Concert Keycloak realm/client and Hub OIDC..."

    "$SETUP_KEYCLOAK" \
      --kc-url="$KC_URL" \
      --namespace="$HUB_NS" \
      --product-url="$CONCERT_URL" \
      --username="$CONCERT_ADMIN_USER" \
      --password="$CONCERT_ADMIN_PASSWORD"

    ok "Concert Keycloak/OIDC initialization completed."
  else
    log "Realm '${CONCERT_REALM}' already exists; setup-keycloak initialization skipped."
  fi

 ##############################################################################
 # Ensure Hub OIDC configuration uses the external Keycloak route
 #
 # KEYCLOAK_URL must be the external OCP route so the Concert UI browser login
 # redirect resolves correctly.  The solis-core TLS trust issue (Let's Encrypt
 # not in the pod CA bundle) is fixed separately by appending the OCP ingress
 # chain to app-cfg-internal-tls — see Lab1b/fix-concert-auth.sh.
 ##############################################################################

  if oc get configmap app-cfg-cm -n "$HUB_NS" >/dev/null 2>&1; then
    CURRENT_KC_URL="$(
      oc get configmap app-cfg-cm -n "$HUB_NS" \
        -o jsonpath='{.data.KEYCLOAK_URL}' 2>/dev/null || true
    )"

    if [[ "$CURRENT_KC_URL" != "$KC_URL" ]]; then
      log "Updating Hub KEYCLOAK_URL to external OpenShift route..."
      oc patch configmap app-cfg-cm -n "$HUB_NS" \
        --type merge \
        -p "{\"data\":{\"KEYCLOAK_URL\":\"${KC_URL}\",\"REALM_NAME\":\"${CONCERT_REALM}\",\"SOLIS_AUTH\":\"oidc\"}}"
    else
      log "Hub KEYCLOAK_URL already correct — no change needed."
    fi
  fi

 ##############################################################################
 # Obtain Keycloak bootstrap admin token
 ##############################################################################

  KEYCLOAK_POD="$(
    oc get pods -n "$HUB_NS" \
      -o name | grep ibm-solis-embedded-keycloak | head -1 | cut -d/ -f2
  )"

  [[ -n "$KEYCLOAK_POD" ]] || die "Embedded Keycloak pod was not found."

  KC_ADMIN_USER="$(
    oc exec -n "$HUB_NS" "$KEYCLOAK_POD" -- \
      sh -c 'printf "%s" "$KC_BOOTSTRAP_ADMIN_USERNAME"'
  )"

  KC_ADMIN_PASS="$(
    oc exec -n "$HUB_NS" "$KEYCLOAK_POD" -- \
      sh -c 'printf "%s" "$KC_BOOTSTRAP_ADMIN_PASSWORD"'
  )"

  TOKEN_RESPONSE="$(
    curl -ks \
      -X POST \
      "${KC_URL}/realms/master/protocol/openid-connect/token" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "client_id=admin-cli" \
      --data-urlencode "username=${KC_ADMIN_USER}" \
      --data-urlencode "password=${KC_ADMIN_PASS}" \
      --data-urlencode 'grant_type=password'
  )"

  KC_TOKEN="$(printf '%s' "$TOKEN_RESPONSE" | jq -r '.access_token // empty')"
  [[ -n "$KC_TOKEN" ]] || die "Could not obtain Keycloak admin token."

 ##############################################################################
 # Locate concert-client
 ##############################################################################

  CLIENT_UUID="$(
    curl -ks \
      "${KC_URL}/admin/realms/${CONCERT_REALM}/clients?clientId=${CONCERT_CLIENT_ID}" \
      -H "Authorization: Bearer ${KC_TOKEN}" |
      jq -r '.[0].id // empty'
  )"

  [[ -n "$CLIENT_UUID" ]] || die "Keycloak client '${CONCERT_CLIENT_ID}' was not found."

 ##############################################################################
 # Add externally valid Concert callback
 ##############################################################################

  REQUIRED_REDIRECT="${CONCERT_URL}/platform_hub/*"

  CURRENT_CLIENT="$(
    curl -ks \
      "${KC_URL}/admin/realms/${CONCERT_REALM}/clients/${CLIENT_UUID}" \
      -H "Authorization: Bearer ${KC_TOKEN}"
  )"

  if ! printf '%s' "$CURRENT_CLIENT" | \
      jq -e --arg uri "$REQUIRED_REDIRECT" '.redirectUris[]? | select(. == $uri)' \
      >/dev/null; then

    log "Adding Keycloak redirect URI: ${REQUIRED_REDIRECT}"

    UPDATED_CLIENT="$(
      printf '%s' "$CURRENT_CLIENT" |
      jq --arg uri "$REQUIRED_REDIRECT" '
        .redirectUris = ((.redirectUris // []) + [$uri] | unique)
      '
    )"

    UPDATE_CODE="$(
      curl -ks \
        -o /tmp/concert-client-update.out \
        -w '%{http_code}' \
        -X PUT \
        "${KC_URL}/admin/realms/${CONCERT_REALM}/clients/${CLIENT_UUID}" \
        -H "Authorization: Bearer ${KC_TOKEN}" \
        -H 'Content-Type: application/json' \
        -d "$UPDATED_CLIENT"
    )"

    [[ "$UPDATE_CODE" == "204" ]] || \
      die "Failed to update Keycloak redirect URI. HTTP ${UPDATE_CODE}"
  else
    log "Required Keycloak redirect URI already exists."
  fi

  unset KC_ADMIN_PASS KC_TOKEN TOKEN_RESPONSE IBM_ENTITLEMENT_KEY

 ##############################################################################
 # Restart authentication-facing components
 ##############################################################################

  log "Restarting Hub authentication-facing deployments..."
  for dep in ibm-solis-core ibm-solis-hub-gw ibm-solis-ui; do
    if oc get deployment "$dep" -n "$HUB_NS" >/dev/null 2>&1; then
      oc rollout restart "deployment/${dep}" -n "$HUB_NS"
    fi
  done

  log "Restarting Concert gateway/UI deployments..."
  for dep in concert-solis-gw roja-portal-gw roja-ui; do
    if oc get deployment "$dep" -n "$CONCERT_NS" >/dev/null 2>&1; then
      oc rollout restart "deployment/${dep}" -n "$CONCERT_NS"
    fi
  done

  wait_deployment_if_present "$HUB_NS" ibm-solis-core
  wait_deployment_if_present "$HUB_NS" ibm-solis-hub-gw
  wait_deployment_if_present "$HUB_NS" ibm-solis-ui
  wait_deployment_if_present "$CONCERT_NS" concert-solis-gw
  wait_deployment_if_present "$CONCERT_NS" roja-portal-gw
  wait_deployment_if_present "$CONCERT_NS" roja-ui
fi

###############################################################################
# Final validation
###############################################################################

echo
echo "================================================================"
echo " Final IBM Concert Validation"
echo "================================================================"

for ns in "$HUB_NS" "$CONCERT_NS"; do
  echo
  echo "Namespace: $ns"
  oc get pods -n "$ns"
done

if bool_true "$INSTALL_DATAAPPS"; then
  echo
  echo "Namespace: $DATAAPPS_NS"
  oc get pods -n "$DATAAPPS_NS"
fi

if bool_true "$INSTALL_WORKFLOWS"; then
  echo
  echo "Namespace: $WORKFLOWS_NS"
  oc get pods -n "$WORKFLOWS_NS"
fi

echo
echo "Routes:"
oc get route -n "$HUB_NS" 2>/dev/null || true
oc get route -n "$CONCERT_NS" 2>/dev/null || true
if bool_true "$INSTALL_WORKFLOWS"; then
  oc get route -n "$WORKFLOWS_NS" 2>/dev/null || true
fi

echo
echo "PersistentVolumeClaims:"
oc get pvc -n "$HUB_NS" 2>/dev/null || true
oc get pvc -n "$CONCERT_NS" 2>/dev/null || true
if bool_true "$INSTALL_DATAAPPS"; then
  oc get pvc -n "$DATAAPPS_NS" 2>/dev/null || true
fi
if bool_true "$INSTALL_WORKFLOWS"; then
  oc get pvc -n "$WORKFLOWS_NS" 2>/dev/null || true
fi

if bool_true "$CONFIGURE_SSO"; then
  OIDC_ISSUER="$(
    curl -ks \
      "${KC_URL}/realms/${CONCERT_REALM}/.well-known/openid-configuration" |
      jq -r '.issuer // empty'
  )"

  [[ -n "$OIDC_ISSUER" ]] || die "OIDC discovery validation failed."
  ok "OIDC issuer: ${OIDC_ISSUER}"
fi

echo
echo "================================================================"
echo " IBM Concert installation completed"
echo "================================================================"
echo "Concert URL : ${CONCERT_URL}"
echo "Hub URL     : ${HUB_URL}"
if bool_true "$INSTALL_WORKFLOWS"; then
  WORKFLOWS_HOST="$(oc get route solis-gw -n "$WORKFLOWS_NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -z "$WORKFLOWS_HOST" ]] || echo "Workflows URL: https://${WORKFLOWS_HOST}"
fi
echo "Install log : ${LOG_FILE}"
echo
echo "Initial Concert admin user: ${CONCERT_ADMIN_USER}"
echo "Password was not written to the log by this script."
echo
echo "Security follow-up:"
echo "  - Change the initial Concert admin password if it is temporary."
echo "  - Replace the Keycloak bootstrap administrator with a permanent admin."
echo "  - Do not expose IBM entitlement keys or Keycloak client secrets."
echo "================================================================"
