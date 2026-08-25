#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# IBM Concert 3.0.x on OpenShift - Post-install Authentication Automation
#
# Assumptions:
#   - IBM Concert 3.0.x is already installed.
#   - You are already authenticated to the target OpenShift cluster with oc login.
#   - jq, curl and oc are installed on the host running this script.
#
# What this script does:
#   1. Validates OpenShift access and required Concert namespaces/services.
#   2. Creates/reuses the IBM Solis Hub OpenShift route.
#   3. Verifies external Keycloak reachability.
#   4. Initializes concert-realm / concert-client with setup-keycloak.sh if needed.
#   5. Ensures Hub OIDC configuration uses the external Hub route.
#   6. Adds the Concert /platform_hub/* redirect URI to concert-client.
#   7. Restarts the required Hub and Concert components.
#   8. Optionally creates/updates users from a CSV and assigns the Admin client role.
#   9. Performs final verification.
#
# CSV format (optional):
#   username,email,first_name,last_name,password
#   user@example.com,user@example.com,First,Last,StrongPassword123!
###############################################################################

INSTALL_DIR="${INSTALL_DIR:-/opt/ibm-concert}"
HUB_NS="${HUB_NS:-concert-hub}"
CONCERT_NS="${CONCERT_NS:-concert}"
HUB_ROUTE_NAME="${HUB_ROUTE_NAME:-solis-hub}"
HUB_SERVICE="${HUB_SERVICE:-ibm-solis-hub-gw-svc}"
REALM="${CONCERT_REALM:-concert-realm}"
CLIENT_ID="${CONCERT_CLIENT_ID:-concert-client}"
CONCERT_ROLE="${CONCERT_ROLE:-Admin}"
USERS_CSV="${USERS_CSV:-concert-users.csv}"
CREATE_USERS="${CREATE_USERS:-true}"

ROUTE_SCRIPT="${INSTALL_DIR}/concert-hub/bin/ocp-route.sh"
SETUP_KEYCLOAK_SCRIPT="${INSTALL_DIR}/concert-hub/bin/setup-keycloak.sh"

TMP_DIR="$(mktemp -d /tmp/concert-postinstall.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

log()     { printf '[INFO] %s\n' "$*"; }
success() { printf '[SUCCESS] %s\n' "$*"; }
warn()    { printf '[WARN] %s\n' "$*" >&2; }
die()     { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' is not installed."
}

http_code() {
  curl -ksS -o /dev/null -w '%{http_code}' "$1"
}

###############################################################################
# 1. Prerequisite validation
###############################################################################

require_cmd oc
require_cmd curl
require_cmd jq

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift. Run 'oc login' first."

log "Connected OpenShift user: $(oc whoami)"
log "OpenShift API: $(oc whoami --show-server)"

oc get ns "$HUB_NS" >/dev/null 2>&1 || die "Namespace '$HUB_NS' does not exist."
oc get ns "$CONCERT_NS" >/dev/null 2>&1 || die "Namespace '$CONCERT_NS' does not exist."
oc get svc "$HUB_SERVICE" -n "$HUB_NS" >/dev/null 2>&1 || die "Service '$HUB_SERVICE' not found in '$HUB_NS'."

[[ -x "$ROUTE_SCRIPT" ]] || die "Route script not found/executable: $ROUTE_SCRIPT"
[[ -x "$SETUP_KEYCLOAK_SCRIPT" ]] || die "Keycloak setup script not found/executable: $SETUP_KEYCLOAK_SCRIPT"

CONCERT_HOST="$(oc get route concert -n "$CONCERT_NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
[[ -n "$CONCERT_HOST" ]] || die "Concert route 'concert' not found in namespace '$CONCERT_NS'."
CONCERT_URL="https://${CONCERT_HOST}"

log "Concert URL: $CONCERT_URL"

###############################################################################
# 2. Create/reuse the supported Solis Hub route
###############################################################################

if oc get route "$HUB_ROUTE_NAME" -n "$HUB_NS" >/dev/null 2>&1; then
  log "Hub route '$HUB_ROUTE_NAME' already exists; reusing it."
else
  log "Creating IBM Solis Hub route using $ROUTE_SCRIPT ..."
  "$ROUTE_SCRIPT" "$HUB_NS"
fi

HUB_HOST="$(oc get route "$HUB_ROUTE_NAME" -n "$HUB_NS" -o jsonpath='{.spec.host}')"
[[ -n "$HUB_HOST" ]] || die "Unable to determine Hub route host."

HUB_URL="https://${HUB_HOST}"
KC_URL="${HUB_URL}/sys/internal/kc"

log "Hub URL: $HUB_URL"
log "Keycloak URL: $KC_URL"

MASTER_CODE="$(http_code "${KC_URL}/realms/master")"
[[ "$MASTER_CODE" == "200" ]] || die "Keycloak master realm is not reachable through Hub route (HTTP $MASTER_CODE)."
success "External Keycloak endpoint is reachable."

###############################################################################
# 3. Locate embedded Keycloak and retrieve bootstrap credentials
###############################################################################

KEYCLOAK_POD="$(oc get pods -n "$HUB_NS" -o name | grep ibm-solis-embedded-keycloak | head -1 | cut -d/ -f2 || true)"
[[ -n "$KEYCLOAK_POD" ]] || die "Embedded Keycloak pod not found in '$HUB_NS'."

KC_ADMIN_USERNAME="$(oc exec -n "$HUB_NS" "$KEYCLOAK_POD" -- sh -c 'printf "%s" "${KC_BOOTSTRAP_ADMIN_USERNAME:-}"')"
KC_ADMIN_PASSWORD="$(oc exec -n "$HUB_NS" "$KEYCLOAK_POD" -- sh -c 'printf "%s" "${KC_BOOTSTRAP_ADMIN_PASSWORD:-}"')"

[[ -n "$KC_ADMIN_USERNAME" ]] || die "KC_BOOTSTRAP_ADMIN_USERNAME is unavailable."
[[ -n "$KC_ADMIN_PASSWORD" ]] || die "KC_BOOTSTRAP_ADMIN_PASSWORD is unavailable."

refresh_admin_token() {
  local response
  response="$(curl -ksS -X POST \
    "${KC_URL}/realms/master/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'client_id=admin-cli' \
    --data-urlencode "username=${KC_ADMIN_USERNAME}" \
    --data-urlencode "password=${KC_ADMIN_PASSWORD}" \
    --data-urlencode 'grant_type=password')"

  ACCESS_TOKEN="$(jq -r '.access_token // empty' <<<"$response")"
  [[ -n "$ACCESS_TOKEN" ]] || {
    jq . <<<"$response" >&2 || true
    die "Unable to obtain Keycloak admin token."
  }
}

refresh_admin_token
success "Authenticated to Keycloak Admin API."

###############################################################################
# 4. Initialize Concert realm/client if absent
###############################################################################

REALM_CODE="$(curl -ksS -o /dev/null -w '%{http_code}' \
  "${KC_URL}/admin/realms/${REALM}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}")"

if [[ "$REALM_CODE" == "200" ]]; then
  log "Realm '$REALM' already exists; skipping setup-keycloak initialization."
else
  log "Realm '$REALM' does not exist. Initializing Concert Keycloak authentication."

  PRODUCT_ADMIN_USERNAME="${PRODUCT_ADMIN_USERNAME:-admin}"
  if [[ -z "${PRODUCT_ADMIN_PASSWORD:-}" ]]; then
    read -r -s -p "Enter initial Concert platform admin password for '${PRODUCT_ADMIN_USERNAME}': " PRODUCT_ADMIN_PASSWORD
    echo
  fi

  [[ -n "$PRODUCT_ADMIN_PASSWORD" ]] || die "Product admin password cannot be empty."

  "$SETUP_KEYCLOAK_SCRIPT" \
    --kc-url="${KC_URL}" \
    --namespace="${HUB_NS}" \
    --product-url="${CONCERT_URL}" \
    --username="${PRODUCT_ADMIN_USERNAME}" \
    --password="${PRODUCT_ADMIN_PASSWORD}"

  refresh_admin_token

  REALM_CODE="$(curl -ksS -o /dev/null -w '%{http_code}' \
    "${KC_URL}/admin/realms/${REALM}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}")"
  [[ "$REALM_CODE" == "200" ]] || die "Realm '$REALM' was not created successfully."
  success "Realm '$REALM' initialized."
fi

###############################################################################
# 5. Ensure Hub OIDC config uses the external route
###############################################################################

log "Ensuring Hub OIDC configuration points to external Keycloak route ..."

oc patch configmap app-cfg-cm -n "$HUB_NS" --type merge -p "$(jq -nc \
  --arg kc "$KC_URL" \
  --arg realm "$REALM" \
  '{data:{KEYCLOAK_URL:$kc,REALM_NAME:$realm,SOLIS_AUTH:"oidc"}}')" >/dev/null

success "Hub OIDC configuration updated."

###############################################################################
# 6. Ensure Concert client configuration/redirect URI
###############################################################################

refresh_admin_token

CLIENT_UUID="$(curl -ksS -G \
  "${KC_URL}/admin/realms/${REALM}/clients" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  --data-urlencode "clientId=${CLIENT_ID}" | jq -r '.[0].id // empty')"

[[ -n "$CLIENT_UUID" ]] || die "Client '$CLIENT_ID' not found in realm '$REALM'."

log "Concert client UUID: $CLIENT_UUID"

ROLE_JSON="$(curl -ksS \
  "${KC_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/roles/${CONCERT_ROLE}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}")"
ROLE_ID="$(jq -r '.id // empty' <<<"$ROLE_JSON")"
ROLE_NAME="$(jq -r '.name // empty' <<<"$ROLE_JSON")"
[[ -n "$ROLE_ID" && -n "$ROLE_NAME" ]] || die "Client role '$CONCERT_ROLE' not found on '$CLIENT_ID'."

CURRENT_CLIENT="$(curl -ksS \
  "${KC_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}")"

FULL_REDIRECT_URI="${CONCERT_URL}/platform_hub/*"

UPDATED_CLIENT="$(jq \
  --arg root "$CONCERT_URL" \
  --arg redirect "$FULL_REDIRECT_URI" '
    .rootUrl = $root
    | .adminUrl = $root
    | .redirectUris = ((.redirectUris // []) + [$redirect] | unique)
  ' <<<"$CURRENT_CLIENT")"

UPDATE_CODE="$(curl -ksS \
  -o "$TMP_DIR/client-update.out" \
  -w '%{http_code}' \
  -X PUT \
  "${KC_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "$UPDATED_CLIENT")"

[[ "$UPDATE_CODE" == "204" ]] || {
  cat "$TMP_DIR/client-update.out" >&2 || true
  die "Failed to update Concert client (HTTP $UPDATE_CODE)."
}

success "Concert client redirect URI ensured: $FULL_REDIRECT_URI"

###############################################################################
# 7. Restart required Hub and Concert deployments
###############################################################################

log "Restarting Hub authentication components ..."
for d in ibm-solis-core ibm-solis-hub-gw ibm-solis-ui; do
  if oc get deploy "$d" -n "$HUB_NS" >/dev/null 2>&1; then
    oc rollout restart deployment/"$d" -n "$HUB_NS" >/dev/null
  fi
done

log "Restarting Concert gateway/UI components ..."
for d in concert-solis-gw roja-portal-gw roja-ui; do
  if oc get deploy "$d" -n "$CONCERT_NS" >/dev/null 2>&1; then
    oc rollout restart deployment/"$d" -n "$CONCERT_NS" >/dev/null
  fi
done

for d in ibm-solis-core ibm-solis-hub-gw ibm-solis-ui; do
  if oc get deploy "$d" -n "$HUB_NS" >/dev/null 2>&1; then
    oc rollout status deployment/"$d" -n "$HUB_NS" --timeout=10m
  fi
done

for d in concert-solis-gw roja-portal-gw roja-ui; do
  if oc get deploy "$d" -n "$CONCERT_NS" >/dev/null 2>&1; then
    oc rollout status deployment/"$d" -n "$CONCERT_NS" --timeout=10m
  fi
done

success "Required deployments are ready."

###############################################################################
# 8. Optional bulk user provisioning
###############################################################################

create_or_update_users() {
  local csv="$1"
  local total=0 created=0 updated=0 failed=0

  [[ -f "$csv" ]] || {
    warn "User CSV '$csv' not found; skipping user provisioning."
    return 0
  }

  log "Provisioning users from $csv with Concert client role '$CONCERT_ROLE' ..."

  while IFS=',' read -r username email first_name last_name password || [[ -n "${username:-}" ]]; do
    username="${username//$'\r'/}"
    email="${email//$'\r'/}"
    first_name="${first_name//$'\r'/}"
    last_name="${last_name//$'\r'/}"
    password="${password//$'\r'/}"

    [[ "$username" == "username" ]] && continue
    [[ -z "$username" ]] && continue

    total=$((total + 1))
    refresh_admin_token

    USER_JSON="$(curl -ksS -G \
      "${KC_URL}/admin/realms/${REALM}/users" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      --data-urlencode "username=${username}" \
      --data-urlencode 'exact=true')"

    USER_ID="$(jq -r '.[0].id // empty' <<<"$USER_JSON")"

    USER_PAYLOAD="$(jq -nc \
      --arg username "$username" \
      --arg email "$email" \
      --arg first "$first_name" \
      --arg last "$last_name" \
      '{username:$username,email:$email,firstName:$first,lastName:$last,enabled:true,emailVerified:true}')"

    if [[ -z "$USER_ID" ]]; then
      CODE="$(curl -ksS -o "$TMP_DIR/user.out" -w '%{http_code}' -X POST \
        "${KC_URL}/admin/realms/${REALM}/users" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H 'Content-Type: application/json' \
        -d "$USER_PAYLOAD")"
      if [[ "$CODE" != "201" ]]; then
        warn "Failed to create '$username' (HTTP $CODE)."
        failed=$((failed + 1)); continue
      fi
      created=$((created + 1))

      USER_ID="$(curl -ksS -G \
        "${KC_URL}/admin/realms/${REALM}/users" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        --data-urlencode "username=${username}" \
        --data-urlencode 'exact=true' | jq -r '.[0].id // empty')"
    else
      CODE="$(curl -ksS -o "$TMP_DIR/user-update.out" -w '%{http_code}' -X PUT \
        "${KC_URL}/admin/realms/${REALM}/users/${USER_ID}" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H 'Content-Type: application/json' \
        -d "$USER_PAYLOAD")"
      if [[ "$CODE" != "204" ]]; then
        warn "Failed to update '$username' (HTTP $CODE)."
        failed=$((failed + 1)); continue
      fi
      updated=$((updated + 1))
    fi

    [[ -n "$USER_ID" ]] || { warn "Unable to determine user ID for '$username'."; failed=$((failed + 1)); continue; }

    PASSWORD_PAYLOAD="$(jq -nc --arg p "$password" '{type:"password",temporary:false,value:$p}')"
    CODE="$(curl -ksS -o "$TMP_DIR/password.out" -w '%{http_code}' -X PUT \
      "${KC_URL}/admin/realms/${REALM}/users/${USER_ID}/reset-password" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H 'Content-Type: application/json' \
      -d "$PASSWORD_PAYLOAD")"
    if [[ "$CODE" != "204" ]]; then
      warn "Failed to set password for '$username' (HTTP $CODE)."
      failed=$((failed + 1)); continue
    fi

    ROLE_PAYLOAD="$(jq -nc --arg id "$ROLE_ID" --arg name "$ROLE_NAME" --arg cid "$CLIENT_UUID" \
      '[{id:$id,name:$name,containerId:$cid,clientRole:true}]')"

    CODE="$(curl -ksS -o "$TMP_DIR/role.out" -w '%{http_code}' -X POST \
      "${KC_URL}/admin/realms/${REALM}/users/${USER_ID}/role-mappings/clients/${CLIENT_UUID}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H 'Content-Type: application/json' \
      -d "$ROLE_PAYLOAD")"
    if [[ "$CODE" != "204" ]]; then
      warn "Failed to assign role '$CONCERT_ROLE' to '$username' (HTTP $CODE)."
      failed=$((failed + 1)); continue
    fi

    success "Provisioned $username with role '$CONCERT_ROLE'."
  done < "$csv"

  log "User provisioning summary: total=$total created=$created updated=$updated failed=$failed"
  [[ "$failed" -eq 0 ]] || return 1
}

if [[ "${CREATE_USERS,,}" == "true" ]]; then
  create_or_update_users "$USERS_CSV"
else
  log "CREATE_USERS=$CREATE_USERS; skipping user provisioning."
fi

###############################################################################
# 9. Final verification
###############################################################################

log "Verifying OIDC discovery document ..."
OIDC_JSON="$(curl -ksS "${KC_URL}/realms/${REALM}/.well-known/openid-configuration")"
ISSUER="$(jq -r '.issuer // empty' <<<"$OIDC_JSON")"
AUTH_EP="$(jq -r '.authorization_endpoint // empty' <<<"$OIDC_JSON")"
TOKEN_EP="$(jq -r '.token_endpoint // empty' <<<"$OIDC_JSON")"

[[ "$ISSUER" == "${KC_URL}/realms/${REALM}" ]] || warn "Unexpected issuer: $ISSUER"

refresh_admin_token
FINAL_CLIENT="$(curl -ksS \
  "${KC_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}")"

printf '\n============================================================\n'
printf ' IBM Concert Post-install Authentication Summary\n'
printf '============================================================\n'
printf 'Concert URL       : %s\n' "$CONCERT_URL"
printf 'Hub URL           : %s\n' "$HUB_URL"
printf 'Keycloak URL      : %s\n' "$KC_URL"
printf 'Realm             : %s\n' "$REALM"
printf 'Client            : %s\n' "$CLIENT_ID"
printf 'Admin client role : %s\n' "$CONCERT_ROLE"
printf 'OIDC issuer       : %s\n' "$ISSUER"
printf 'Authorization EP  : %s\n' "$AUTH_EP"
printf 'Token EP          : %s\n' "$TOKEN_EP"
printf 'Redirect URIs:\n'
jq -r '.redirectUris[]? | "  - " + .' <<<"$FINAL_CLIENT"
printf '============================================================\n'

success "Concert authentication automation completed successfully."
printf '\nOpen Concert in a private browser window:\n%s\n' "$CONCERT_URL"
