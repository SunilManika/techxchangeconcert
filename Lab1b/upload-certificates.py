#!/usr/bin/env python3
"""
IBM Concert 3.0.x - Certificate Upload
=======================================

Uploads a certificate inventory CSV to IBM Concert via the ingestion API:

    POST /ingestion/api/v1/upload_files

The endpoint accepts the CSV as a multipart/form-data file upload with:
    - data_type = certificate
    - metadata  = {"env_name": "<environment-name>"}
    - filename  = @<path-to-csv>

The upload is asynchronous — Concert returns HTTP 202 with record_paths and
event_ids.  After uploading, this script polls
GET /concert/core/api/v1/certificates to verify that the uploaded certificate
serial numbers appear in Concert (confirming the background pipeline has run).

Equivalent curl commands:
    # 1. Upload
    curl -k --fail-with-body \\
      -X POST \\
      "https://${CONCERT_HOST}/ingestion/api/v1/upload_files" \\
      -H "accept: application/csv" \\
      -H "InstanceID: ${INSTANCE_ID}" \\
      -H "Authorization: ZenApiKey ${API_KEY}" \\
      -H "Content-Type: multipart/form-data" \\
      -F "data_type=certificate" \\
      -F 'metadata={"env_name":"prod"}' \\
      -F "filename=@${CERT_FILE}"

    # 2. Verify (poll until certs appear)
    curl -k -X GET \\
      "https://${CONCERT_HOST}/concert/core/api/v1/certificates" \\
      -H "InstanceID: ${INSTANCE_ID}" \\
      -H "Authorization: Bearer ${JWT}"

Authentication — two modes (pick one):
  A. Automated (default) — derives a Hub-signed platform JWT automatically using
     the same oc-based auth flow as the other Lab1b scripts.  No API key needed.
       Required env vars: CONCERT_URL, CONCERT_HUB_URL, CONCERT_USERNAME,
                          CONCERT_PASSWORD

  B. Pre-supplied API key — set CONCERT_API_KEY and the script uses it directly
     as a ZenApiKey bearer token, skipping the automated auth flow entirely.
       Required env vars: CONCERT_URL, CONCERT_API_KEY

Upload strategy:
  The script reads the input CSV and groups rows by the value in the 'Namespace'
  column.  One upload request is made per unique namespace value, with
  metadata={"env_name":"<namespace>"}.

  Override the env_name for all rows by setting CONCERT_ENV_NAME.

Prerequisites:
  - python3 (stdlib only — no pip installs required)
  - oc CLI installed and logged in  (only needed for Mode A)

Reference:
  https://developer.ibm.com/apis/catalog/concert--ibm-concert-api/
  api/API--concert--ibm-concert-api-v3-0-0-0#upload_files

Usage:
    python3 upload-certificates.py
    python3 upload-certificates.py concert-certificates.csv

----------------------------------------------------------------------
Environment variables
----------------------------------------------------------------------
    CONCERT_URL          Concert app URL                   (required)
                         e.g. https://concert-concert.apps.<cluster>/concert

    --- Mode A: automated JWT auth (default) ---
    CONCERT_HUB_URL      IBM Solis Hub URL                 (required for Mode A)
    CONCERT_USERNAME     Concert login username             (required for Mode A)
    CONCERT_PASSWORD     Concert login password             (required for Mode A)
    CONCERT_HUB_NS       Keycloak / Hub namespace           (default: concert-hub)
    CONCERT_REALM        Keycloak realm name                (default: concert-realm)
    CONCERT_LOCAL_PORT   Local port for port-forward        (default: 18099)

    --- Mode B: pre-supplied API key ---
    CONCERT_API_KEY      ZenApiKey value                   (triggers Mode B)

    --- Common ---
    CONCERT_SKIP_TLS     Skip TLS verification              (default: false)
    CONCERT_ENV_NAME     Override env_name for all uploads  (default: use Namespace column)
    CONCERT_POLL_TIMEOUT  Seconds to wait for certs to appear  (default: 120)
    CONCERT_POLL_INTERVAL Seconds between verification polls   (default: 10)

----------------------------------------------------------------------
Input CSV columns (header row required)
----------------------------------------------------------------------
  Serial Number, Name, Subject, CN, Issuer, Key Algorithm, Key Size,
  SANS, ValidFrom, Valid To, Thumbprint, Certificate Hosts,
  System Reference Id, DN, ParentDN, Certificate Type, CreatedOn,
  Primary Owner, Secondary Owner, Namespace

  The 'Namespace' column is used as the env_name in the upload metadata.
  All other columns are passed through to Concert as-is.
"""

import base64
import csv
import io
import json
import os
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CONCERT_URL      = os.environ.get("CONCERT_URL",      "").rstrip("/")
CONCERT_HUB_URL  = os.environ.get("CONCERT_HUB_URL",  "").rstrip("/")
CONCERT_USERNAME = os.environ.get("CONCERT_USERNAME", "")
CONCERT_PASSWORD = os.environ.get("CONCERT_PASSWORD", "")
CONCERT_HUB_NS   = os.environ.get("CONCERT_HUB_NS",   "concert-hub")
CONCERT_REALM    = os.environ.get("CONCERT_REALM",    "concert-realm")
CONCERT_SKIP_TLS = os.environ.get("CONCERT_SKIP_TLS", "false").lower() == "true"
LOCAL_PORT       = int(os.environ.get("CONCERT_LOCAL_PORT", "18099"))
KC_LOCAL_PORT    = int(os.environ.get("CONCERT_KC_LOCAL_PORT", "18443"))

CONCERT_API_KEY      = os.environ.get("CONCERT_API_KEY",      "")   # Mode B
CONCERT_ENV_NAME     = os.environ.get("CONCERT_ENV_NAME",     "")   # override env_name
CONCERT_POLL_TIMEOUT  = int(os.environ.get("CONCERT_POLL_TIMEOUT",  "120"))
CONCERT_POLL_INTERVAL = int(os.environ.get("CONCERT_POLL_INTERVAL", "5"))

CSV_FILE = sys.argv[1] if len(sys.argv) > 1 else "concert-certificates.csv"

# Derive the Concert host (scheme + netloc) from CONCERT_URL
_parsed      = urllib.parse.urlparse(CONCERT_URL)
CONCERT_BASE = f"{_parsed.scheme}://{_parsed.netloc}"

UPLOAD_PATH  = "/ingestion/api/v1/upload_files"
CERTS_PATH   = "/concert/core/api/v1/certificates"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def die(msg: str) -> None:
    print(f"\nERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def ok(msg: str) -> None:
    print(f"  OK  : {msg}")


def info(msg: str) -> None:
    print(f"  --> : {msg}")


def make_ssl_ctx() -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    if CONCERT_SKIP_TLS:
        ctx.check_hostname = False
        ctx.verify_mode    = ssl.CERT_NONE
    return ctx


def http_post_form(url: str, fields: dict) -> tuple[int, dict]:
    data = urllib.parse.urlencode(fields).encode()
    req  = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
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
    data    = json.dumps(payload).encode() if payload else None
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
    url  = f"https://localhost:{port}{path}"
    data = json.dumps(payload).encode()
    ctx  = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode    = ssl.CERT_NONE
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
# multipart/form-data encoder (stdlib only — no requests/httpx needed)
# ---------------------------------------------------------------------------

def encode_multipart(fields: list[tuple[str, str]], file_field: str,
                     filename: str, file_bytes: bytes,
                     content_type: str = "text/csv") -> tuple[bytes, str]:
    """
    Build a multipart/form-data body from a list of (name, value) text fields
    and a single file field.

    Returns (body_bytes, content_type_header_value).
    """
    boundary = uuid.uuid4().hex
    ctype    = f"multipart/form-data; boundary={boundary}"
    buf      = io.BytesIO()
    sep      = f"--{boundary}\r\n".encode()

    for name, value in fields:
        buf.write(sep)
        buf.write(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        buf.write(value.encode())
        buf.write(b"\r\n")

    # File field
    buf.write(sep)
    buf.write(
        f'Content-Disposition: form-data; name="{file_field}"; '
        f'filename="{filename}"\r\n'.encode()
    )
    buf.write(f"Content-Type: {content_type}\r\n\r\n".encode())
    buf.write(file_bytes)
    buf.write(b"\r\n")

    buf.write(f"--{boundary}--\r\n".encode())
    return buf.getvalue(), ctype


def upload_csv(url: str, auth_header: str, instance_id: str,
               csv_bytes: bytes, filename: str, env_name: str) -> tuple[int, str]:
    """
    POST a CSV file to the Concert upload_files endpoint.

    Returns (http_status, response_text).
    """
    metadata   = json.dumps({"env_name": env_name})
    body, ctype = encode_multipart(
        fields=[
            ("data_type", "certificate"),
            ("metadata",  metadata),
        ],
        file_field    = "filename",
        filename      = filename,
        file_bytes    = csv_bytes,
        content_type  = "text/csv",
    )

    headers = {
        "Authorization": auth_header,
        "InstanceID":    instance_id,
        "Accept":        "application/json",
        "Content-Type":  ctype,
    }
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, context=make_ssl_ctx()) as resp:
            raw = resp.read()
            return resp.status, raw.decode(errors="replace")
    except urllib.error.HTTPError as exc:
        raw = b""
        try:
            raw = exc.read()
        except Exception:
            pass
        return exc.code, raw.decode(errors="replace")
    except urllib.error.URLError as exc:
        die(f"Upload request failed: {exc.reason}")


def poll_certificates_visible(
    serial_numbers: set,
    auth_header: str,
    instance_id: str,
    timeout: int,
    interval: int,
) -> tuple[bool, set, set]:
    """
    Poll GET /concert/core/api/v1/certificates until all serial numbers from
    the uploaded CSV appear in Concert, or until timeout.

    Concert's ingestion pipeline is asynchronous: the 202 only confirms the
    file was staged in object storage.  A background processor reads the file,
    validates it, and inserts the records.  There is no public status endpoint
    to track this — the only reliable signal is whether the data appears.

    Returns (all_found, found_serials, missing_serials).
    """
    certs_url = f"{CONCERT_BASE}{CERTS_PATH}"
    headers   = {
        "Authorization": auth_header,
        "InstanceID":    instance_id,
        "Accept":        "application/json",
    }

    deadline   = time.time() + timeout
    attempt    = 0
    http_status = 0
    raw_text    = ""

    while time.time() < deadline:
        attempt += 1
        req = urllib.request.Request(certs_url, headers=headers, method="GET")
        try:
            with urllib.request.urlopen(req, context=make_ssl_ctx()) as resp:
                http_status = resp.status
                raw_bytes   = resp.read()
                raw_text    = raw_bytes.decode(errors="replace")
                body        = json.loads(raw_text) if raw_text else {}
        except urllib.error.HTTPError as exc:
            http_status = exc.code
            raw_text    = exc.read().decode(errors="replace")
            try:
                body = json.loads(raw_text)
            except Exception:
                body = {}
        except urllib.error.URLError as exc:
            http_status = 0
            raw_text    = str(exc.reason)
            body        = {}

        # On first attempt, always print the raw response to aid debugging
        if attempt == 1:
            print()
            print(f"      [debug] GET {certs_url}")
            print(f"      [debug] HTTP {http_status}  response (first 400 chars):")
            print(f"      [debug] {raw_text[:400]}")
            print()

        # Extract the list of certificates from response — Concert wraps in
        # {"certificates": [...]} or returns a bare list
        cert_list = body if isinstance(body, list) else body.get("certificates", [])

        # Build a set of serial numbers already in Concert
        # Concert stores serial as hex uppercase; normalise both sides
        existing = {
            str(c.get("serial_number", "") or c.get("serialNumber", "")).upper().lstrip("0")
            for c in cert_list
        }

        found   = {s.upper().lstrip("0") for s in serial_numbers} & existing
        missing = {s.upper().lstrip("0") for s in serial_numbers} - existing

        remaining = max(0, int(deadline - time.time()))
        print(
            f"      [poll {attempt:>2}] HTTP {http_status} "
            f"found {len(found)}/{len(serial_numbers)} cert(s)  "
            f"(timeout in {remaining}s)  ",
            end="\r", flush=True,
        )

        if not missing:
            print()
            return True, found, set()

        time.sleep(interval)

    print()
    found   = {s.upper().lstrip("0") for s in serial_numbers} & existing
    missing = {s.upper().lstrip("0") for s in serial_numbers} - existing
    return False, found, missing


# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

print("=" * 64)
print("  IBM Concert 3.0.x — Certificate Upload")
print("=" * 64)
print(f"  Concert URL   : {CONCERT_URL}")
print(f"  CSV File      : {CSV_FILE}")
print(f"  Auth mode     : {'API key (Mode B)' if CONCERT_API_KEY else 'Automated JWT (Mode A)'}")
if CONCERT_ENV_NAME:
    print(f"  Env name      : {CONCERT_ENV_NAME} (override — all rows)")
else:
    print(f"  Env name      : derived from 'Namespace' column per group")
print(f"  Skip TLS      : {CONCERT_SKIP_TLS}")
print(f"  Poll timeout  : {CONCERT_POLL_TIMEOUT}s  (interval: {CONCERT_POLL_INTERVAL}s)")
print()

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------

if not CONCERT_URL:
    die("CONCERT_URL is not set.\n"
        "  e.g. export CONCERT_URL=https://concert-concert.apps.<cluster>/concert")

if not os.path.isfile(CSV_FILE):
    die(f"CSV file '{CSV_FILE}' not found.")

# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------

PLATFORM_JWT = ""
INSTANCE_ID  = ""

if CONCERT_API_KEY:
    # ------------------------------------------------------------------
    # Mode B — pre-supplied ZenApiKey; instance ID must come from env or
    # be discovered via oc (if oc is available).
    # ------------------------------------------------------------------
    print("Auth: Using pre-supplied API key (Mode B) ...")
    PLATFORM_JWT  = CONCERT_API_KEY   # used as ZenApiKey below
    AUTH_HEADER   = f"ZenApiKey {CONCERT_API_KEY}"

    INSTANCE_ID = os.environ.get("CONCERT_INSTANCE_ID", "")
    if not INSTANCE_ID:
        # Try to read it from OpenShift if oc is available
        res = subprocess.run(
            ["oc", "get", "configmap", "solis-account-instances-cm",
             "-n", os.environ.get("CONCERT_HUB_NS", "concert-hub"),
             "-o", "jsonpath={.data}"],
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
            except Exception:
                pass

    if not INSTANCE_ID:
        die("CONCERT_INSTANCE_ID is not set and could not be read from the cluster.\n"
            "  Set it with: export CONCERT_INSTANCE_ID=<instance-id>")

    ok(f"API key auth ready. Instance ID: {INSTANCE_ID}")

else:
    # ------------------------------------------------------------------
    # Mode A — automated Hub-signed platform JWT
    # ------------------------------------------------------------------
    if not CONCERT_HUB_URL:
        die("CONCERT_HUB_URL is not set.\n"
            "  Run: oc get routes -n concert-hub\n"
            "  e.g. export CONCERT_HUB_URL=https://solis-hub-concert-hub.apps.<cluster>")
    if not CONCERT_USERNAME:
        die("CONCERT_USERNAME is not set.")
    if not CONCERT_PASSWORD:
        die("CONCERT_PASSWORD is not set.")

    res = subprocess.run(["oc", "whoami"], capture_output=True, text=True)
    if res.returncode != 0:
        die("Not logged in to OpenShift. Run 'oc login' first.")
    print(f"  OCP user      : {res.stdout.strip()}")
    print()

    # Step 1 — Keycloak pod
    print("Step 1: Locating Keycloak pod ...")
    KC_POD = oc_get_pod(CONCERT_HUB_NS, "ibm-solis-embedded-keycloak-")
    if not KC_POD:
        die(f"Keycloak pod not found in namespace '{CONCERT_HUB_NS}'.")
    ok(f"Keycloak pod: {KC_POD}")

    # Step 2 — KC bootstrap credentials
    print("Step 2: Retrieving Keycloak bootstrap credentials ...")
    KC_ADMIN_USER = oc_exec(CONCERT_HUB_NS, KC_POD,
                            'printf "%s" "${KC_BOOTSTRAP_ADMIN_USERNAME:-}"')
    KC_ADMIN_PASS = oc_exec(CONCERT_HUB_NS, KC_POD,
                            'printf "%s" "${KC_BOOTSTRAP_ADMIN_PASSWORD:-}"')
    if not KC_ADMIN_USER or not KC_ADMIN_PASS:
        die("Keycloak bootstrap credentials not available in pod environment.")
    ok(f"KC bootstrap admin: {KC_ADMIN_USER}")

    # Steps 3–5 — port-forward to Hub gateway for Keycloak admin API
    # (master realm /token and /admin are not exposed on the external route)
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

        # Step 4 — concert-client secret
        print("Step 4: Retrieving concert-client secret ...")
        st, clients = api_request(
            "GET", f"{KC_LOCAL_URL}/admin/realms/{CONCERT_REALM}/clients?clientId=concert-client",
            KC_ADMIN_TOKEN)
        if not isinstance(clients, list) or not clients:
            die(f"concert-client not found (HTTP {st}).")
        client_uuid = clients[0].get("id", "")
        st, sec = api_request(
            "GET", f"{KC_LOCAL_URL}/admin/realms/{CONCERT_REALM}/clients/{client_uuid}/client-secret",
            KC_ADMIN_TOKEN)
        CLIENT_SECRET = sec.get("value", "")
        if not CLIENT_SECRET:
            die(f"concert-client secret not retrieved (HTTP {st}).")
        ok(f"concert-client secret retrieved (UUID: {client_uuid}).")

        # Step 5 — validate Concert user
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

    # Step 6 — Hub-signed platform JWT
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

    print(f"  Starting port-forward ibm-solis-core-svc:{LOCAL_PORT} ...")
    pf = subprocess.Popen(
        ["oc", "port-forward", "-n", CONCERT_HUB_NS,
         "svc/ibm-solis-core-svc", f"{LOCAL_PORT}:8000"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    try:
        if not wait_for_port(LOCAL_PORT, timeout=15):
            pf.terminate()
            die(f"Port-forward not ready after 15 s.")
        ok(f"Port-forward ready on localhost:{LOCAL_PORT}.")

        st, body = http_post_json_local(
            LOCAL_PORT, "/platform_hub/core/api/v1/handle_login",
            {"secret": SOLIS_SECRET}, {"username": CONCERT_USERNAME})

        PLATFORM_JWT = body.get("token", "")
        if not PLATFORM_JWT or st != 200:
            die(f"handle_login failed (HTTP {st}): {json.dumps(body)}")
        ok(f"Platform JWT obtained (HTTP {st}, length: {len(PLATFORM_JWT)}).")
    finally:
        pf.terminate(); pf.wait()

    AUTH_HEADER = f"Bearer {PLATFORM_JWT}"

    # Step 7 — instance ID
    print("Step 7: Reading Concert instance ID ...")
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
        die(f"Concert instance ID not found. Raw: {res.stdout[:300]}")
    ok(f"Concert instance ID: {INSTANCE_ID}")

# ---------------------------------------------------------------------------
# Read and group the CSV by Namespace (or CONCERT_ENV_NAME override)
# ---------------------------------------------------------------------------

print()
print("=" * 64)
print("  Reading certificate CSV")
print("=" * 64)

with open(CSV_FILE, newline="", encoding="utf-8") as fh:
    raw_content = fh.read()

reader    = csv.DictReader(io.StringIO(raw_content))
fieldnames = reader.fieldnames or []

if not fieldnames:
    die(f"CSV file '{CSV_FILE}' appears to be empty or has no header row.")

# Namespace column is used as env_name unless overridden
has_namespace = "Namespace" in fieldnames

if not CONCERT_ENV_NAME and not has_namespace:
    die("CSV has no 'Namespace' column and CONCERT_ENV_NAME is not set.\n"
        "  Set: export CONCERT_ENV_NAME=<environment-name>")

info(f"CSV columns: {', '.join(fieldnames)}")

# Group rows by their env_name
groups: dict[str, list[dict]] = {}
row_count = 0
for row in reader:
    env_name = CONCERT_ENV_NAME if CONCERT_ENV_NAME else row.get("Namespace", "").strip()
    if not env_name:
        env_name = "default"
    groups.setdefault(env_name, []).append(row)
    row_count += 1

ok(f"Read {row_count} certificate rows across "
   f"{len(groups)} environment group(s): {list(groups.keys())}")

# ---------------------------------------------------------------------------
# Upload — one request per env_name group
# ---------------------------------------------------------------------------

print()
print("=" * 64)
print("  Uploading certificates to Concert")
print("=" * 64)
print(f"  Endpoint: {CONCERT_BASE}{UPLOAD_PATH}")
print()

upload_url   = f"{CONCERT_BASE}{UPLOAD_PATH}"
total_groups = len(groups)
succeeded    = 0
failed       = 0

for group_idx, (env_name, rows) in enumerate(groups.items(), start=1):
    print(f"  [{group_idx}/{total_groups}] env_name='{env_name}'  ({len(rows)} row(s))")

    # Rebuild a CSV in memory for just this group (preserving original header)
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=fieldnames,
                            lineterminator="\r\n", extrasaction="ignore")
    writer.writeheader()
    writer.writerows(rows)
    group_csv_bytes = buf.getvalue().encode("utf-8")

    # Derive a safe filename for this group
    safe_env = "".join(c if c.isalnum() or c in "-_" else "_" for c in env_name)
    upload_filename = f"certificates-{safe_env}.csv"

    info(f"Uploading '{upload_filename}' ({len(group_csv_bytes)} bytes) ...")

    http_status, response_text = upload_csv(
        url         = upload_url,
        auth_header = AUTH_HEADER,
        instance_id = INSTANCE_ID,
        csv_bytes   = group_csv_bytes,
        filename    = upload_filename,
        env_name    = env_name,
    )

    # Parse response body
    resp_msg  = response_text.strip()
    resp_json = {}
    try:
        resp_json = json.loads(response_text)
        resp_msg  = json.dumps(resp_json, indent=2)
    except Exception:
        pass

    if http_status in (200, 201, 202):
        ok(f"Upload accepted (HTTP {http_status}).")
        if resp_msg:
            for line in resp_msg.splitlines():
                print(f"          {line}")

        # ------------------------------------------------------------------
        # Verify processing: poll GET /concert/core/api/v1/certificates until
        # the uploaded serial numbers appear in Concert.
        #
        # Background: Concert's ingestion pipeline is fully asynchronous.
        # The 202 response only confirms the file was staged in MinIO object
        # storage.  A background worker (roja-pipeline) then reads the file,
        # validates it, and persists the data to the appdb.  There is no
        # public status polling endpoint — the only reliable confirmation is
        # whether the certificate records actually appear in the API.
        # ------------------------------------------------------------------
        serial_numbers = {
            str(r.get("Serial Number", "")).strip()
            for r in rows
            if r.get("Serial Number", "").strip()
        }

        if serial_numbers:
            print()
            info(f"Verifying {len(serial_numbers)} certificate(s) appear in Concert ...")
            info(f"(polling every {CONCERT_POLL_INTERVAL}s, timeout {CONCERT_POLL_TIMEOUT}s)")

            all_found, found_set, missing_set = poll_certificates_visible(
                serial_numbers = serial_numbers,
                auth_header    = AUTH_HEADER,
                instance_id    = INSTANCE_ID,
                timeout        = CONCERT_POLL_TIMEOUT,
                interval       = CONCERT_POLL_INTERVAL,
            )

            if all_found:
                ok(f"All {len(found_set)} certificate(s) confirmed in Concert.")
                succeeded += 1
            else:
                if found_set:
                    ok(f"{len(found_set)} of {len(serial_numbers)} certificate(s) "
                       f"found in Concert.")
                print(f"      WARN: {len(missing_set)} certificate(s) not yet visible "
                      f"after {CONCERT_POLL_TIMEOUT}s.")
                print(f"            This is normal — the background pipeline may still")
                print(f"            be running.  Refresh the Concert UI in 2–3 minutes.")
                print(f"            Missing serial(s): "
                      f"{', '.join(sorted(missing_set)[:3])}"
                      f"{'...' if len(missing_set) > 3 else ''}")
                # Not a hard failure — upload was accepted (202)
                succeeded += 1
        else:
            # No serial numbers to verify (e.g. all rows were empty)
            info("No serial numbers to verify — skipping poll.")
            succeeded += 1

    else:
        print(f"      ERROR: HTTP {http_status} for env_name='{env_name}'")
        for line in resp_msg.splitlines():
            print(f"          {line}")
        failed += 1

    print()

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print("=" * 64)
print("  Summary")
print("=" * 64)
print(f"  Concert URL      : {CONCERT_URL}")
print(f"  Instance ID      : {INSTANCE_ID}")
print(f"  CSV File         : {CSV_FILE}")
print(f"  Certificate rows : {row_count}")
print(f"  Upload groups    : {total_groups}")
print(f"  Succeeded        : {succeeded}")
print(f"  Failed           : {failed}")
print("=" * 64)

if failed:
    sys.exit(1)

print()
print("All certificate uploads completed successfully.")
