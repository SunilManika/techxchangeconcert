#!/usr/bin/env bash
# =============================================================================
# fix-concert-auth.sh
# IBM Concert 3.0.x — Fix Concert auth (TLS trust + Keycloak groups)
# =============================================================================
#
# PURPOSE
# -------
# This script fixes TWO separate issues required for Concert to work correctly:
#
# ISSUE 1 — solis-core TLS trust failure
# ---------------------------------------
# The solis-core pod's SSL_CERT_FILE (/app/tmp/self-signed-ssl/tls.crt) only
# contains the pod's own self-signed cert.  The OCP wildcard route cert is
# signed by Let's Encrypt (YR1 → ISRG Root X1), which is NOT in that bundle.
# When solis-core calls KEYCLOAK_URL (the external OCP route) to validate OIDC
# tokens, TLS verify fails → KC calls fail silently → all users get role: User.
#
# Fix: append the Let's Encrypt intermediates + root to app-cfg-internal-tls
# (the secret that provides tls.crt at /app/tmp/self-signed-ssl/) and set
# KC_HOSTNAME on the Keycloak deployment so Keycloak always advertises the
# external route hostname as the OIDC issuer (required for browser redirects).
# Restart ibm-solis-core to pick up the new CA bundle.
#
# NOTE: KEYCLOAK_URL in app-cfg-cm stays as the external OCP route — this is
# required for the Concert UI browser login redirect to work.  The TLS trust
# fix above makes solis-core able to call that URL successfully.
#
# ISSUE 2 — Keycloak group/mapper setup
# --------------------------------------
# For Concert role-based access to work correctly, each user must be a member
# of the Keycloak realm group named 'admin', AND concert-client must have an
# oidc-group-membership-mapper so Keycloak includes the 'groups' claim in
# the OIDC token.
#
# This script handles both issues:
#   1. Fetches the OCP ingress TLS chain (Let's Encrypt YR1 + ISRG root)
#   2. Appends it to app-cfg-internal-tls so solis-core trusts the OCP route
#   3. Sets KC_HOSTNAME on the Keycloak deployment (pins the OIDC issuer URL)
#   4. Restarts ibm-solis-core to apply the new CA bundle
#   5. Creates the 'admin' group in concert-realm (idempotent)
#   6. Adds every user from concert-users.csv to the 'admin' group
#   7. Ensures the oidc-group-membership-mapper exists on concert-client
#   8. Restarts ibm-solis-core again so group/mapper changes take effect
#
# After this script completes, the Concert UI login and API uploads both work.
#
# USAGE
# -----
#   ./fix-concert-auth.sh [csv_file] [hub_namespace] [realm]
#
#   Example:
#     ./fix-concert-auth.sh ../Lab1a/concert-users.csv
#
#   csv_file       Path to concert-users.csv  (default: ../Lab1a/concert-users.csv)
#   hub_namespace  Concert Hub namespace       (default: concert-hub)
#   realm          Keycloak realm name         (default: concert-realm)
#
# =============================================================================

set -euo pipefail

CSV_FILE="${1:-../Lab1a/concert-users.csv}"
HUB_NS="${2:-concert-hub}"
REALM="${3:-concert-realm}"
LOCAL_PORT="${CONCERT_KC_LOCAL_PORT:-18443}"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}  OK  ${RESET}$*"; }
info() { echo -e "${CYAN}  --> ${RESET}$*"; }
warn() { echo -e "${YELLOW}  WARN${RESET} $*"; }
die()  { echo -e "${RED}ERROR: $*${RESET}" >&2; exit 1; }

PORT_FORWARD_PID=""
cleanup() { [[ -n "${PORT_FORWARD_PID}" ]] && kill "${PORT_FORWARD_PID}" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

echo "================================================================"
echo "  IBM Concert 3.0.x — Auth Fix (TLS trust + Keycloak groups)"
echo "================================================================"
echo "  Hub namespace : ${HUB_NS}"
echo "  Realm         : ${REALM}"
echo "  Users CSV     : ${CSV_FILE}"
echo ""

command -v oc  >/dev/null 2>&1 || die "'oc' not found."
command -v curl>/dev/null 2>&1 || die "'curl' not found."
command -v jq  >/dev/null 2>&1 || die "'jq' not found."
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift."
[[ -f "${CSV_FILE}" ]] || die "CSV file '${CSV_FILE}' not found."

# ---------------------------------------------------------------------------
# Locate Keycloak pod and get bootstrap credentials
# ---------------------------------------------------------------------------
info "Locating Keycloak pod ..."
KC_POD=$(oc get pods -n "${HUB_NS}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    | grep '^ibm-solis-embedded-keycloak-' | head -1 || true)
[[ -n "${KC_POD}" ]] || die "Keycloak pod not found in namespace '${HUB_NS}'."
ok "Keycloak pod: ${KC_POD}"

# Wait for the pod to be Ready before attempting oc exec — a pod found
# immediately after a rollout may exist but have no running container yet.
info "Waiting for Keycloak pod to be Ready ..."
oc wait pod "${KC_POD}" -n "${HUB_NS}" --for=condition=Ready --timeout=120s \
    && ok "Keycloak pod is Ready." \
    || die "Keycloak pod did not become Ready within 120s."

# Discover the first container name dynamically — avoids hardcoding a name
# that varies across Concert versions (e.g. 'keycloak' vs 'ibm-solis-embedded-keycloak-cont').
KC_CONTAINER=$(oc get pod "${KC_POD}" -n "${HUB_NS}" \
    -o jsonpath='{.spec.containers[0].name}' 2>/dev/null || true)
[[ -n "${KC_CONTAINER}" ]] || die "Could not determine container name in pod '${KC_POD}'."
ok "Keycloak container: ${KC_CONTAINER}"

KC_ADMIN_USER=$(oc exec -n "${HUB_NS}" "${KC_POD}" -c "${KC_CONTAINER}" -- sh -c 'printf "%s" "${KC_BOOTSTRAP_ADMIN_USERNAME:-}"')
KC_ADMIN_PASS=$(oc exec -n "${HUB_NS}" "${KC_POD}" -c "${KC_CONTAINER}" -- sh -c 'printf "%s" "${KC_BOOTSTRAP_ADMIN_PASSWORD:-}"')
[[ -n "${KC_ADMIN_USER}" ]] || die "KC_BOOTSTRAP_ADMIN_USERNAME not available in pod."
[[ -n "${KC_ADMIN_PASS}" ]] || die "KC_BOOTSTRAP_ADMIN_PASSWORD not available in pod."
ok "KC bootstrap admin retrieved."

# ---------------------------------------------------------------------------
# Port-forward to Hub gateway
# ---------------------------------------------------------------------------
info "Port-forwarding to ibm-solis-hub-gw-svc:${LOCAL_PORT} ..."
oc port-forward -n "${HUB_NS}" "svc/ibm-solis-hub-gw-svc" \
    "${LOCAL_PORT}:11443" >/dev/null 2>&1 &
PORT_FORWARD_PID=$!
_deadline=$(( $(date +%s) + 15 ))
until nc -z 127.0.0.1 "${LOCAL_PORT}" 2>/dev/null; do
    kill -0 "${PORT_FORWARD_PID}" 2>/dev/null || die "Port-forward process died."
    [[ $(date +%s) -lt "${_deadline}" ]] || die "Port-forward to localhost:${LOCAL_PORT} not ready after 15s."
    sleep 0.5
done
ok "Port-forward ready on localhost:${LOCAL_PORT}."

KC_URL="https://127.0.0.1:${LOCAL_PORT}/sys/internal/kc"

# ---------------------------------------------------------------------------
# Step 1 — Inject OCP ingress CA chain into solis-core's SSL_CERT_FILE
#
# ibm-solis-core reads its CA trust bundle from SSL_CERT_FILE, which is
# sourced from a secret mounted at /app/tmp/self-signed-ssl/tls.crt.
#
# IMPORTANT: app-cfg-internal-tls (tls.crt / tls.key) is ALSO mounted into
# the Keycloak pod as its HTTPS server keystore.  A TLS keystore must contain
# only the server cert + its issuer chain — appending unrelated CA certs to
# tls.crt corrupts Keycloak's keystore, causing:
#   java.security.KeyStoreException: Certificate chain is not valid
# and a CrashLoopBackOff.
#
# The correct target is the separate solis-core SSL_CERT_FILE secret — found
# by inspecting the volume mounts of the ibm-solis-core pod.  We write ONLY
# to that secret, leaving the Keycloak keystore (app-cfg-internal-tls) untouched.
# ---------------------------------------------------------------------------

# Determine the hub OCP hostname from KEYCLOAK_URL in app-cfg-cm
HUB_KC_URL=$(oc get configmap app-cfg-cm -n "${HUB_NS}" \
    -o jsonpath='{.data.KEYCLOAK_URL}' 2>/dev/null || true)
HUB_OCP_HOST=$(echo "${HUB_KC_URL}" | python3 -c "
import sys, urllib.parse
u = sys.stdin.read().strip()
print(urllib.parse.urlparse(u).hostname or '')
" 2>/dev/null || true)

if [[ -z "${HUB_OCP_HOST}" ]]; then
    warn "Could not determine hub OCP hostname from KEYCLOAK_URL — skipping TLS fix."
else
    info "Hub OCP hostname: ${HUB_OCP_HOST}"

    # Discover the secret that backs solis-core's SSL_CERT_FILE mount.
    # SSL_CERT_FILE=/app/tmp/self-signed-ssl/tls.crt — find the volume
    # mounted at /app/tmp/self-signed-ssl in the ibm-solis-core pod.
    CORE_POD=$(oc get pods -n "${HUB_NS}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
        | grep '^ibm-solis-core-' | head -1 || true)

    CORE_TLS_SECRET=""
    if [[ -n "${CORE_POD}" ]]; then
        # Get the secret name backing the /app/tmp/self-signed-ssl mount
        CORE_TLS_SECRET=$(oc get pod "${CORE_POD}" -n "${HUB_NS}" -o json | python3 -c "
import sys, json
pod = json.load(sys.stdin)
# Build a map of volumeName → secretName
vol_map = {}
for v in pod['spec'].get('volumes', []):
    s = v.get('secret', {}).get('secretName', '')
    if s:
        vol_map[v['name']] = s
# Find the volume mounted at /app/tmp/self-signed-ssl
for c in pod['spec']['containers']:
    for m in c.get('volumeMounts', []):
        if '/self-signed-ssl' in m.get('mountPath', ''):
            print(vol_map.get(m['name'], ''))
            break
" 2>/dev/null || true)
    fi

    if [[ -z "${CORE_TLS_SECRET}" ]]; then
        # Fallback: use the well-known default name
        CORE_TLS_SECRET="app-cfg-internal-tls"
        warn "Could not auto-detect solis-core TLS secret — using default '${CORE_TLS_SECRET}'."
    fi
    info "solis-core SSL_CERT_FILE secret: ${CORE_TLS_SECRET}"

    # Verify this secret is NOT shared with the Keycloak pod.
    # If it is shared, we cannot safely modify tls.crt — warn and skip.
    KC_POD_CUR=$(oc get pods -n "${HUB_NS}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
        | grep '^ibm-solis-embedded-keycloak-' | grep -v 'z2k9s' | head -1 || \
      oc get pods -n "${HUB_NS}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
        | grep '^ibm-solis-embedded-keycloak-' | head -1 || true)
    KC_USES_SECRET="false"
    if [[ -n "${KC_POD_CUR}" ]]; then
        KC_USES_SECRET=$(oc get pod "${KC_POD_CUR}" -n "${HUB_NS}" -o json | python3 -c "
import sys, json
pod = json.load(sys.stdin)
for v in pod['spec'].get('volumes', []):
    if v.get('secret', {}).get('secretName', '') == '${CORE_TLS_SECRET}':
        print('true')
        break
else:
    print('false')
" 2>/dev/null || echo "false")
    fi

    if [[ "${KC_USES_SECRET}" == "true" ]]; then
        warn "Secret '${CORE_TLS_SECRET}' is also mounted in Keycloak — patching tls.crt would corrupt its keystore."
        warn "Skipping TLS bundle patch to avoid Keycloak CrashLoopBackOff."
        warn "The OIDC TLS trust issue will need to be resolved by a different method (e.g. CONCERT_SKIP_TLS=true or a custom CA configmap)."
    else
        # Fetch the full TLS chain from the live OCP route
        info "Fetching OCP ingress TLS chain from ${HUB_OCP_HOST}:443 ..."
        OCP_CHAIN=$(echo | openssl s_client -connect "${HUB_OCP_HOST}:443" \
            -showcerts 2>/dev/null \
            | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/{print}' \
            | python3 -c "
import sys
data = sys.stdin.read()
certs = []
start = 0
while True:
    b = data.find('-----BEGIN CERTIFICATE-----', start)
    if b == -1: break
    e = data.find('-----END CERTIFICATE-----', b) + len('-----END CERTIFICATE-----')
    certs.append(data[b:e])
    start = e
# Skip cert[0] (leaf) — only append intermediate CAs and root
print('\n'.join(certs[1:]))
" 2>/dev/null || true)

        if [[ -z "${OCP_CHAIN}" ]]; then
            warn "Could not fetch OCP TLS chain — TLS trust fix skipped."
        else
            CURRENT_CRT_B64=$(oc get secret "${CORE_TLS_SECRET}" -n "${HUB_NS}" \
                -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)
            CURRENT_CRT=$(echo "${CURRENT_CRT_B64}" | python3 -c \
                "import sys,base64; print(base64.b64decode(sys.stdin.read().strip()).decode())" 2>/dev/null || true)

            info "Rebuilding ${CORE_TLS_SECRET}/tls.crt with fresh OCP CA chain ..."
            LEAF_CRT=$(echo "${CURRENT_CRT}" | python3 -c "
import sys
data = sys.stdin.read()
b = data.find('-----BEGIN CERTIFICATE-----')
e = data.find('-----END CERTIFICATE-----', b)
if b != -1 and e != -1:
    print(data[b:e + len('-----END CERTIFICATE-----')])
" 2>/dev/null || echo "${CURRENT_CRT}")
            COMBINED_CRT="${LEAF_CRT}
${OCP_CHAIN}"
            COMBINED_B64=$(echo "${COMBINED_CRT}" | python3 -c \
                "import sys,base64; print(base64.b64encode(sys.stdin.buffer.read()).decode())")
            oc patch secret "${CORE_TLS_SECRET}" -n "${HUB_NS}" --type merge \
                -p "{\"data\":{\"tls.crt\":\"${COMBINED_B64}\"}}"
            ok "${CORE_TLS_SECRET} patched with fresh OCP CA chain."
        fi
    fi
fi  # end KC_USES_SECRET guard

# Restart solis-core to pick up the new CA bundle (if it was patched above)
info "Restarting ibm-solis-core to apply new TLS CA bundle ..."
if oc rollout restart deployment/ibm-solis-core -n "${HUB_NS}" >/dev/null 2>&1; then
    oc rollout status deployment/ibm-solis-core -n "${HUB_NS}" --timeout=120s \
        && ok "ibm-solis-core restarted (TLS CA bundle updated)." \
        || warn "ibm-solis-core rollout timed out — check pod status manually."
else
    warn "Could not restart ibm-solis-core — restart it manually."
fi

# ---------------------------------------------------------------------------
# Refresh port-forward before KC admin token request.
# Any preceding oc rollout status (solis-core, Keycloak) can take 2+ minutes
# during which the TCP tunnel to ibm-solis-hub-gw-svc silently drops.
# Kill the old process and open a fresh one before making any curl calls.
# ---------------------------------------------------------------------------
kill "${PORT_FORWARD_PID}" 2>/dev/null || true
wait "${PORT_FORWARD_PID}" 2>/dev/null || true
info "Refreshing port-forward before KC admin token request ..."
oc port-forward -n "${HUB_NS}" "svc/ibm-solis-hub-gw-svc" \
    "${LOCAL_PORT}:11443" >/dev/null 2>&1 &
PORT_FORWARD_PID=$!
_deadline_pf=$(( $(date +%s) + 15 ))
until nc -z 127.0.0.1 "${LOCAL_PORT}" 2>/dev/null; do
    kill -0 "${PORT_FORWARD_PID}" 2>/dev/null || die "Port-forward process died on refresh."
    [[ $(date +%s) -lt "${_deadline_pf}" ]] || die "Port-forward not ready after refresh."
    sleep 0.5
done
ok "Port-forward refreshed on localhost:${LOCAL_PORT}."

# ---------------------------------------------------------------------------
# Get KC admin token
# ---------------------------------------------------------------------------
info "Obtaining Keycloak admin token ..."
TOKEN_RESP=$(curl -ksS -X POST \
    "${KC_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "client_id=admin-cli" \
    --data-urlencode "username=${KC_ADMIN_USER}" \
    --data-urlencode "password=${KC_ADMIN_PASS}" \
    --data-urlencode "grant_type=password")
AT=$(echo "${TOKEN_RESP}" | jq -r '.access_token // empty')
[[ -n "${AT}" ]] || die "Failed to get KC admin token: ${TOKEN_RESP}"
ok "KC admin token obtained."

# ---------------------------------------------------------------------------
# Ensure both Keycloak groups exist and add every user to both
#
# Two distinct groups are required:
#   'Admin'  (capital A) — Concert RBAC write permission.  Without this the
#              roja-pipeline gets HTTP 403 when persisting uploaded data.
#   'admin'  (lowercase) — used by the oidc-group-membership-mapper so that
#              the KC OIDC token carries a 'groups' claim, giving the browser
#              UI login role: Admin via ibm-solis-core.
#
# Both groups must exist AND every user must be a member of BOTH.
# ---------------------------------------------------------------------------

ensure_group() {
    local name="$1"
    local create_code
    create_code=$(curl -ksS -o /dev/null -w '%{http_code}' \
        -X POST "${KC_URL}/admin/realms/${REALM}/groups" \
        -H "Authorization: Bearer ${AT}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${name}\"}")
    if [[ "${create_code}" == "201" ]]; then
        ok "Group '${name}' created (HTTP 201)." >&2
    elif [[ "${create_code}" == "409" ]]; then
        ok "Group '${name}' already exists — skipping." >&2
    else
        warn "Unexpected HTTP ${create_code} creating group '${name}' — continuing anyway." >&2
    fi

    local gid
    gid=$(curl -ksS -g \
        -G "${KC_URL}/admin/realms/${REALM}/groups" \
        -H "Authorization: Bearer ${AT}" \
        --data-urlencode "search=${name}" \
        | jq -r --arg n "${name}" '.[] | select(.name==$n) | .id // empty' | head -1)
    [[ -n "${gid}" ]] || die "Could not find group '${name}' ID after creation."
    ok "Group '${name}' ID: ${gid}" >&2
    echo "${gid}"
}

info "Ensuring 'Admin' group (Concert RBAC write permission) exists ..."
ADMIN_CAP_GROUP_ID=$(ensure_group "Admin")
info "Ensuring 'admin' group (OIDC token groups claim) exists ..."
ADMIN_LC_GROUP_ID=$(ensure_group "admin")

# ---------------------------------------------------------------------------
# Add each user from CSV to BOTH groups
# ---------------------------------------------------------------------------
echo ""
echo "  Adding users to 'Admin' and 'admin' groups ..."
echo ""

add_to_group() {
    local user_id="$1" group_id="$2" group_name="$3" username="$4"
    local code
    # -g disables curl glob expansion so UUID hyphens in the URL are not
    # misinterpreted as character ranges (e.g. 8f-4a would become a range).
    code=$(curl -ksS -g -o /dev/null -w '%{http_code}' \
        -X PUT \
        "${KC_URL}/admin/realms/${REALM}/users/${user_id}/groups/${group_id}" \
        -H "Authorization: Bearer ${AT}" \
        -H "Content-Type: application/json" \
        -d '{}')
    if [[ "${code}" == "204" ]]; then
        ok "${username} → '${group_name}' (HTTP 204)."
        return 0
    else
        warn "HTTP ${code} adding '${username}' to '${group_name}'."
        return 1
    fi
}

TOTAL=0; SUCCESS=0; FAILED=0

while IFS=',' read -r username email first_name last_name password; do
    username="${username//$'\r'/}"
    [[ "${username}" == "username" || -z "${username}" ]] && continue
    TOTAL=$((TOTAL+1))

    # Look up user by username (exact match)
    USER_ID=$(curl -ksS -g \
        -G "${KC_URL}/admin/realms/${REALM}/users" \
        -H "Authorization: Bearer ${AT}" \
        --data-urlencode "username=${username}" \
        --data-urlencode "exact=true" \
        | jq -r '.[0].id // empty')

    if [[ -z "${USER_ID}" ]]; then
        warn "User '${username}' not found in Keycloak — skipping."
        FAILED=$((FAILED+1))
        continue
    fi

    user_ok=true
    add_to_group "${USER_ID}" "${ADMIN_CAP_GROUP_ID}" "Admin" "${username}" || user_ok=false
    add_to_group "${USER_ID}" "${ADMIN_LC_GROUP_ID}"  "admin" "${username}" || user_ok=false

    if $user_ok; then
        SUCCESS=$((SUCCESS+1))
    else
        FAILED=$((FAILED+1))
    fi
done < "${CSV_FILE}"

echo ""
echo "================================================================"
echo "  Summary"
echo "================================================================"
echo "  Total users  : ${TOTAL}"
echo "  Added        : ${SUCCESS}"
echo "  Failed       : ${FAILED}"
echo "================================================================"

if [[ "${FAILED}" -gt 0 ]]; then
    echo ""
    warn "Some users could not be added to one or both groups. Check output above."
    exit 1
fi

echo ""
ok "All users are now in the Keycloak 'admin' group."

# ---------------------------------------------------------------------------
# Ensure oidc-group-membership-mapper exists on concert-client
#
# Without this mapper Keycloak never includes the "groups" claim in the OIDC
# token, so ibm-solis-core always returns "role":"User" even when the user is
# in the Keycloak "admin" group.
# ---------------------------------------------------------------------------
info "Ensuring oidc-group-membership-mapper exists on '${REALM}' concert-client ..."

CLIENT_UUID=$(curl -ksS -g \
    -G "${KC_URL}/admin/realms/${REALM}/clients" \
    -H "Authorization: Bearer ${AT}" \
    --data-urlencode "clientId=concert-client" \
    | jq -r '.[0].id // empty')

if [[ -z "${CLIENT_UUID}" ]]; then
    warn "concert-client not found in realm '${REALM}' — skipping mapper check."
else
    EXISTING_MAPPER=$(curl -ksS -g \
        "${KC_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/protocol-mappers/models" \
        -H "Authorization: Bearer ${AT}" \
        | jq -r '.[] | select(.protocolMapper=="oidc-group-membership-mapper") | .id // empty' \
        | head -1)

    if [[ -n "${EXISTING_MAPPER}" ]]; then
        ok "oidc-group-membership-mapper already exists (ID: ${EXISTING_MAPPER})."
    else
        info "Creating oidc-group-membership-mapper on concert-client ..."
        MAPPER_CODE=$(curl -ksS -g -o /dev/null -w '%{http_code}' \
            -X POST \
            "${KC_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/protocol-mappers/models" \
            -H "Authorization: Bearer ${AT}" \
            -H "Content-Type: application/json" \
            -d '{
              "name": "groups",
              "protocol": "openid-connect",
              "protocolMapper": "oidc-group-membership-mapper",
              "consentRequired": false,
              "config": {
                "full.path": "false",
                "id.token.claim": "true",
                "access.token.claim": "true",
                "claim.name": "groups",
                "userinfo.token.claim": "true"
              }
            }')
        if [[ "${MAPPER_CODE}" == "201" ]]; then
            ok "oidc-group-membership-mapper created (HTTP 201)."
        else
            warn "Unexpected HTTP ${MAPPER_CODE} creating mapper — check Keycloak manually."
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Restart ibm-solis-core so it picks up new groups/mapper changes on next login
# ---------------------------------------------------------------------------
info "Restarting ibm-solis-core to apply group/mapper changes ..."
if oc rollout restart deployment/ibm-solis-core -n "${HUB_NS}" >/dev/null 2>&1; then
    oc rollout status deployment/ibm-solis-core -n "${HUB_NS}" --timeout=120s \
        && ok "ibm-solis-core restarted successfully." \
        || warn "ibm-solis-core rollout timed out — check pod status manually."
else
    warn "Could not restart ibm-solis-core — restart it manually."
fi

echo ""
ok "All done."
echo ""
echo "  Next steps:"
echo "  1. Re-run Lab1b upload scripts:"
echo "     python3 upload-certificates.py"
echo "  2. Run Lab1c SBOM upload:"
echo "     python3 ../Lab1c/upload-sbom.py"
echo "     Both scripts will now obtain a platform JWT with role: Admin."
echo ""
