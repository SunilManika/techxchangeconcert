#!/usr/bin/env python3
"""
IBM Concert 3.0.x - Lab1b Setup: Environments + Instana Ingestion Jobs
=======================================================================

Performs two operations in sequence:

  1. Create environments  (POST /concert/core/api/v1/environments)
     Input: environments.csv  — columns: name, purpose, description

  2. Create Instana ingestion jobs  (POST /concert/core/api/v1/ingestion_jobs)
     Input: instana-jobs.csv  — columns: name, connection_name, environment_name, description

     Each ingestion job references:
       • an existing Instana connection/credential by display name
       • an environment by display name   (looked up → environment_id parameter)

Authentication flow (fully automated):
  1. oc exec on Keycloak pod → KC bootstrap admin creds
  2. KC admin token  (master realm / admin-cli)
  3. concert-client secret from KC admin API
  4. Validate Concert user via KC  (concert-client + grant_type=password)
  5. Hub internal secret from app-cfg-secret  (concert-hub namespace)
  6. Port-forward to ibm-solis-core-svc → handle_login → Hub-signed JWT
  7. Instance ID from solis-account-instances-cm
  8. Call Concert APIs with platform JWT + instance-id header

API reference:
  https://developer.ibm.com/apis/catalog/concert--ibm-concert-api/
  api/API--concert--ibm-concert-api-v3-0-0-0#create_environment
  https://developer.ibm.com/apis/catalog/concert--ibm-concert-api/
  api/API--concert--ibm-concert-api-v3-0-0-0#create_ingestion_job

Prerequisites:
  - oc CLI installed and logged in to the OpenShift cluster.
  - python3 (stdlib only — no third-party packages).

Usage:
    python3 setup-environments.py
    python3 setup-environments.py environments.csv instana-jobs.csv

----------------------------------------------------------------------
Environment variables
----------------------------------------------------------------------
    CONCERT_URL          Concert app URL                   (required)
                         e.g. https://concert-concert.apps.<cluster>/concert

    CONCERT_HUB_URL      IBM Solis Hub URL                 (required)
                         e.g. https://solis-hub-concert-hub.apps.<cluster>

    CONCERT_USERNAME     Concert login username             (required)
    CONCERT_PASSWORD     Concert login password             (required)

    CONCERT_HUB_NS       Keycloak / Hub namespace           (default: concert-hub)
    CONCERT_REALM        Keycloak realm name                (default: concert-realm)
    CONCERT_SKIP_TLS     Skip TLS verification              (default: false)
    CONCERT_LOCAL_PORT   Local port for port-forward        (default: 18099)

----------------------------------------------------------------------
Input CSV formats
----------------------------------------------------------------------
environments.csv  (header required):
    name,purpose,description

    name         Display name for the environment
    purpose      Purpose tag, e.g. "testing" / "production"  (optional)
    description  Free-text description                        (optional)

instana-jobs.csv  (header required):
    name,connection_name,environment_name,description

    name              Display name for the ingestion job
    connection_name   Name of an existing Instana connection (from Lab1b/instana-connections.csv)
    environment_name  Name of an existing environment (from environments.csv)
    description       Free-text description  (optional)
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
# Configuration
# ---------------------------------------------------------------------------

CONCERT_URL       = os.environ.get("CONCERT_URL",       "").rstrip("/")
CONCERT_HUB_URL   = os.environ.get("CONCERT_HUB_URL",   "").rstrip("/")
CONCERT_USERNAME  = os.environ.get("CONCERT_USERNAME",  "")
CONCERT_PASSWORD  = os.environ.get("CONCERT_PASSWORD",  "")
CONCERT_HUB_NS    = os.environ.get("CONCERT_HUB_NS",    "concert-hub")
CONCERT_REALM     = os.environ.get("CONCERT_REALM",     "concert-realm")
CONCERT_SKIP_TLS  = os.environ.get("CONCERT_SKIP_TLS",  "false").lower() == "true"
LOCAL_PORT        = int(os.environ.get("CONCERT_LOCAL_PORT", "18099"))
KC_LOCAL_PORT     = int(os.environ.get("CONCERT_KC_LOCAL_PORT", "18443"))

ENV_CSV  = sys.argv[1] if len(sys.argv) > 1 else "environments.csv"
JOBS_CSV = sys.argv[2] if len(sys.argv) > 2 else "instana-jobs.csv"

_parsed      = urllib.parse.urlparse(CONCERT_URL)
CONCERT_BASE = f"{_parsed.scheme}://{_parsed.netloc}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def die(msg: str) -> None:
    print(f"\nERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def ok(msg: str) -> None:
    print(f"  OK  : {msg}")


def make_ssl_ctx() -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    if CONCERT_SKIP_TLS:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


def http_post_form(url: str, fields: dict) -> tuple[int, dict]:
    data = urllib.parse.urlencode(fields).encode()
    req  = urllib.request.Request(url, data=data,
           headers={"Content-Type": "application/x-www-form-urlencoded"}, method="POST")
    try:
        with urllib.request.urlopen(req, context=make_ssl_ctx()) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        try:    return e.code, json.loads(e.read().decode())
        except: return e.code, {}
    except urllib.error.URLError as e:
        die(f"Cannot reach {url}: {e.reason}")


def api_request(method: str, url: str, token: str,
                instance_id: str = "", payload: dict | None = None) -> tuple[int, dict | list]:
    data = json.dumps(payload).encode() if payload else None
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type":  "application/json",
        "Accept":        "application/json",
    }
    if instance_id:
        headers["instance-id"] = instance_id
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, context=make_ssl_ctx()) as r:
            raw = r.read()
            return r.status, (json.loads(raw.decode()) if raw else {})
    except urllib.error.HTTPError as e:
        try:    return e.code, json.loads(e.read().decode())
        except: return e.code, {}
    except urllib.error.URLError as e:
        die(f"Concert API unreachable at {url}: {e.reason}")


def http_post_json_local(port: int, path: str, extra_headers: dict,
                         payload: dict) -> tuple[int, dict]:
    """POST JSON to an HTTPS localhost endpoint (port-forward), TLS verify skipped."""
    url  = f"https://localhost:{port}{path}"
    data = json.dumps(payload).encode()
    ctx  = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    req  = urllib.request.Request(url, data=data, headers={
        "Content-Type": "application/json",
        "Accept":       "application/json",
        **extra_headers,
    }, method="POST")
    try:
        with urllib.request.urlopen(req, context=ctx) as r:
            raw = r.read()
            return r.status, (json.loads(raw.decode()) if raw else {})
    except urllib.error.HTTPError as e:
        try:    return e.code, json.loads(e.read().decode())
        except: return e.code, {}
    except urllib.error.URLError as e:
        die(f"Port-forward to localhost:{port} failed: {e.reason}")


def oc_exec(ns: str, pod: str, cmd: str) -> str:
    res = subprocess.run(["oc", "exec", "-n", ns, pod, "--", "sh", "-c", cmd],
                         capture_output=True, text=True)
    if res.returncode != 0:
        die(f"oc exec failed: {res.stderr.strip()}")
    return res.stdout.strip()


def oc_get_pod(ns: str, name_contains: str) -> str:
    res = subprocess.run(
        ["oc", "get", "pods", "-n", ns, "-o",
         "jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}"],
        capture_output=True, text=True)
    if res.returncode != 0:
        die(f"oc get pods failed: {res.stderr.strip()}")
    for line in res.stdout.splitlines():
        if name_contains in line:
            return line.strip()
    return ""


def wait_for_port(port: int, timeout: int = 12) -> bool:
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

print("=" * 64)
print("  IBM Concert 3.0.x — Lab1b: Environment + Ingestion Job Setup")
print("=" * 64)
print(f"  Concert URL   : {CONCERT_URL}")
print(f"  Hub URL       : {CONCERT_HUB_URL}")
print(f"  Hub Namespace : {CONCERT_HUB_NS}")
print(f"  Username      : {CONCERT_USERNAME}")
print(f"  Env CSV       : {ENV_CSV}")
print(f"  Jobs CSV      : {JOBS_CSV}")
print(f"  Skip TLS      : {CONCERT_SKIP_TLS}")
print()

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------

if not CONCERT_URL:
    die("CONCERT_URL is not set.")
if not CONCERT_HUB_URL:
    die("CONCERT_HUB_URL is not set.\n"
        "  Run: oc get routes -n concert-hub\n"
        "  e.g. export CONCERT_HUB_URL=https://solis-hub-concert-hub.apps.<cluster>")
if not CONCERT_USERNAME:
    die("CONCERT_USERNAME is not set.")
if not CONCERT_PASSWORD:
    die("CONCERT_PASSWORD is not set.")
if not os.path.isfile(ENV_CSV):
    die(f"Environments CSV '{ENV_CSV}' not found.")
if not os.path.isfile(JOBS_CSV):
    die(f"Ingestion jobs CSV '{JOBS_CSV}' not found.")

res = subprocess.run(["oc", "whoami"], capture_output=True, text=True)
if res.returncode != 0:
    die("Not logged in to OpenShift. Run 'oc login' first.")
print(f"  OCP user      : {res.stdout.strip()}")
print()

# ---------------------------------------------------------------------------
# Steps 1-7: Authenticate and obtain platform JWT
# ---------------------------------------------------------------------------

print("Step 1: Locating Keycloak pod ...")
KC_POD = oc_get_pod(CONCERT_HUB_NS, "ibm-solis-embedded-keycloak-")
if not KC_POD:
    die(f"Keycloak pod not found in namespace '{CONCERT_HUB_NS}'.")
ok(f"Keycloak pod: {KC_POD}")

print("Step 2: Retrieving Keycloak bootstrap credentials ...")
KC_ADMIN_USER = oc_exec(CONCERT_HUB_NS, KC_POD, 'printf "%s" "${KC_BOOTSTRAP_ADMIN_USERNAME:-}"')
KC_ADMIN_PASS = oc_exec(CONCERT_HUB_NS, KC_POD, 'printf "%s" "${KC_BOOTSTRAP_ADMIN_PASSWORD:-}"')
if not KC_ADMIN_USER or not KC_ADMIN_PASS:
    die("KC bootstrap credentials not available in pod env.")
ok(f"KC bootstrap admin: {KC_ADMIN_USER}")

print(f"Step 3: Port-forwarding to ibm-solis-hub-gw-svc:{KC_LOCAL_PORT} for Keycloak admin ...")
kc_pf = subprocess.Popen(
    ["oc", "port-forward", "-n", CONCERT_HUB_NS,
     "svc/ibm-solis-hub-gw-svc", f"{KC_LOCAL_PORT}:11443"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

try:
    if not wait_for_port(KC_LOCAL_PORT, timeout=15):
        kc_pf.terminate()
        die(f"Port-forward to localhost:{KC_LOCAL_PORT} not ready after 15 s.")
    ok(f"Keycloak port-forward ready on localhost:{KC_LOCAL_PORT}.")

    KC_LOCAL_URL    = f"https://localhost:{KC_LOCAL_PORT}/sys/internal/kc"
    TOKEN_EP_MASTER = f"{KC_LOCAL_URL}/realms/master/protocol/openid-connect/token"
    TOKEN_EP_REALM  = f"{KC_LOCAL_URL}/realms/{CONCERT_REALM}/protocol/openid-connect/token"

    print("  Obtaining Keycloak admin token (master realm / admin-cli) ...")
    st, body = http_post_form(TOKEN_EP_MASTER, {
        "grant_type": "password", "client_id": "admin-cli",
        "username": KC_ADMIN_USER, "password": KC_ADMIN_PASS,
    })
    KC_ADMIN_TOKEN = body.get("access_token", "")
    if not KC_ADMIN_TOKEN:
        die(f"KC admin token failed (HTTP {st}): {body.get('error_description', body)}")
    ok(f"KC admin token obtained (HTTP {st}).")

    print("Step 4: Retrieving concert-client secret ...")
    st, clients = api_request("GET", f"{KC_LOCAL_URL}/admin/realms/{CONCERT_REALM}/clients?clientId=concert-client", KC_ADMIN_TOKEN)
    if not isinstance(clients, list) or not clients:
        die(f"concert-client not found (HTTP {st}).")
    client_uuid = clients[0].get("id", "")
    st, sec = api_request("GET", f"{KC_LOCAL_URL}/admin/realms/{CONCERT_REALM}/clients/{client_uuid}/client-secret", KC_ADMIN_TOKEN)
    CLIENT_SECRET = sec.get("value", "")
    if not CLIENT_SECRET:
        die(f"concert-client secret not retrieved (HTTP {st}).")
    ok(f"concert-client secret retrieved (UUID: {client_uuid}).")

    print(f"Step 5: Validating Concert user '{CONCERT_USERNAME}' ...")
    st, body = http_post_form(TOKEN_EP_REALM, {
        "grant_type": "password", "client_id": "concert-client",
        "client_secret": CLIENT_SECRET, "username": CONCERT_USERNAME,
        "password": CONCERT_PASSWORD, "scope": "openid",
    })
    if not body.get("access_token"):
        die(f"User validation failed (HTTP {st}): {body.get('error_description', body)}")
    ok(f"User '{CONCERT_USERNAME}' validated (HTTP {st}).")

finally:
    kc_pf.terminate(); kc_pf.wait()

print("Step 6: Obtaining Hub-signed platform JWT ...")
hub_secret_res = subprocess.run(
    ["oc", "get", "secret", "app-cfg-secret", "-n", CONCERT_HUB_NS,
     "-o", "jsonpath={.data.SOLIS_HUB_INTERNAL_SECRET}"],
    capture_output=True, text=True)
if hub_secret_res.returncode != 0:
    die(f"Could not read app-cfg-secret: {hub_secret_res.stderr.strip()}")
SOLIS_SECRET = base64.b64decode(hub_secret_res.stdout.strip()).decode()
if not SOLIS_SECRET:
    die("SOLIS_HUB_INTERNAL_SECRET is empty.")
ok(f"Hub internal secret retrieved (length: {len(SOLIS_SECRET)}).")

print(f"  Starting port-forward ibm-solis-core-svc:{LOCAL_PORT} ...")
pf = subprocess.Popen(
    ["oc", "port-forward", "-n", CONCERT_HUB_NS,
     "svc/ibm-solis-core-svc", f"{LOCAL_PORT}:8000"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

try:
    if not wait_for_port(LOCAL_PORT, timeout=15):
        pf.terminate()
        die(f"Port-forward to localhost:{LOCAL_PORT} not ready after 15 s.")
    ok(f"Port-forward ready on localhost:{LOCAL_PORT}.")

    st, body = http_post_json_local(
        LOCAL_PORT, "/platform_hub/core/api/v1/handle_login",
        {"secret": SOLIS_SECRET}, {"username": CONCERT_USERNAME})

    if not isinstance(body, dict):
        die(f"handle_login returned unexpected response (HTTP {st}): {body!r}")
    PLATFORM_JWT = body.get("token", "")
    if not PLATFORM_JWT or st != 200:
        die(f"handle_login failed (HTTP {st}): {json.dumps(body)}")
    ok(f"Platform JWT obtained (HTTP {st}, length: {len(PLATFORM_JWT)}).")
finally:
    pf.terminate(); pf.wait()

# CONCERT_INSTANCE_ID env var overrides all automatic discovery.
print("Step 7: Reading Concert instance ID ...")
INSTANCE_ID = os.environ.get("CONCERT_INSTANCE_ID", "")
if INSTANCE_ID:
    ok(f"Concert instance ID (from CONCERT_INSTANCE_ID): {INSTANCE_ID}")
else:
    res = subprocess.run(
        ["oc", "get", "configmap", "solis-account-instances-cm",
         "-n", CONCERT_HUB_NS, "-o", "jsonpath={.data}"],
        capture_output=True, text=True, check=False)
    if res.returncode == 0 and res.stdout.strip():
        try:
            for key, val in json.loads(res.stdout).items():
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
        die("Concert instance ID not found in 'solis-account-instances-cm'.\n"
            "  Set manually: export CONCERT_INSTANCE_ID=<uuid>")

    ok(f"Concert instance ID: {INSTANCE_ID}")


# ---------------------------------------------------------------------------
# Helper: fetch existing resource list
# ---------------------------------------------------------------------------

def _extract_list(body) -> list[dict]:
    """Recursively unwrap any response shape to find the first list of dicts."""
    if isinstance(body, list):
        return [i for i in body if isinstance(i, dict)]
    if not isinstance(body, dict):
        return []
    # Direct top-level list values
    for v in body.values():
        if isinstance(v, list):
            return [i for i in v if isinstance(i, dict)]
    # Unwrap one level of nesting (e.g. {"data": {"environments": [...]}})
    nested = body.get("data")
    if isinstance(nested, list):
        return [i for i in nested if isinstance(i, dict)]
    if isinstance(nested, dict):
        for v in nested.values():
            if isinstance(v, list):
                return [i for i in v if isinstance(i, dict)]
    return []


def list_resources(endpoint: str) -> list[dict]:
    """GET endpoint, return items found in the response body."""
    st, body = api_request("GET", f"{CONCERT_BASE}{endpoint}", PLATFORM_JWT, INSTANCE_ID)
    if st != 200:
        die(f"GET {endpoint} returned HTTP {st}: {body}")
    return _extract_list(body)


def get_env_id_by_name(name: str) -> str:
    """Resolve an environment ID by querying with a name filter.

    Concert's list endpoint returns an empty array when the JWT's RBAC scope
    cannot see environments created by a different user.  Querying with
    ?name=<name> returns only that specific environment and bypasses the
    visibility restriction.
    """
    url = f"{CONCERT_BASE}/concert/core/api/v1/environments"
    params = urllib.parse.urlencode({"name": name})
    st, body = api_request("GET", f"{url}?{params}", PLATFORM_JWT, INSTANCE_ID)
    if st == 200:
        items = _extract_list(body)
        for item in items:
            if item.get("name", "").strip() == name:
                return item.get("id", "")
    return ""


def name_exists(items: list[dict], name: str) -> bool:
    return any(item.get("name", "").strip() == name for item in items)


def id_by_name(items: list[dict], name: str) -> str:
    for item in items:
        if item.get("name", "").strip() == name:
            return item.get("id", "")
    return ""


# ---------------------------------------------------------------------------
# Phase 1 — Create environments
# ---------------------------------------------------------------------------

ENV_ENDPOINT = f"{CONCERT_BASE}/concert/core/api/v1/environments"

print()
print("=" * 64)
print("  Phase 1: Creating Environments")
print("=" * 64)
print(f"  Endpoint: {ENV_ENDPOINT}")
print()

env_total = env_created = env_skipped = env_failed = 0

with open(ENV_CSV, newline="", encoding="utf-8") as fh:
    reader = csv.DictReader(fh)
    fieldnames = set(reader.fieldnames or [])
    if "name" not in fieldnames:
        die(f"environments.csv is missing required 'name' column.")

    existing_envs = list_resources("/concert/core/api/v1/environments")

    for row in reader:
        name        = row["name"].strip()
        purpose     = row.get("purpose", "").strip()
        description = row.get("description", "").strip()

        if not name:
            continue

        env_total += 1
        print(f"  [{env_total}] Environment : {name}")
        if purpose:
            print(f"       Purpose    : {purpose}")
        if description:
            print(f"       Description: {description[:80]}")

        # Check for existing
        if name_exists(existing_envs, name):
            print(f"       SKIP: Environment '{name}' already exists.")
            env_skipped += 1
            print()
            continue

        payload: dict = {"name": name}
        if purpose:
            payload["purpose"] = purpose
        if description:
            payload["description"] = description

        st, body = api_request("POST", ENV_ENDPOINT, PLATFORM_JWT, INSTANCE_ID, payload)

        if st in (200, 201):
            ok(f"Environment '{name}' created (ID: {body.get('id','N/A')}, HTTP {st}).")
            existing_envs.append(body)
            env_created += 1
        elif st in (400, 409):
            # Concert returns 400 "That environment already exists." — treat any
            # "already exists" message as a successful skip regardless of whether
            # the GET list is able to return it (Concert's list endpoint may not
            # return envs the user didn't create, depending on RBAC).
            exc_msg = str(body.get("exception", "")).lower()
            msg_str = str(body.get("message", "")).lower()
            if "already exists" in exc_msg or "already exists" in msg_str or st == 409:
                print(f"       SKIP: Environment '{name}' already exists (HTTP {st}).")
                # Synthesise a minimal dict so Phase 2 id_by_name can find it.
                existing_envs.append({"name": name, "id": body.get("id", "")})
                env_skipped += 1
            else:
                print(f"       ERROR: HTTP {st} for '{name}'.")
                print(f"       Response: {json.dumps(body, indent=6)}")
                env_failed += 1

        print()

print(f"  Environments — Created: {env_created}  Skipped: {env_skipped}  Failed: {env_failed}")

# ---------------------------------------------------------------------------
# Phase 2 — Create Instana ingestion jobs
# ---------------------------------------------------------------------------

JOBS_ENDPOINT  = f"{CONCERT_BASE}/concert/core/api/v1/ingestion_jobs"
CREDS_ENDPOINT = f"{CONCERT_BASE}/concert/core/api/v1/credentials"

print()
print("=" * 64)
print("  Phase 2: Creating Instana Ingestion Jobs")
print("=" * 64)
print(f"  Endpoint: {JOBS_ENDPOINT}")
print()

job_total = job_created = job_skipped = job_failed = 0

with open(JOBS_CSV, newline="", encoding="utf-8") as fh:
    reader = csv.DictReader(fh)
    fieldnames = set(reader.fieldnames or [])
    missing = {"name", "connection_name", "environment_name"} - fieldnames
    if missing:
        die(f"instana-jobs.csv is missing required columns: {', '.join(sorted(missing))}")

    all_creds = list_resources("/concert/core/api/v1/credentials")
    _fetched_envs = list_resources("/concert/core/api/v1/environments")
    # Fall back to the Phase-1 snapshot (contains synthesised entries for
    # environments that existed before this run) if the GET returned nothing.
    all_envs  = _fetched_envs if _fetched_envs else existing_envs
    all_jobs  = list_resources("/concert/core/api/v1/ingestion_jobs")

    for row in reader:
        name        = row["name"].strip()
        conn_name   = row["connection_name"].strip()
        env_name    = row["environment_name"].strip()
        description = row.get("description", "").strip()

        if not name:
            continue

        job_total += 1
        print(f"  [{job_total}] Job           : {name}")
        print(f"       Connection    : {conn_name}")
        print(f"       Environment   : {env_name}")
        if description:
            print(f"       Description   : {description[:80]}")

        errors = []
        if not conn_name:
            errors.append("connection_name is empty")
        if not env_name:
            errors.append("environment_name is empty")
        if errors:
            print(f"       ERROR: {'; '.join(errors)}")
            job_failed += 1
            print()
            continue

        # Look up credential ID
        cred_id = id_by_name(all_creds, conn_name)
        if not cred_id:
            print(f"       ERROR: Instana connection '{conn_name}' not found in Concert.")
            print(f"         Available connections: {[c['name'] for c in all_creds]}")
            job_failed += 1
            print()
            continue

        # Look up environment ID — first try the in-memory list, then fall
        # back to a direct name-filtered GET (needed when the RBAC-scoped list
        # endpoint returns an empty array for envs created by another user).
        env_id = id_by_name(all_envs, env_name)
        if not env_id:
            env_id = get_env_id_by_name(env_name)
        if not env_id:
            print(f"       ERROR: Environment '{env_name}' not found in Concert.")
            print(f"         Available environments: {[e['name'] for e in all_envs]}")
            job_failed += 1
            print()
            continue

        print(f"       Credential ID : {cred_id}")
        print(f"       Environment ID: {env_id}")

        # Check for existing ingestion job with same name
        if name_exists(all_jobs, name):
            print(f"       SKIP: Ingestion job '{name}' already exists.")
            job_skipped += 1
            print()
            continue

        payload: dict = {
            "name":           name,
            "type":           "instana",
            "credentials_id": cred_id,
            "enabled":        "enabled",
            "status":         "",
            "scheduled":      0,
            "details": {
                "parameters": [
                    {"key": "environment_id", "value": env_id},
                ],
            },
        }
        if description:
            payload["description"] = description

        import json as _json
        print(f"       Payload: {_json.dumps(payload)}")
        st, body = api_request("POST", JOBS_ENDPOINT, PLATFORM_JWT, INSTANCE_ID, payload)

        if st in (200, 201):
            ok(f"Ingestion job '{name}' created "
               f"(ID: {body.get('id','N/A')}, HTTP {st}).")
            all_jobs.append(body)
            job_created += 1
        elif st in (400, 409):
            # Re-check against a fresh list in case the job was created concurrently.
            all_jobs = list_resources("/concert/core/api/v1/ingestion_jobs")
            if name_exists(all_jobs, name):
                print(f"       SKIP: Ingestion job '{name}' already exists (HTTP {st}).")
                job_skipped += 1
            else:
                print(f"       ERROR: HTTP {st} for '{name}'.")
                print(f"       Response: {json.dumps(body, indent=6)}")
                job_failed += 1

        print()

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print("=" * 64)
print("  Summary")
print("=" * 64)
print(f"  Concert URL    : {CONCERT_URL}")
print(f"  Instance ID    : {INSTANCE_ID}")
print()
print(f"  Environments")
print(f"    Total        : {env_total}")
print(f"    Created      : {env_created}")
print(f"    Skipped      : {env_skipped}")
print(f"    Failed       : {env_failed}")
print()
print(f"  Ingestion Jobs")
print(f"    Total        : {job_total}")
print(f"    Created      : {job_created}")
print(f"    Skipped      : {job_skipped}")
print(f"    Failed       : {job_failed}")
print("=" * 64)

if env_failed or job_failed:
    sys.exit(1)

print()
print("All environments and ingestion jobs provisioned successfully.")
