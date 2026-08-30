#!/usr/bin/env python3
"""
IBM Concert 3.0.x - Upload Trivy CycloneDX image vulnerability scans
====================================================================

This script mirrors the following IBM Concert UI workflow:

    Vulnerability scan : Image
    Scan source        : Trivy
    Application        : Existing application
    Application name   : Read from sbom-apps.csv

Each CycloneDX JSON file is uploaded to:

    POST /concert/ingestion/api/v1/upload_files

with these multipart fields:

    data_type = image_scan
    metadata  = {
        "scanner_name": "Trivy",
        "application_name": "<existing-application>",
        "application_version": "<existing-application-version>"
    }
    filename  = <CycloneDX JSON file>

Authentication uses the API key generated in IBM Concert:

    Authorization: C_API_KEY <api-key>
    InstanceID: <instance-id>

Required environment variables
------------------------------

    CONCERT_URL
        Concert URL, for example:
        https://concert-concert.apps.example.com/concert

    CONCERT_API_KEY
        API key generated from the Concert UI.

    CONCERT_INSTANCE_ID
        Concert instance ID shown with the API key.

Optional environment variables
------------------------------

    CONCERT_SKIP_TLS
        Set to true only for a disposable lab with an untrusted route
        certificate. Default: false.

    CONCERT_CA_BUNDLE
        Path to a trusted PEM CA bundle. Preferred over CONCERT_SKIP_TLS.

    CONCERT_UPLOAD_DELAY
        Seconds to pause between accepted uploads. Default: 10.

    CONCERT_APP_VERSION
        Version of the existing Concert application. This can instead be
        supplied with --app-version or an optional app_version CSV column.

App mapping CSV
---------------

The default mapping file is sbom-apps.csv:

    file,app_name
    *,Retail_App_Sunil

Supply the existing application version separately:

    export CONCERT_APP_VERSION=1.0.0

or include an optional third CSV column:

    file,app_name,app_version
    *,Retail_App_Sunil,1.0.0

The wildcard maps every discovered *.cdx.json file to the same existing
Concert application. Explicit per-file mappings are also supported:

    file,app_name
    retail-backend.cdx.json,Retail_App_Sunil
    retail-frontend.cdx.json,Retail_App_Sunil

Usage
-----

    python3 upload-sbom.py
    python3 upload-sbom.py --apps-csv sbom-apps.csv
    python3 upload-sbom.py --app-version 1.0.0
    python3 upload-sbom.py retail-backend.cdx.json
    python3 upload-sbom.py --app-name Retail_App_Sunil retail-backend.cdx.json

For multiple scans that contain common packages, IBM recommends waiting for
the previous ingestion event to complete before uploading the next file. Use
--confirm-between to pause after each accepted upload while you confirm its
event in Concert's Event log.

Exit codes
----------

    0  Every upload request was accepted.
    1  Validation, authentication, preflight, or upload failure.

HTTP 202 means accepted for asynchronous processing. It does not prove that
the background ingestion pipeline completed. The script prints every returned
event ID so the final state can be checked in Concert's Event log.
"""

from __future__ import annotations

import argparse
import csv
import glob
import io
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple


UPLOAD_PATH = "/concert/ingestion/api/v1/upload_files"
APPLICATIONS_PATH = "/concert/core/api/v1/applications"
SUPPORTED_CYCLONEDX_VERSIONS = {"1.3", "1.4", "1.5", "1.6"}
TRUE_VALUES = {"1", "true", "yes", "y", "on"}


class ConcertError(RuntimeError):
    """A user-actionable validation or Concert API error."""


@dataclass(frozen=True)
class Config:
    base_url: str
    api_key: str
    instance_id: str
    skip_tls: bool
    ca_bundle: str
    scanner_name: str
    app_version_override: str
    upload_delay: int
    check_applications: bool
    confirm_between: bool
    require_vulnerabilities: bool


@dataclass(frozen=True)
class HttpResult:
    status: int
    body: bytes
    headers: Mapping[str, str]

    @property
    def text(self) -> str:
        return self.body.decode("utf-8", errors="replace")

    def json_or_none(self) -> Any:
        if not self.body:
            return None
        try:
            return json.loads(self.text)
        except json.JSONDecodeError:
            return None


@dataclass(frozen=True)
class ScanFile:
    path: Path
    app_name: str
    app_version: str
    content: bytes
    spec_version: str
    component_count: int
    vulnerability_count: int
    subject_name: str


@dataclass(frozen=True)
class TrackingDetails:
    event_ids: List[str]
    record_paths: List[str]


def env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in TRUE_VALUES


def nonnegative_int(value: str, label: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise ConcertError(f"{label} must be an integer; received {value!r}.") from exc
    if parsed < 0:
        raise ConcertError(f"{label} must be zero or greater; received {parsed}.")
    return parsed


def normalize_base_url(raw_url: str) -> str:
    value = raw_url.strip().rstrip("/")
    if not value:
        raise ConcertError(
            "CONCERT_URL is not set. Example: "
            "export CONCERT_URL=https://concert-concert.apps.example.com/concert"
        )

    parsed = urllib.parse.urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ConcertError(f"CONCERT_URL is not a valid HTTP(S) URL: {value!r}")

    # Concert API paths start at /concert. Retain only scheme and authority to
    # avoid producing /concert/concert when CONCERT_URL already ends in it.
    return f"{parsed.scheme}://{parsed.netloc}"


def load_config(args: argparse.Namespace) -> Config:
    api_key = os.environ.get("CONCERT_API_KEY", "").strip()
    instance_id = os.environ.get("CONCERT_INSTANCE_ID", "").strip()
    ca_bundle = os.environ.get("CONCERT_CA_BUNDLE", "").strip()

    if not api_key:
        raise ConcertError(
            "CONCERT_API_KEY is not set. Generate an API key in Concert and export it."
        )
    if not instance_id:
        raise ConcertError(
            "CONCERT_INSTANCE_ID is not set. Export the instance ID shown with the API key."
        )
    if ca_bundle and not Path(ca_bundle).is_file():
        raise ConcertError(f"CONCERT_CA_BUNDLE does not exist: {ca_bundle!r}")

    delay_raw = (
        str(args.delay)
        if args.delay is not None
        else os.environ.get("CONCERT_UPLOAD_DELAY", "10")
    )

    return Config(
        base_url=normalize_base_url(os.environ.get("CONCERT_URL", "")),
        api_key=api_key,
        instance_id=instance_id,
        skip_tls=env_bool("CONCERT_SKIP_TLS"),
        ca_bundle=ca_bundle,
        scanner_name=args.scanner_name.strip() or "Trivy",
        app_version_override=(
            args.app_version.strip()
            or os.environ.get("CONCERT_APP_VERSION", "").strip()
        ),
        upload_delay=nonnegative_int(delay_raw, "upload delay"),
        check_applications=not args.skip_application_check,
        confirm_between=args.confirm_between,
        require_vulnerabilities=args.require_vulnerabilities,
    )


def ssl_context(config: Config) -> ssl.SSLContext:
    context = ssl.create_default_context()
    if config.ca_bundle:
        context.load_verify_locations(cafile=config.ca_bundle)
    if config.skip_tls:
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
    return context


def api_headers(config: Config, extra: Optional[Mapping[str, str]] = None) -> Dict[str, str]:
    headers = {
        "Authorization": f"C_API_KEY {config.api_key}",
        "InstanceID": config.instance_id,
        "Accept": "application/json",
    }
    if extra:
        headers.update(extra)
    return headers


def request(
    method: str,
    url: str,
    config: Config,
    *,
    body: Optional[bytes] = None,
    headers: Optional[Mapping[str, str]] = None,
) -> HttpResult:
    req = urllib.request.Request(
        url,
        data=body,
        headers=dict(headers or api_headers(config)),
        method=method,
    )
    try:
        with urllib.request.urlopen(req, context=ssl_context(config), timeout=60) as response:
            return HttpResult(
                status=response.status,
                body=response.read(),
                headers=dict(response.headers.items()),
            )
    except urllib.error.HTTPError as exc:
        return HttpResult(
            status=exc.code,
            body=exc.read(),
            headers=dict(exc.headers.items()) if exc.headers else {},
        )
    except urllib.error.URLError as exc:
        reason = getattr(exc, "reason", exc)
        raise ConcertError(f"Cannot reach {url}: {reason}") from exc
    except TimeoutError as exc:
        raise ConcertError(f"Request timed out: {url}") from exc


def response_summary(result: HttpResult, limit: int = 2000) -> str:
    payload = result.json_or_none()
    if payload is not None:
        text = json.dumps(payload, indent=2, ensure_ascii=False)
    else:
        text = result.text.strip() or "<empty response>"
    if len(text) > limit:
        return text[:limit] + "\n... response truncated ..."
    return text


def extract_collection(payload: Any, preferred_key: str) -> List[Dict[str, Any]]:
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if not isinstance(payload, dict):
        return []

    preferred = payload.get(preferred_key)
    if isinstance(preferred, list):
        return [item for item in preferred if isinstance(item, dict)]

    for key in ("items", "data", "results"):
        value = payload.get(key)
        if isinstance(value, list):
            return [item for item in value if isinstance(item, dict)]
        if isinstance(value, dict):
            nested = extract_collection(value, preferred_key)
            if nested:
                return nested

    return []


def application_name(item: Mapping[str, Any]) -> str:
    for key in ("name", "app_name", "application_name", "component_name"):
        value = str(item.get(key, "")).strip()
        if value:
            return value
    return ""


def list_visible_applications(config: Config) -> Set[str]:
    query = urllib.parse.urlencode({"page_size": 2000, "page_number": 1})
    url = f"{config.base_url}{APPLICATIONS_PATH}?{query}"
    result = request("GET", url, config)
    if result.status != 200:
        raise ConcertError(
            f"Application preflight returned HTTP {result.status}.\n"
            f"{response_summary(result)}"
        )

    return {
        name
        for item in extract_collection(result.json_or_none(), "applications")
        if (name := application_name(item))
    }


def ensure_applications_visible(config: Config, required: Iterable[str]) -> None:
    required_names = sorted(set(required))
    visible = list_visible_applications(config)
    visible_casefold = {name.casefold(): name for name in visible}

    missing: List[str] = []
    case_mismatches: List[Tuple[str, str]] = []
    for requested in required_names:
        if requested in visible:
            continue
        canonical = visible_casefold.get(requested.casefold())
        if canonical:
            case_mismatches.append((requested, canonical))
        else:
            missing.append(requested)

    if case_mismatches:
        details = ", ".join(
            f"{requested!r} should be {canonical!r}"
            for requested, canonical in case_mismatches
        )
        raise ConcertError(
            "Application names are case-sensitive for upload metadata: " + details
        )

    if missing:
        available = ", ".join(sorted(visible)) if visible else "<none visible>"
        raise ConcertError(
            "The following existing application(s) do not exist or are not visible "
            f"to this API key: {', '.join(missing)}.\n"
            f"Visible applications: {available}\n"
            "Create the application or grant the API-key owner access before uploading."
        )


def load_apps_csv(path: Path) -> Tuple[Dict[str, str], str, str]:
    if not path.is_file():
        raise ConcertError(
            f"Apps CSV not found: {path}\n"
            "Create it with columns file,app_name. Example: *,Retail_App_Sunil"
        )

    explicit: Dict[str, str] = {}
    wildcard = ""
    versions: Set[str] = set()
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        fieldnames = set(reader.fieldnames or [])
        missing = {"file", "app_name"} - fieldnames
        if missing:
            raise ConcertError(
                f"Apps CSV {str(path)!r} is missing columns: {', '.join(sorted(missing))}"
            )

        for row_number, row in enumerate(reader, start=2):
            filename = str(row.get("file", "")).strip()
            app_name = str(row.get("app_name", "")).strip()
            app_version = str(row.get("app_version", "")).strip()
            if not filename and not app_name:
                continue
            if not filename or not app_name:
                raise ConcertError(
                    f"Apps CSV row {row_number} must contain both file and app_name."
                )
            if app_version:
                versions.add(app_version)
            if filename == "*":
                if wildcard and wildcard != app_name:
                    raise ConcertError("Apps CSV contains conflicting wildcard mappings.")
                wildcard = app_name
                continue

            basename = Path(filename).name
            previous = explicit.get(basename)
            if previous and previous != app_name:
                raise ConcertError(
                    f"Apps CSV maps {basename!r} to more than one application."
                )
            explicit[basename] = app_name

    if not explicit and not wildcard:
        raise ConcertError(f"Apps CSV {str(path)!r} contains no usable mappings.")
    if len(versions) > 1:
        raise ConcertError(
            "Apps CSV contains multiple app_version values. Run the uploader once "
            "per application version, or use one consistent app_version value."
        )
    csv_version = next(iter(versions), "")
    return explicit, wildcard, csv_version


def resolve_files(
    cli_files: Sequence[str],
    apps_csv: Path,
    explicit: Mapping[str, str],
    wildcard: str,
) -> List[Path]:
    if cli_files:
        paths = [Path(value).expanduser() for value in cli_files]
    elif explicit:
        paths = [apps_csv.parent / filename for filename in explicit]
    elif wildcard:
        paths = [Path(value) for value in sorted(glob.glob(str(apps_csv.parent / "*.cdx.json")))]
    else:
        paths = []

    if not paths:
        raise ConcertError(
            "No *.cdx.json files were found. Pass file names or add explicit rows to sbom-apps.csv."
        )

    resolved: List[Path] = []
    seen: Set[Path] = set()
    for path in paths:
        candidate = path.resolve()
        if candidate in seen:
            continue
        if not candidate.is_file():
            raise ConcertError(f"SBOM file does not exist: {path}")
        seen.add(candidate)
        resolved.append(candidate)
    return resolved


def mapped_application(
    path: Path,
    explicit: Mapping[str, str],
    wildcard: str,
    override: str,
) -> str:
    app_name = override.strip() or explicit.get(path.name, "") or wildcard
    if not app_name:
        raise ConcertError(
            f"No app_name mapping exists for {path.name!r}. Add an exact CSV row, "
            "add a wildcard row, or pass --app-name."
        )
    return app_name


def load_scan(
    path: Path,
    app_name: str,
    app_version: str,
    require_vulnerabilities: bool,
) -> ScanFile:
    try:
        content = path.read_bytes()
    except OSError as exc:
        raise ConcertError(f"Cannot read {path}: {exc}") from exc

    try:
        document = json.loads(content.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ConcertError(f"{path.name!r} is not valid UTF-8 JSON: {exc}") from exc

    if not isinstance(document, dict):
        raise ConcertError(f"{path.name!r} must contain a JSON object.")
    if document.get("bomFormat") != "CycloneDX":
        raise ConcertError(
            f"{path.name!r} has bomFormat={document.get('bomFormat')!r}; expected 'CycloneDX'."
        )

    spec_version = str(document.get("specVersion", "")).strip()
    if spec_version not in SUPPORTED_CYCLONEDX_VERSIONS:
        raise ConcertError(
            f"{path.name!r} has unsupported CycloneDX specVersion={spec_version!r}. "
            "Use CycloneDX 1.6 or an older supported version."
        )

    components = document.get("components", [])
    if not isinstance(components, list):
        raise ConcertError(f"{path.name!r} has a non-array components field.")

    vulnerabilities = document.get("vulnerabilities", [])
    if vulnerabilities is None:
        vulnerabilities = []
    if not isinstance(vulnerabilities, list):
        raise ConcertError(f"{path.name!r} has a non-array vulnerabilities field.")
    if require_vulnerabilities and not vulnerabilities:
        raise ConcertError(
            f"{path.name!r} contains no vulnerabilities. Generate it with Trivy "
            "vulnerability scanning enabled or omit --require-vulnerabilities."
        )

    metadata = document.get("metadata", {})
    subject_name = ""
    if isinstance(metadata, dict):
        component = metadata.get("component", {})
        if isinstance(component, dict):
            subject_name = str(component.get("name", "")).strip()

    # Upload the original bytes without rewriting valid CycloneDX 1.6 fields.
    return ScanFile(
        path=path,
        app_name=app_name,
        app_version=app_version,
        content=content,
        spec_version=spec_version,
        component_count=len(components),
        vulnerability_count=len(vulnerabilities),
        subject_name=subject_name,
    )


def write_multipart_field(buffer: io.BytesIO, boundary: str, name: str, value: str) -> None:
    buffer.write(f"--{boundary}\r\n".encode("utf-8"))
    buffer.write(
        f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode("utf-8")
    )
    buffer.write(value.encode("utf-8"))
    buffer.write(b"\r\n")


def write_multipart_file(
    buffer: io.BytesIO,
    boundary: str,
    field_name: str,
    filename: str,
    content: bytes,
) -> None:
    safe_filename = filename.replace('"', "_").replace("\r", "_").replace("\n", "_")
    buffer.write(f"--{boundary}\r\n".encode("utf-8"))
    buffer.write(
        (
            f'Content-Disposition: form-data; name="{field_name}"; '
            f'filename="{safe_filename}"\r\n'
        ).encode("utf-8")
    )
    buffer.write(b"Content-Type: application/json\r\n\r\n")
    buffer.write(content)
    buffer.write(b"\r\n")


def upload_scan(config: Config, scan: ScanFile) -> HttpResult:
    boundary = f"----concert-{uuid.uuid4().hex}"
    metadata = json.dumps(
        {
            "scanner_name": config.scanner_name,
            "application_name": scan.app_name,
            "application_version": scan.app_version,
        },
        separators=(",", ":"),
    )

    buffer = io.BytesIO()
    write_multipart_field(buffer, boundary, "data_type", "image_scan")
    write_multipart_field(buffer, boundary, "metadata", metadata)
    write_multipart_file(
        buffer,
        boundary,
        "filename",
        scan.path.name,
        scan.content,
    )
    buffer.write(f"--{boundary}--\r\n".encode("utf-8"))

    headers = api_headers(
        config,
        {"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    return request(
        "POST",
        f"{config.base_url}{UPLOAD_PATH}",
        config,
        body=buffer.getvalue(),
        headers=headers,
    )


def string_list(value: Any) -> List[str]:
    if isinstance(value, list):
        return [str(item) for item in value if str(item).strip()]
    if value is None or value == "":
        return []
    return [str(value)]


def extract_tracking_details(result: HttpResult) -> TrackingDetails:
    payload = result.json_or_none()
    if not isinstance(payload, dict):
        return TrackingDetails(event_ids=[], record_paths=[])

    event_ids: List[str] = []
    record_paths: List[str] = []
    for key in ("event_ids", "eventIds", "event_id", "eventId"):
        if key in payload:
            event_ids.extend(string_list(payload.get(key)))
    for key in ("record_paths", "recordPaths", "record_path", "recordPath"):
        if key in payload:
            record_paths.extend(string_list(payload.get(key)))

    return TrackingDetails(
        event_ids=list(dict.fromkeys(event_ids)),
        record_paths=list(dict.fromkeys(record_paths)),
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="upload-sbom.py",
        description=(
            "Upload Trivy CycloneDX JSON files as IBM Concert image vulnerability scans."
        ),
    )
    parser.add_argument(
        "files",
        nargs="*",
        help=(
            "CycloneDX JSON files. With no files, explicit CSV rows are used; "
            "a wildcard-only CSV discovers *.cdx.json beside the CSV."
        ),
    )
    parser.add_argument(
        "--apps-csv",
        default="sbom-apps.csv",
        help="File-to-existing-application mapping (default: sbom-apps.csv).",
    )
    parser.add_argument(
        "--app-name",
        default="",
        help="Override CSV application mapping for every selected file.",
    )
    parser.add_argument(
        "--scanner-name",
        default="Trivy",
        help="Concert scanner_name metadata value (default: Trivy).",
    )
    parser.add_argument(
        "--app-version",
        default="",
        help=(
            "Existing Concert application version. Overrides CONCERT_APP_VERSION "
            "and the optional app_version CSV column."
        ),
    )
    parser.add_argument(
        "--skip-application-check",
        action="store_true",
        help="Skip validation that every mapped existing application is visible.",
    )
    parser.add_argument(
        "--require-vulnerabilities",
        action="store_true",
        help="Reject CycloneDX files whose vulnerabilities array is empty or absent.",
    )
    parser.add_argument(
        "--delay",
        type=int,
        default=None,
        help=(
            "Seconds to pause between accepted uploads; overrides "
            "CONCERT_UPLOAD_DELAY (default: 10)."
        ),
    )
    parser.add_argument(
        "--confirm-between",
        action="store_true",
        help=(
            "Prompt after each accepted upload so its Event log entry can be "
            "confirmed Complete before continuing."
        ),
    )
    return parser


def print_banner(config: Config, apps_csv: Path, scans: Sequence[ScanFile]) -> None:
    print("=" * 68)
    print("  IBM Concert 3.0.x - Trivy Image Vulnerability Scan Upload")
    print("=" * 68)
    print(f"  Concert API base : {config.base_url}")
    print("  Authentication   : C_API_KEY")
    print(f"  Instance ID      : {config.instance_id}")
    print("  Vulnerability    : Image")
    print(f"  Scan source      : {config.scanner_name}")
    print(
        "  App version      : "
        + ", ".join(sorted({scan.app_version for scan in scans}))
    )
    print(f"  Apps CSV         : {apps_csv}")
    print(f"  Application check: {'enabled' if config.check_applications else 'skipped'}")
    print(f"  TLS verification : {'DISABLED' if config.skip_tls else 'enabled'}")
    print(f"  Files            : {len(scans)}")
    print("=" * 68)


def run() -> int:
    args = build_parser().parse_args()
    config = load_config(args)
    apps_csv = Path(args.apps_csv).expanduser().resolve()
    explicit, wildcard, csv_version = load_apps_csv(apps_csv)
    app_version = config.app_version_override or csv_version
    if not app_version:
        raise ConcertError(
            "The existing application version is required by Concert for image "
            "scan uploads. Set one of:\n"
            "  export CONCERT_APP_VERSION=<existing-version>\n"
            "  python3 upload-sbom.py --app-version <existing-version>\n"
            "  add app_version to sbom-apps.csv"
        )
    paths = resolve_files(args.files, apps_csv, explicit, wildcard)

    scans: List[ScanFile] = []
    for path in paths:
        app_name = mapped_application(
            path,
            explicit,
            wildcard,
            args.app_name,
        )
        scans.append(
            load_scan(
                path,
                app_name,
                app_version,
                config.require_vulnerabilities,
            )
        )

    print_banner(config, apps_csv, scans)

    if config.skip_tls:
        print("WARNING: CONCERT_SKIP_TLS=true disables certificate verification.")
        print("         Use CONCERT_CA_BUNDLE outside a disposable lab.")
        print()

    print("Validated scan files:")
    for scan in scans:
        subject = f" subject={scan.subject_name!r}" if scan.subject_name else ""
        print(
            f"  {scan.path.name}: app={scan.app_name!r}, "
            f"app_version={scan.app_version!r}, "
            f"CycloneDX={scan.spec_version}, components={scan.component_count}, "
            f"vulnerabilities={scan.vulnerability_count}{subject}"
        )
        if scan.vulnerability_count == 0:
            print(
                "    WARNING: This file has no top-level vulnerabilities. "
                "It can be accepted, but no Trivy CVEs will appear from this scan."
            )
    print()

    if config.check_applications:
        required_apps = {scan.app_name for scan in scans}
        print("Checking that mapped existing applications are visible...")
        ensure_applications_visible(config, required_apps)
        print("  OK: " + ", ".join(sorted(required_apps)))
        print()

    print("Uploading scans sequentially...")
    print(f"  Endpoint : {config.base_url}{UPLOAD_PATH}")
    print("  Type     : image_scan")
    print(f"  Source   : {config.scanner_name}")
    print(f"  App ver. : {app_version}")
    print()

    accepted = 0
    failed = 0
    all_event_ids: List[str] = []

    if config.confirm_between and len(scans) > 1 and not sys.stdin.isatty():
        raise ConcertError("--confirm-between requires an interactive terminal.")

    for index, scan in enumerate(scans, start=1):
        print(
            f"[{index}/{len(scans)}] {scan.path.name} -> "
            f"{scan.app_name}:{scan.app_version} "
            f"({len(scan.content)} bytes)"
        )
        result = upload_scan(config, scan)

        if result.status in {200, 201, 202}:
            accepted += 1
            print(f"  ACCEPTED: HTTP {result.status}")
            tracking = extract_tracking_details(result)
            all_event_ids.extend(tracking.event_ids)
            if tracking.event_ids:
                for event_id in tracking.event_ids:
                    print(f"  Event ID   : {event_id}")
            else:
                print("  Event ID   : <not returned>")
            for record_path in tracking.record_paths:
                print(f"  Record path: {record_path}")

            if index < len(scans):
                if config.confirm_between:
                    answer = input(
                        "  Confirm the event is Complete in Concert, then press Enter "
                        "to continue (or enter q to stop): "
                    ).strip().lower()
                    if answer in {"q", "quit", "stop"}:
                        print("Stopped before uploading the remaining files.")
                        return 1
                elif config.upload_delay:
                    print(
                        f"  Waiting {config.upload_delay}s before the next request. "
                        "Use --confirm-between for Event log confirmation."
                    )
                    time.sleep(config.upload_delay)
        else:
            failed += 1
            print(f"  FAILED: HTTP {result.status}")
            print(response_summary(result))

        print()

    print("=" * 68)
    print("  Upload summary")
    print("=" * 68)
    print(f"  Files selected : {len(scans)}")
    print(f"  Accepted       : {accepted}")
    print(f"  Failed         : {failed}")
    if all_event_ids:
        print(f"  Event IDs      : {', '.join(dict.fromkeys(all_event_ids))}")
    print("=" * 68)

    if failed:
        print("One or more scan uploads were rejected.")
        return 1

    print("All upload requests were accepted for asynchronous processing.")
    print("Verify each Event ID in Concert: Administration -> Event log.")
    print("Then open the existing application and review its vulnerability data.")
    return 0


def main() -> int:
    try:
        return run()
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        return 130
    except ConcertError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
