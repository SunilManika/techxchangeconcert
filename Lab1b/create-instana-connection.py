#!/usr/bin/env python3
"""
IBM Concert 3.0.x - Bulk Instana Connection Provisioning
=========================================================

Creates Instana credential/connection entries in IBM Concert via the
Concert REST API:

    POST /concert/core/api/v1/credentials

Authentication flow (fully automated — no manual API key needed):
  1. Use `oc exec` on the embedded Keycloak pod to retrieve the
     KC bootstrap admin credentials (KC_BOOTSTRAP_ADMIN_USERNAME /
     KC_BOOTSTRAP_ADMIN_PASSWORD).
  2. Obtain a Keycloak admin token (admin-cli / master realm).
  3. Retrieve the concert-client secret from the Keycloak admin API.
  4. Obtain a Keycloak user token using concert-client + client_secret
     and the Concert user's username/password (grant_type=password).
     This validates the user exists and the password is correct.
  5. Use `oc exec` to read SOLIS_HUB_INTERNAL_SECRET from the Hub secret.
  6. Port-forward to ibm-solis-core-svc and call handle_login with the
     Concert username → returns a Hub-signed platform JWT
     (aud=PLATFORMAUD) that the Concert API accepts.
  7. Read the Concert instance ID from solis-account-instances-cm.
  8. Call POST /concert/core/api/v1/credentials for each row in the CSV.

Credential payload shape for Instana (discovered from Concert UI source):
    {
      "name": "<display-name>",
      "type": "instana",
      "credentials": [
        {"key": "endpoint", "value": "<instana-base-url>"},
        {"key": "api_key",  "value": "<instana-api-key>"}
      ]
    }

NOTE — Self-signed / private CA on Instana:
  If the Instana endpoint uses a self-signed certificate, run the
  one-time cluster fix script BEFORE this script:

      ./fix-instana-tls.sh <instana_url> <credential_name>

  That script patches the Concert TLS CA bundle and restarts the
  relevant pods.  This script makes NO changes to the OCP cluster.

Prerequisites:
  - `oc` CLI installed and logged in to the OpenShift cluster.
  - `python3` (stdlib only — no third-party packages needed).

Reference:
    https://developer.ibm.com/apis/catalog/concert--ibm-concert-api/
    api/API--concert--ibm-concert-api-v3-0-0-0#create_credential

Usage:
    python3 create-instana-connection.py
    python3 create-instana-connection.py instana-connections.csv

----------------------------------------------------------------------
Environment variables
----------------------------------------------------------------------
    CONCERT_URL          Concert app URL                   (required)
                         e.g. https://concert-concert.apps.<cluster>/concert

    CONCERT_HUB_URL      IBM Solis Hub URL                 (required)
                         e.g. https://solis-hub-concert-hub.apps.<cluster>
                         Hint: oc get routes -n concert-hub

    CONCERT_USERNAME     Concert login username             (required)
    CONCERT_PASSWORD     Concert login password             (required)

    CONCERT_HUB_NS       Keycloak / Hub namespace           (default: concert-hub)
    CONCERT_REALM        Keycloak realm name                (default: concert-realm)
    CONCERT_SKIP_TLS     Skip TLS verification for Concert  (default: false)

    CONCERT_LOCAL_PORT   Local port for port-forward        (default: 18099)

----------------------------------------------------------------------
Input CSV format (header row required)
----------------------------------------------------------------------
    name,instana_url,api_key

    name         Display name for the connection in Concert
    instana_url  Base URL of the Instana backend  (https://...)
    api_key      Instana REST API key

Example:
    name,instana_url,api_key
    my-instana,https://instana.example.com,Fn3Jc9GeTZyudAU4nHfDNg
"""

import base64
import csv
import json
import os
import socket
import subprocess
import sys
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

# ---------------------------------------------------------------------------
# Configuration — all from environment variables
# ---------------------------------------------------------------------------

CONCERT_URL       = os.environ.get("CONCERT_URL",       "").rstrip("/")
CONCERT_HUB_URL   = os.environ.get("CONCERT_HUB_URL",   "").rstrip("/")
CONCERT_USERNAME  = os.environ.get("CONCERT_USERNAME",  "")
CONCERT_PASSWORD  = os.environ.get("CONCERT_PASSWORD",  "")
CONCERT_HUB_NS    = os.environ.get("CONCERT_HUB_NS",    "concert-hub")
CONCERT_REALM     = os.environ.get("CONCERT_REALM",     "concert-realm")
CONCERT_SKIP_TLS  = os.environ.get("CONCERT_SKIP_TLS",  "false").lower() == "true"
LOCAL_PORT        = int(os.environ.get("CONCERT_LOCAL_PORT", "18099"))

CSV_FILE = sys.argv[1] if len(sys.argv) > 1 else "instana-connections.csv"

# Concert API base: strip app path suffix (e.g. /concert) — API paths root at host
_parsed       = urllib.parse.urlparse(CONCERT_URL)
CONCERT_BASE  = f"{_parsed.scheme}://{_parsed.netloc}"

# Keycloak endpoint (on Hub route)
KC_URL           = f"{CONCERT_HUB_URL}/sys/internal/kc"
TOKEN_EP_MASTER  = f"{KC_URL}/realms/master/protocol/openid-connect/token"
TOKEN_EP_REALM   = f"{KC_URL}/realms/{CONCERT_REALM}/protocol/openid-connect/token"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def die(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def success(message: str) -> None:
    print(f"  OK  : {message}")


def make_ssl_context() -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    if CONCERT_SKIP_TLS:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


def http_post_form(url: str, fields: dict) -> tuple[int, dict]:
    data = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, context=make_ssl_context()) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        body = {}
        try:
            body = json.loads(exc.read().decode())
        except Exception:
            pass
        return exc.code, body
    except urllib.error.URLError as exc:
        die(f"Cannot reach {url}: {exc.reason}")


def api_request(
    method: str,
    url: str,
    token: str,
    instance_id: str = "",
    payload: dict | None = None,
    extra_headers: dict | None = None,
) -> tuple[int, dict]:
    data = json.dumps(payload).encode() if payload else None
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type":  "application/json",
        "Accept":        "application/json",
    }
    if instance_id:
        headers["instance-id"] = instance_id
    if extra_headers:
        headers.update(extra_headers)
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, context=make_ssl_context()) as resp:
            raw = resp.read()
            return resp.status, json.loads(raw.decode()) if raw else {}
    except urllib.error.HTTPError as exc:
        body = {}
        try:
            body = json.loads(exc.read().decode())
        except Exception:
            pass
        return exc.code, body
    except urllib.error.URLError as exc:
        die(f"Concert API unreachable at {url}: {exc.reason}")


def http_post_json_local(port: int, path: str, headers: dict, payload: dict) -> tuple[int, dict]:
    """POST JSON to an HTTPS endpoint on localhost (port-forward), skip TLS verify."""
    url = f"https://localhost:{port}{path}"
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers={
        "Content-Type": "application/json",
        "Accept":       "application/json",
        **headers,
    }, method="POST")
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(req, context=ctx) as resp:
            raw = resp.read()
            return resp.status, json.loads(raw.decode()) if raw else {}
    except urllib.error.HTTPError as exc:
        body = {}
        try:
            body = json.loads(exc.read().decode())
        except Exception:
            pass
        return exc.code, body
    except urllib.error.URLError as exc:
        die(f"Port-forward to localhost:{port} failed: {exc.reason}")


def oc_exec(namespace: str, pod: str, shell_cmd: str) -> str:
    """Run a shell command inside a pod via oc exec, return stdout stripped."""
    result = subprocess.run(
        ["oc", "exec", "-n", namespace, pod, "--", "sh", "-c", shell_cmd],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        die(f"oc exec failed: {result.stderr.strip()}")
    return result.stdout.strip()


def oc_get_pod(namespace: str, grep: str) -> str:
    """Return the first running pod name matching a grep pattern."""
    result = subprocess.run(
        ["oc", "get", "pods", "-n", namespace,
         "-o", "jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        die(f"oc get pods failed: {result.stderr.strip()}")
    for line in result.stdout.splitlines():
        if grep in line:
            return line.strip()
    return ""


def wait_for_port(port: int, timeout: int = 10) -> bool:
    """Wait until a local TCP port is listening."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return True
        except OSError:
            time.sleep(0.5)
    return False


# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

print("=" * 62)
print("  IBM Concert 3.0.x — Instana Connection Provisioning")
print("=" * 62)
print(f"  Concert URL   : {CONCERT_URL}")
print(f"  Hub URL       : {CONCERT_HUB_URL}")
print(f"  Hub Namespace : {CONCERT_HUB_NS}")
print(f"  Realm         : {CONCERT_REALM}")
print(f"  Username      : {CONCERT_USERNAME}")
print(f"  CSV File      : {CSV_FILE}")
print(f"  Skip TLS      : {CONCERT_SKIP_TLS}")
print()

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------

if not CONCERT_URL:
    die("CONCERT_URL environment variable is not set.")
if not CONCERT_HUB_URL:
    die(
        "CONCERT_HUB_URL is not set.\n"
        "  Run: oc get routes -n concert-hub\n"
        "  Set to the solis-hub route URL, e.g.:\n"
        "  export CONCERT_HUB_URL=https://solis-hub-concert-hub.apps.<cluster>"
    )
if not CONCERT_USERNAME:
    die("CONCERT_USERNAME environment variable is not set.")
if not CONCERT_PASSWORD:
    die("CONCERT_PASSWORD environment variable is not set.")
if not os.path.isfile(CSV_FILE):
    die(f"CSV file '{CSV_FILE}' does not exist.")

# Check oc is available
result = subprocess.run(["oc", "whoami"], capture_output=True, text=True)
if result.returncode != 0:
    die("Not logged in to OpenShift. Run 'oc login' first.")
print(f"  OCP user      : {result.stdout.strip()}")
print()

# ---------------------------------------------------------------------------
# Step 1 — Locate embedded Keycloak pod
# ---------------------------------------------------------------------------

print(f"Step 1: Locating Keycloak pod in namespace '{CONCERT_HUB_NS}' ...")

KC_POD = oc_get_pod(CONCERT_HUB_NS, "ibm-solis-embedded-keycloak-")
if not KC_POD:
    die(f"Embedded Keycloak pod not found in namespace '{CONCERT_HUB_NS}'.")

success(f"Keycloak pod: {KC_POD}")

# ---------------------------------------------------------------------------
# Step 2 — Retrieve KC bootstrap admin credentials from pod env
# ---------------------------------------------------------------------------

print("Step 2: Retrieving Keycloak bootstrap credentials ...")

KC_ADMIN_USER = oc_exec(CONCERT_HUB_NS, KC_POD,
                        'printf "%s" "${KC_BOOTSTRAP_ADMIN_USERNAME:-}"')
KC_ADMIN_PASS = oc_exec(CONCERT_HUB_NS, KC_POD,
                        'printf "%s" "${KC_BOOTSTRAP_ADMIN_PASSWORD:-}"')

if not KC_ADMIN_USER or not KC_ADMIN_PASS:
    die("Keycloak bootstrap credentials not available in pod environment.")

success(f"KC bootstrap admin: {KC_ADMIN_USER}")

# ---------------------------------------------------------------------------
# Step 3 — Get Keycloak admin token (master realm / admin-cli)
# ---------------------------------------------------------------------------

print("Step 3: Obtaining Keycloak admin token ...")

status, body = http_post_form(TOKEN_EP_MASTER, {
    "grant_type": "password",
    "client_id":  "admin-cli",
    "username":   KC_ADMIN_USER,
    "password":   KC_ADMIN_PASS,
})

KC_ADMIN_TOKEN = body.get("access_token", "")
if not KC_ADMIN_TOKEN:
    die(f"Failed to obtain KC admin token (HTTP {status}): "
        f"{body.get('error_description', body.get('error', ''))}")

success(f"KC admin token obtained (HTTP {status}).")

# ---------------------------------------------------------------------------
# Step 4 — Retrieve concert-client secret from Keycloak admin API
# ---------------------------------------------------------------------------

print("Step 4: Retrieving concert-client secret ...")

clients_url = (f"{KC_URL}/admin/realms/{CONCERT_REALM}"
               f"/clients?clientId=concert-client")
status, clients_body = api_request("GET", clients_url, KC_ADMIN_TOKEN)

if not isinstance(clients_body, list) or not clients_body:
    die(f"concert-client not found in realm '{CONCERT_REALM}' (HTTP {status}).")

client_uuid = clients_body[0].get("id", "")
if not client_uuid:
    die("Could not extract concert-client UUID.")

secret_url = (f"{KC_URL}/admin/realms/{CONCERT_REALM}"
              f"/clients/{client_uuid}/client-secret")
status, secret_body = api_request("GET", secret_url, KC_ADMIN_TOKEN)

CLIENT_SECRET = secret_body.get("value", "")
if not CLIENT_SECRET:
    die(f"Could not retrieve concert-client secret (HTTP {status}): {secret_body}")

success(f"concert-client secret retrieved (client UUID: {client_uuid}).")

# ---------------------------------------------------------------------------
# Step 5 — Validate user credentials via Keycloak
# ---------------------------------------------------------------------------

print(f"Step 5: Validating Concert user '{CONCERT_USERNAME}' ...")

status, body = http_post_form(TOKEN_EP_REALM, {
    "grant_type":    "password",
    "client_id":     "concert-client",
    "client_secret": CLIENT_SECRET,
    "username":      CONCERT_USERNAME,
    "password":      CONCERT_PASSWORD,
    "scope":         "openid",
})

if not body.get("access_token"):
    die(f"User authentication failed (HTTP {status}): "
        f"{body.get('error_description', body.get('error', json.dumps(body)))}")

success(f"User '{CONCERT_USERNAME}' validated (HTTP {status}).")

# ---------------------------------------------------------------------------
# Step 6 — Obtain Hub-signed platform JWT via handle_login
# ---------------------------------------------------------------------------

print("Step 6: Obtaining Hub-signed platform JWT ...")

HUB_SECRET_B64 = subprocess.run(
    ["oc", "get", "secret", "app-cfg-secret", "-n", CONCERT_HUB_NS,
     "-o", "jsonpath={.data.SOLIS_HUB_INTERNAL_SECRET}"],
    capture_output=True, text=True,
)
if HUB_SECRET_B64.returncode != 0:
    die(f"Could not read app-cfg-secret: {HUB_SECRET_B64.stderr.strip()}")

SOLIS_INTERNAL_SECRET = base64.b64decode(
    HUB_SECRET_B64.stdout.strip()
).decode("utf-8")

if not SOLIS_INTERNAL_SECRET:
    die("SOLIS_HUB_INTERNAL_SECRET is empty in app-cfg-secret.")

success(f"Hub internal secret retrieved (length: {len(SOLIS_INTERNAL_SECRET)}).")

print(f"  Starting port-forward to ibm-solis-core-svc:{LOCAL_PORT} ...")
pf_proc = subprocess.Popen(
    ["oc", "port-forward", "-n", CONCERT_HUB_NS,
     "svc/ibm-solis-core-svc", f"{LOCAL_PORT}:8000"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
)

try:
    if not wait_for_port(LOCAL_PORT, timeout=15):
        pf_proc.terminate()
        die(f"Port-forward to localhost:{LOCAL_PORT} did not become ready in 15 s.")

    success(f"Port-forward ready on localhost:{LOCAL_PORT}.")

    status, body = http_post_json_local(
        LOCAL_PORT,
        "/platform_hub/core/api/v1/handle_login",
        {"secret": SOLIS_INTERNAL_SECRET},
        {"username": CONCERT_USERNAME},
    )

    PLATFORM_JWT = body.get("token", "")
    if not PLATFORM_JWT or status != 200:
        die(f"handle_login failed (HTTP {status}): {json.dumps(body)}")

    success(f"Platform JWT obtained (HTTP {status}, "
            f"length: {len(PLATFORM_JWT)}).")

finally:
    pf_proc.terminate()
    pf_proc.wait()

# ---------------------------------------------------------------------------
# Step 7 — Read Concert instance ID from OpenShift configmap
# ---------------------------------------------------------------------------

print("Step 7: Reading Concert instance ID from OpenShift ...")

result = subprocess.run(
    ["oc", "get", "configmap", "solis-account-instances-cm",
     "-n", CONCERT_HUB_NS,
     "-o", "jsonpath={.data}"],
    capture_output=True, text=True, check=False,
)

INSTANCE_ID = ""
if result.returncode == 0 and result.stdout.strip():
    try:
        cm_data = json.loads(result.stdout.strip())
        for key, val in cm_data.items():
            if key.startswith("_"):
                continue
            entries = json.loads(val) if isinstance(val, str) else val
            for entry in (entries if isinstance(entries, list) else [entries]):
                if entry.get("product_id") == "concert":
                    INSTANCE_ID = entry.get("instance_id", "")
                    break
            if INSTANCE_ID:
                break
    except Exception as exc:
        die(f"Failed to parse solis-account-instances-cm: {exc}")

if not INSTANCE_ID:
    die(
        "Concert instance ID not found in 'solis-account-instances-cm'.\n"
        f"  Raw output: {result.stdout[:300]}"
    )

success(f"Concert instance ID: {INSTANCE_ID}")

# ---------------------------------------------------------------------------
# Step 8 — Process CSV and create each Instana connection
#
# Payload shape (from Concert UI source / IngestionjobCredentialPrototype):
#
#   POST /concert/core/api/v1/credentials
#   {
#     "name": "<display-name>",
#     "type": "instana",
#     "credentials": [
#       {"key": "endpoint", "value": "<instana-base-url>"},
#       {"key": "api_key",  "value": "<instana-api-key>"}
#     ]
#   }
# ---------------------------------------------------------------------------

CREDENTIALS_URL = f"{CONCERT_BASE}/concert/core/api/v1/credentials"


def credential_name_exists(url: str, token: str, instance_id: str, name: str) -> tuple[bool, str]:
    """Return (exists, credential_id) for a credential matching name."""
    st, body = api_request("GET", url, token, instance_id)
    if st != 200:
        return False, ""
    for cred in body.get("credentials", []):
        if cred.get("name", "").strip() == name:
            return True, cred.get("id", "")
    return False, ""


print()
print("=" * 62)
print("  Step 8: Creating Instana Connections")
print("=" * 62)
print(f"  Endpoint: {CREDENTIALS_URL}")
print()

total = created = skipped = failed = 0

with open(CSV_FILE, newline="", encoding="utf-8") as fh:
    reader = csv.DictReader(fh)

    # Accept both 'api_key' and legacy 'api_token' column names
    fieldnames = set(reader.fieldnames or [])
    api_key_col = "api_key" if "api_key" in fieldnames else "api_token"

    missing = {"name", "instana_url"} - fieldnames
    if api_key_col not in fieldnames:
        missing.add("api_key (or api_token)")
    if missing:
        die(f"CSV is missing required columns: {', '.join(sorted(missing))}")

    for row in reader:
        name        = row["name"].strip()
        instana_url = row["instana_url"].strip()
        instana_key = row[api_key_col].strip()

        if not name:
            continue

        total += 1
        print(f"  [{total}] Connection : {name}")
        print(f"      Instana URL: {instana_url}")
        print(f"      API Key    : {instana_key[:8]}***" if instana_key else "      API Key    : (empty)")

        errors = []
        if not instana_url:
            errors.append("instana_url is empty")
        if not instana_key:
            errors.append(f"{api_key_col} is empty")
        if errors:
            print(f"      ERROR: {'; '.join(errors)}")
            failed += 1
            print()
            continue

        payload = {
            "name": name,
            "type": "instana",
            "credentials": [
                {"key": "endpoint", "value": instana_url},
                {"key": "api_key",  "value": instana_key},
            ],
        }

        status, body = api_request(
            "POST", CREDENTIALS_URL, PLATFORM_JWT, INSTANCE_ID, payload
        )

        if status in (200, 201):
            credential_id = body.get("id", "")
            success(f"Connection '{name}' created "
                    f"(ID: {credential_id}, HTTP {status}).")
            created += 1
        elif status == 409 or (
            status == 400
            and credential_name_exists(CREDENTIALS_URL, PLATFORM_JWT, INSTANCE_ID, name)[0]
        ):
            _, cred_id = credential_name_exists(CREDENTIALS_URL, PLATFORM_JWT, INSTANCE_ID, name)
            print(f"      SKIP: Connection '{name}' already exists (ID: {cred_id}).")
            skipped += 1
        else:
            print(f"      ERROR: Unexpected HTTP {status} for '{name}'.")
            print(f"      Response: {json.dumps(body, indent=6)}")
            failed += 1

        print()

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print("=" * 62)
print("  Summary")
print("=" * 62)
print(f"  Concert URL       : {CONCERT_URL}")
print(f"  Instance ID       : {INSTANCE_ID}")
print(f"  CSV File          : {CSV_FILE}")
print(f"  Total processed   : {total}")
print(f"  Created           : {created}")
print(f"  Skipped (exists)  : {skipped}")
print(f"  Failures          : {failed}")
print("=" * 62)

if failed:
    sys.exit(1)

print()
print("All Instana connections were successfully provisioned.")
