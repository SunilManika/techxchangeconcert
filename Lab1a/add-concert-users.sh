#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# IBM Concert 3.0.x - Bulk User Provisioning
#
# Creates or updates users in the embedded Keycloak instance and assigns
# the Concert "Admin" client role.
#
# Usage:
#   ./add-concert-users.sh
#
# or:
#   ./add-concert-users.sh concert-users.csv
#
# CSV format:
#
# username,email,first_name,last_name,password
# sunga027@in.ibm.com,sunga027@in.ibm.com,Sunil,Gajula,Concert@2026!
#
###############################################################################

NAMESPACE="${CONCERT_HUB_NAMESPACE:-concert-hub}"
CSV_FILE="${1:-concert-users.csv}"

REALM="${CONCERT_REALM:-concert-realm}"
CLIENT_ID="${CONCERT_CLIENT_ID:-concert-client}"
CONCERT_ROLE="${CONCERT_ROLE:-Admin}"

HUB_SERVICE="${CONCERT_HUB_SERVICE:-ibm-solis-hub-gw-svc}"
LOCAL_PORT="${CONCERT_KC_LOCAL_PORT:-18443}"

PORT_FORWARD_PID=""

###############################################################################
# Helper functions
###############################################################################

die() {
    echo "ERROR: $*" >&2
    exit 1
}

success() {
    echo "SUCCESS: $*"
}

cleanup() {
    if [[ -n "${PORT_FORWARD_PID}" ]]; then
        kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
        wait "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT INT TERM

###############################################################################
# Banner
###############################################################################

echo "============================================================"
echo " IBM Concert 3.0.x - Bulk User Creation"
echo "============================================================"
echo "Namespace : ${NAMESPACE}"
echo "CSV File  : ${CSV_FILE}"
echo "Realm     : ${REALM}"
echo "Client    : ${CLIENT_ID}"
echo "Role      : ${CONCERT_ROLE}"
echo

###############################################################################
# Validate prerequisites
###############################################################################

command -v oc >/dev/null 2>&1 || \
    die "oc CLI is not installed."

command -v curl >/dev/null 2>&1 || \
    die "curl is not installed."

command -v jq >/dev/null 2>&1 || \
    die "jq is not installed."

[[ -f "${CSV_FILE}" ]] || \
    die "CSV file '${CSV_FILE}' does not exist."

oc whoami >/dev/null 2>&1 || \
    die "Not logged in to OpenShift."

oc get namespace "${NAMESPACE}" >/dev/null 2>&1 || \
    die "Namespace '${NAMESPACE}' does not exist."

###############################################################################
# Locate Keycloak pod
###############################################################################

echo "Locating embedded Concert Keycloak..."

KEYCLOAK_POD=$(
    oc get pods \
      -n "${NAMESPACE}" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' |
    grep '^ibm-solis-embedded-keycloak-' |
    head -1 || true
)

[[ -n "${KEYCLOAK_POD}" ]] || \
    die "Embedded Keycloak pod not found."

echo "Keycloak pod : ${KEYCLOAK_POD}"

###############################################################################
# Retrieve bootstrap Keycloak admin credentials
###############################################################################

echo
echo "Retrieving Keycloak administrator credentials..."

KC_ADMIN_USERNAME=$(
    oc exec \
      -n "${NAMESPACE}" \
      "${KEYCLOAK_POD}" -- \
      sh -c 'printf "%s" "${KC_BOOTSTRAP_ADMIN_USERNAME:-}"'
)

KC_ADMIN_PASSWORD=$(
    oc exec \
      -n "${NAMESPACE}" \
      "${KEYCLOAK_POD}" -- \
      sh -c 'printf "%s" "${KC_BOOTSTRAP_ADMIN_PASSWORD:-}"'
)

if [[ -n "${KC_ADMIN_USERNAME_OVERRIDE:-}" ]]; then
    KC_ADMIN_USERNAME="${KC_ADMIN_USERNAME_OVERRIDE}"
fi

if [[ -n "${KC_ADMIN_PASSWORD_OVERRIDE:-}" ]]; then
    KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD_OVERRIDE}"
fi

[[ -n "${KC_ADMIN_USERNAME}" ]] || \
    die "Keycloak administrator username not available."

[[ -n "${KC_ADMIN_PASSWORD}" ]] || \
    die "Keycloak administrator password not available."

echo "Keycloak administrator credentials found."

###############################################################################
# Discover Hub gateway port
###############################################################################

echo
echo "Checking Concert Hub gateway..."

oc get svc \
    "${HUB_SERVICE}" \
    -n "${NAMESPACE}" \
    >/dev/null 2>&1 || \
    die "Hub gateway service '${HUB_SERVICE}' not found."

echo "Hub service : ${HUB_SERVICE}"

###############################################################################
# Start temporary port-forward
###############################################################################

echo
echo "Starting temporary port-forward..."

rm -f /tmp/concert-kc-port-forward.log

oc port-forward \
    -n "${NAMESPACE}" \
    "svc/${HUB_SERVICE}" \
    "${LOCAL_PORT}:11443" \
    >/tmp/concert-kc-port-forward.log 2>&1 &

PORT_FORWARD_PID=$!

_deadline=$(( $(date +%s) + 15 ))
until nc -z 127.0.0.1 "${LOCAL_PORT}" 2>/dev/null; do
    if ! kill -0 "${PORT_FORWARD_PID}" 2>/dev/null; then
        cat /tmp/concert-kc-port-forward.log
        die "Port-forward process died."
    fi
    [[ $(date +%s) -lt "${_deadline}" ]] || { cat /tmp/concert-kc-port-forward.log; die "Port-forward not ready after 15s."; }
    sleep 0.5
done

KEYCLOAK_URL="https://127.0.0.1:${LOCAL_PORT}/sys/internal/kc"

echo "Keycloak URL : ${KEYCLOAK_URL}"

###############################################################################
# Test Keycloak endpoint
###############################################################################

echo
echo "Testing Keycloak endpoint..."

HTTP_CODE=$(
    curl -k \
      -s \
      -o /dev/null \
      -w '%{http_code}' \
      "${KEYCLOAK_URL}/realms/master"
)

[[ "${HTTP_CODE}" == "200" ]] || \
    die "Keycloak endpoint returned HTTP ${HTTP_CODE}."

success "Keycloak endpoint is reachable."

###############################################################################
# Authenticate to Keycloak Admin REST API
###############################################################################

echo
echo "Authenticating to Keycloak Admin REST API..."

TOKEN_RESPONSE=$(
    curl -k \
      -sS \
      -X POST \
      "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-urlencode "client_id=admin-cli" \
      --data-urlencode "username=${KC_ADMIN_USERNAME}" \
      --data-urlencode "password=${KC_ADMIN_PASSWORD}" \
      --data-urlencode "grant_type=password"
)

ACCESS_TOKEN=$(
    echo "${TOKEN_RESPONSE}" |
    jq -r '.access_token // empty'
)

if [[ -z "${ACCESS_TOKEN}" ]]; then
    echo
    echo "Authentication response:"
    echo "${TOKEN_RESPONSE}" | jq .
    die "Unable to obtain Keycloak administrator token."
fi

success "Authenticated to Keycloak."

###############################################################################
# Validate Concert realm
###############################################################################

echo
echo "Validating Concert realm '${REALM}'..."

REALM_CODE=$(
    curl -k \
      -s \
      -o /dev/null \
      -w '%{http_code}' \
      "${KEYCLOAK_URL}/admin/realms/${REALM}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}"
)

[[ "${REALM_CODE}" == "200" ]] || \
    die "Realm '${REALM}' does not exist."

success "Realm '${REALM}' found."

###############################################################################
# Locate Concert client
###############################################################################

echo
echo "Locating Concert client '${CLIENT_ID}'..."

CLIENT_JSON=$(
    curl -k \
      -sS \
      -G \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/clients" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      --data-urlencode "clientId=${CLIENT_ID}"
)

CLIENT_UUID=$(
    echo "${CLIENT_JSON}" |
    jq -r '.[0].id // empty'
)

if [[ -z "${CLIENT_UUID}" ]]; then

    echo
    echo "Available clients:"

    curl -k \
      -sS \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/clients" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" |
      jq -r '.[].clientId'

    die "Concert client '${CLIENT_ID}' not found."
fi

echo "Concert client UUID : ${CLIENT_UUID}"

###############################################################################
# Locate Concert client role
###############################################################################

echo
echo "Checking Concert client role '${CONCERT_ROLE}'..."

ROLE_RESPONSE=$(
    curl -k \
      -sS \
      -w '\n%{http_code}' \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/roles/${CONCERT_ROLE}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}"
)

ROLE_HTTP_CODE=$(echo "${ROLE_RESPONSE}" | tail -1)
ROLE_BODY=$(echo "${ROLE_RESPONSE}" | sed '$d')

if [[ "${ROLE_HTTP_CODE}" != "200" ]]; then

    echo
    echo "Available Concert client roles:"

    curl -k \
      -sS \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/roles" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" |
      jq -r '.[].name'

    die "Concert client role '${CONCERT_ROLE}' does not exist."
fi

ROLE_ID=$(echo "${ROLE_BODY}" | jq -r '.id')
ROLE_NAME=$(echo "${ROLE_BODY}" | jq -r '.name')

success "Concert client role '${ROLE_NAME}' found."

###############################################################################
# Process CSV
###############################################################################

echo
echo "============================================================"
echo " Creating / Updating Concert Users"
echo "============================================================"

TOTAL=0
CREATED=0
UPDATED=0
FAILED=0

while IFS=',' read -r username email first_name last_name password
do

    ###########################################################################
    # Normalize CSV fields
    ###########################################################################

    username="${username//$'\r'/}"
    email="${email//$'\r'/}"
    first_name="${first_name//$'\r'/}"
    last_name="${last_name//$'\r'/}"
    password="${password//$'\r'/}"

    # Skip CSV header
    if [[ "${username}" == "username" ]]; then
        continue
    fi

    # Skip blank rows
    [[ -z "${username}" ]] && continue

    TOTAL=$((TOTAL + 1))

    echo
    echo "------------------------------------------------------------"
    echo "Processing user: ${username}"
    echo "------------------------------------------------------------"

    ###########################################################################
    # Find existing user
    ###########################################################################

    EXISTING_USER=$(
        curl -k \
          -sS \
          -G \
          "${KEYCLOAK_URL}/admin/realms/${REALM}/users" \
          -H "Authorization: Bearer ${ACCESS_TOKEN}" \
          --data-urlencode "username=${username}" \
          --data-urlencode "exact=true"
    )

    USER_ID=$(
        echo "${EXISTING_USER}" |
        jq -r '.[0].id // empty'
    )

    ###########################################################################
    # Create user
    ###########################################################################

    if [[ -z "${USER_ID}" ]]; then

        echo "Creating user..."

        USER_PAYLOAD=$(
            jq -n \
              --arg username "${username}" \
              --arg email "${email}" \
              --arg firstName "${first_name}" \
              --arg lastName "${last_name}" \
              '{
                  username: $username,
                  email: $email,
                  firstName: $firstName,
                  lastName: $lastName,
                  enabled: true,
                  emailVerified: true
              }'
        )

        CREATE_CODE=$(
            curl -k \
              -sS \
              -o /tmp/concert-create-user-response \
              -w '%{http_code}' \
              -X POST \
              "${KEYCLOAK_URL}/admin/realms/${REALM}/users" \
              -H "Authorization: Bearer ${ACCESS_TOKEN}" \
              -H "Content-Type: application/json" \
              -d "${USER_PAYLOAD}"
        )

        if [[ "${CREATE_CODE}" != "201" ]]; then

            echo "ERROR: Unable to create ${username}"
            cat /tmp/concert-create-user-response
            echo

            FAILED=$((FAILED + 1))
            continue
        fi

        CREATED=$((CREATED + 1))

        #######################################################################
        # Retrieve newly-created user ID
        #######################################################################

        EXISTING_USER=$(
            curl -k \
              -sS \
              -G \
              "${KEYCLOAK_URL}/admin/realms/${REALM}/users" \
              -H "Authorization: Bearer ${ACCESS_TOKEN}" \
              --data-urlencode "username=${username}" \
              --data-urlencode "exact=true"
        )

        USER_ID=$(
            echo "${EXISTING_USER}" |
            jq -r '.[0].id // empty'
        )

        if [[ -z "${USER_ID}" ]]; then
            echo "ERROR: User was created but ID could not be retrieved."
            FAILED=$((FAILED + 1))
            continue
        fi

        echo "User created."
        echo "User ID: ${USER_ID}"

    else

        #######################################################################
        # Update existing user
        #######################################################################

        echo "User already exists."
        echo "User ID: ${USER_ID}"
        echo "Updating profile..."

        UPDATE_PAYLOAD=$(
            jq -n \
              --arg username "${username}" \
              --arg email "${email}" \
              --arg firstName "${first_name}" \
              --arg lastName "${last_name}" \
              '{
                  username: $username,
                  email: $email,
                  firstName: $firstName,
                  lastName: $lastName,
                  enabled: true,
                  emailVerified: true
              }'
        )

        UPDATE_CODE=$(
            curl -k \
              -sS \
              -o /tmp/concert-update-user-response \
              -w '%{http_code}' \
              -X PUT \
              "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${USER_ID}" \
              -H "Authorization: Bearer ${ACCESS_TOKEN}" \
              -H "Content-Type: application/json" \
              -d "${UPDATE_PAYLOAD}"
        )

        if [[ "${UPDATE_CODE}" != "204" ]]; then
            echo "ERROR: Unable to update ${username}"
            FAILED=$((FAILED + 1))
            continue
        fi

        UPDATED=$((UPDATED + 1))
    fi

    ###########################################################################
    # Set permanent password
    ###########################################################################

    echo "Setting permanent password..."

    PASSWORD_PAYLOAD=$(
        jq -n \
          --arg password "${password}" \
          '{
              type: "password",
              temporary: false,
              value: $password
          }'
    )

    PASSWORD_CODE=$(
        curl -k \
          -sS \
          -o /tmp/concert-password-response \
          -w '%{http_code}' \
          -X PUT \
          "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${USER_ID}/reset-password" \
          -H "Authorization: Bearer ${ACCESS_TOKEN}" \
          -H "Content-Type: application/json" \
          -d "${PASSWORD_PAYLOAD}"
    )

    if [[ "${PASSWORD_CODE}" != "204" ]]; then

        echo "ERROR: Failed to set password for ${username}"

        FAILED=$((FAILED + 1))
        continue
    fi

    ###########################################################################
    # Assign Concert client role
    ###########################################################################

    echo "Assigning Concert role '${CONCERT_ROLE}'..."

    ROLE_MAPPING_PAYLOAD=$(
        jq -n \
          --arg id "${ROLE_ID}" \
          --arg name "${ROLE_NAME}" \
          --arg containerId "${CLIENT_UUID}" \
          '[
              {
                  id: $id,
                  name: $name,
                  containerId: $containerId,
                  clientRole: true
              }
          ]'
    )

    ROLE_CODE=$(
        curl -k \
          -sS \
          -o /tmp/concert-role-response \
          -w '%{http_code}' \
          -X POST \
          "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${USER_ID}/role-mappings/clients/${CLIENT_UUID}" \
          -H "Authorization: Bearer ${ACCESS_TOKEN}" \
          -H "Content-Type: application/json" \
          -d "${ROLE_MAPPING_PAYLOAD}"
    )

    if [[ "${ROLE_CODE}" != "204" ]]; then

        echo "ERROR: Failed to assign '${CONCERT_ROLE}' to ${username}"

        cat /tmp/concert-role-response
        echo

        FAILED=$((FAILED + 1))
        continue
    fi

    ###########################################################################
    # Ensure 'admin' Keycloak group exists and add user to it
    #
    # ibm-solis-core maps group membership → platform JWT role via the file
    # /mnt/infra/auth/roles which contains:
    #   Admin: admin
    # So every Concert Admin user must be in the Keycloak group named 'admin'.
    ###########################################################################

    echo "Ensuring 'admin' group exists and adding user..."

    # Create the group if it doesn't exist (409 = already exists, both are fine)
    curl -k -sS -o /dev/null \
        -X POST \
        "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"name":"admin"}' || true

    # Get the group ID
    ADMIN_GROUP_ID=$(
        curl -k -sS \
            -G "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            --data-urlencode "search=admin" \
            | jq -r '.[] | select(.name=="admin") | .id // empty' | head -1
    )

    if [[ -z "${ADMIN_GROUP_ID}" ]]; then
        echo "WARN: Could not find 'admin' group — skipping group assignment for ${username}"
    else
        GROUP_CODE=$(
            curl -k -sS \
                -o /dev/null \
                -w '%{http_code}' \
                -X PUT \
                "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${USER_ID}/groups/${ADMIN_GROUP_ID}" \
                -H "Authorization: Bearer ${ACCESS_TOKEN}" \
                -H "Content-Type: application/json" \
                -d '{}'
        )
        if [[ "${GROUP_CODE}" == "204" ]]; then
            echo "Added ${username} to 'admin' group."
        else
            echo "WARN: Could not add ${username} to 'admin' group (HTTP ${GROUP_CODE})."
        fi
    fi

    ###########################################################################
    # Verify assigned role
    ###########################################################################

    echo "Verifying role assignment..."

    USER_ROLES=$(
        curl -k \
          -sS \
          "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${USER_ID}/role-mappings/clients/${CLIENT_UUID}" \
          -H "Authorization: Bearer ${ACCESS_TOKEN}"
    )

    if echo "${USER_ROLES}" |
       jq -e \
         --arg role "${CONCERT_ROLE}" \
         '.[] | select(.name == $role)' \
         >/dev/null; then

        success "${username} has Concert role '${CONCERT_ROLE}'."

    else

        echo "ERROR: Role verification failed for ${username}"
        FAILED=$((FAILED + 1))
    fi

done < "${CSV_FILE}"

###############################################################################
# Summary
###############################################################################

echo
echo "============================================================"
echo " IBM Concert User Provisioning Summary"
echo "============================================================"
echo "Realm             : ${REALM}"
echo "Client            : ${CLIENT_ID}"
echo "Client UUID       : ${CLIENT_UUID}"
echo "Assigned role     : ${CONCERT_ROLE}"
echo "Total processed   : ${TOTAL}"
echo "Created           : ${CREATED}"
echo "Updated           : ${UPDATED}"
echo "Failures          : ${FAILED}"
echo "============================================================"

if [[ "${FAILED}" -gt 0 ]]; then
    exit 1
fi

echo
echo "All users were successfully provisioned."