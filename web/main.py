#!/usr/bin/env python3
"""fsbackup web UI — FastAPI + HTMX + Tailwind"""

import os
import secrets
import subprocess
import yaml
from datetime import date, datetime, timedelta
from pathlib import Path

from dotenv import load_dotenv
load_dotenv(Path(__file__).parent / ".env")

import boto3
import pam
from botocore.config import Config as BotoConfig
from botocore.exceptions import BotoCoreError, ClientError

from fastapi import FastAPI, Request, Form
from fastapi.responses import HTMLResponse, RedirectResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.middleware.sessions import SessionMiddleware

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

SNAPSHOT_ROOT = Path(os.environ.get("SNAPSHOT_ROOT", "/backup/snapshots"))
MIRROR_ROOT   = Path(os.environ.get("MIRROR_ROOT",   "/backup2/snapshots"))
TARGETS_FILE  = Path(os.environ.get("TARGETS_FILE",  "/etc/fsbackup/targets.yml"))

# Retention policy (days) per tier — used to compute expiration dates
RETENTION = {
    "daily":   14,
    "weekly":  8 * 7,
    "monthly": 366,
    "annual":  None,   # never expires
}

TIERS   = ["daily", "weekly", "monthly", "annual"]
CLASSES = ["class1", "class2", "class3"]

# S3
S3_BUCKET  = os.environ.get("S3_BUCKET",  "fsbackup-snapshots-SUFFIX")
S3_PROFILE = os.environ.get("S3_PROFILE", "fsbackup")
S3_REGION  = os.environ.get("S3_REGION",  "us-west-2")
PRESIGN_TTL = 3600  # seconds

# Point boto3 at the fsbackup user's credential store if not already set.
# This allows the app to run as any user (e.g. crash during dev) as long as
# that user has read ACL on the files.
_aws_creds_dir = "/var/lib/fsbackup/.aws"
os.environ.setdefault("AWS_SHARED_CREDENTIALS_FILE", f"{_aws_creds_dir}/credentials")
os.environ.setdefault("AWS_CONFIG_FILE",              f"{_aws_creds_dir}/config")


def s3_client():
    session = boto3.Session(profile_name=S3_PROFILE)
    return session.client("s3", region_name=S3_REGION, config=BotoConfig(signature_version="s3v4"))

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

SECRET_KEY   = os.environ.get("SECRET_KEY", secrets.token_hex(32))
AUTH_ENABLED = os.environ.get("AUTH_ENABLED", "true").lower() not in ("false", "0", "no")

app = FastAPI(title="fsbackup")
app.mount("/static", StaticFiles(directory=Path(__file__).parent / "static"), name="static")
templates = Jinja2Templates(directory=Path(__file__).parent / "templates")

_PUBLIC_PATHS = {"/login"}

@app.middleware("http")
async def require_login(request: Request, call_next):
    if AUTH_ENABLED and request.url.path not in _PUBLIC_PATHS and not request.url.path.startswith("/static/") and not request.session.get("user"):
        return RedirectResponse(url=f"/login?next={request.url.path}", status_code=302)
    response = await call_next(request)
    return response

# SessionMiddleware must be added AFTER require_login so it is outermost
# (Starlette middleware is LIFO — last added = first executed)
app.add_middleware(SessionMiddleware, secret_key=SECRET_KEY, session_cookie="fsbackup_session", max_age=86400)

# Use a custom TemplateResponse wrapper so every render gets `now`
_orig_response = templates.TemplateResponse
def _template_response(name, context, *args, **kwargs):
    context.setdefault("now", datetime.now())
    return _orig_response(name, context, *args, **kwargs)
templates.TemplateResponse = _template_response


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def parse_snapshot_date(tier: str, date_str: str) -> date | None:
    """Parse a snapshot date directory string to a date object."""
    try:
        if tier == "daily":
            return datetime.strptime(date_str, "%Y-%m-%d").date()
        elif tier == "weekly":
            # YYYY-Www  e.g. 2025-W03
            year, week = date_str.split("-W")
            return datetime.strptime(f"{year}-W{week}-1", "%Y-W%W-%w").date()
        elif tier == "monthly":
            return datetime.strptime(date_str, "%Y-%m").date()
        elif tier == "annual":
            return datetime.strptime(date_str, "%Y").date()
    except (ValueError, AttributeError):
        return None


def expiration_date(tier: str, snapshot_date: date | None) -> date | None:
    """Return the date a snapshot expires, or None if it never does."""
    if tier == "annual" or snapshot_date is None:
        return None
    days = RETENTION.get(tier)
    if days is None:
        return None
    return snapshot_date + timedelta(days=days)


def snapshot_is_mirrored(tier: str, date_str: str, cls: str, target: str) -> bool:
    mirror_path = MIRROR_ROOT / tier / date_str / cls / target
    return mirror_path.exists()


def list_snapshots(tier_filter=None, class_filter=None, target_filter=None, date_filter=None) -> list[dict]:
    """Walk SNAPSHOT_ROOT and return a list of snapshot dicts."""
    snapshots = []
    today = date.today()

    tiers = [tier_filter] if tier_filter else TIERS
    for tier in tiers:
        tier_path = SNAPSHOT_ROOT / tier
        if not tier_path.is_dir():
            continue
        for date_dir in sorted(tier_path.iterdir(), reverse=True):
            if not date_dir.is_dir():
                continue
            if date_filter and date_dir.name != date_filter:
                continue
            snap_date = parse_snapshot_date(tier, date_dir.name)
            exp_date  = expiration_date(tier, snap_date)
            expires_soon = (
                exp_date is not None and (exp_date - today).days <= 3
            ) if exp_date else False

            for cls_dir in sorted(date_dir.iterdir()):
                if not cls_dir.is_dir():
                    continue
                if class_filter and cls_dir.name != class_filter:
                    continue
                for target_dir in sorted(cls_dir.iterdir()):
                    if not target_dir.is_dir():
                        continue
                    if target_filter and target_dir.name != target_filter:
                        continue
                    mirrored = snapshot_is_mirrored(tier, date_dir.name, cls_dir.name, target_dir.name)
                    snapshots.append({
                        "tier":         tier,
                        "date":         date_dir.name,
                        "class":        cls_dir.name,
                        "target":       target_dir.name,
                        "path":         str(target_dir),
                        "snap_date":    snap_date,
                        "exp_date":     exp_date,
                        "expires_soon": expires_soon,
                        "mirrored":     mirrored,
                    })
    return snapshots


def load_targets() -> dict:
    """Load and return the targets YAML, or an empty dict on error."""
    try:
        with open(TARGETS_FILE) as f:
            return yaml.safe_load(f) or {}
    except Exception:
        return {}


def systemd_service_status(unit: str) -> str:
    """Return active/inactive/failed for a systemd unit."""
    try:
        result = subprocess.run(
            ["systemctl", "is-active", unit],
            capture_output=True, text=True, timeout=5
        )
        return result.stdout.strip()
    except Exception:
        return "unknown"


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

@app.get("/login", response_class=HTMLResponse)
async def login_page(request: Request, next: str = "/"):
    if request.session.get("user"):
        return RedirectResponse(url=next, status_code=302)
    return templates.TemplateResponse("login.html", {"request": request, "next": next, "error": ""})


@app.post("/login", response_class=HTMLResponse)
async def login_submit(request: Request, username: str = Form(...), password: str = Form(...), next: str = Form(default="/")):
    p = pam.pam()
    if p.authenticate(username, password):
        request.session["user"] = username
        return RedirectResponse(url=next or "/", status_code=302)
    return templates.TemplateResponse("login.html", {"request": request, "next": next, "error": "Invalid username or password."})


@app.get("/logout")
async def logout(request: Request):
    request.session.clear()
    return RedirectResponse(url="/login", status_code=302)


# ---------------------------------------------------------------------------
# Pages
# ---------------------------------------------------------------------------

@app.get("/", response_class=HTMLResponse)
async def dashboard(request: Request):
    # Quick status: last exit code prom files
    prom_dir = Path("/var/lib/node_exporter/textfile_collector")
    class_status = {}
    for cls in CLASSES:
        prom = prom_dir / f"fsbackup_runner_{cls}.prom"
        status = "unknown"
        if prom.exists():
            for line in prom.read_text().splitlines():
                if line.startswith("fsbackup_runner_last_exit_code{"):
                    status = "ok" if line.split()[-1] == "0" else "error"
                    break
        class_status[cls] = status

    return templates.TemplateResponse("index.html", {
        "request":      request,
        "class_status": class_status,
    })


@app.get("/snapshots", response_class=HTMLResponse)
async def snapshots_page(
    request: Request,
    tier: str = "daily",
    cls: str = "",
    target: str = "",
    snap_date: str = "",
    no_date: str = "",
):
    # Default date to today for daily tier, unless user explicitly cleared it
    today_str = date.today().strftime("%Y-%m-%d")
    if not snap_date and tier == "daily" and not no_date:
        snap_date = today_str

    snaps = list_snapshots(
        tier_filter=tier or None,
        class_filter=cls or None,
        target_filter=target or None,
        date_filter=snap_date or None,
    )
    # Unique values for filter dropdowns
    all_targets = sorted({s["target"] for s in list_snapshots()})
    # Available dates for selected tier (for the date picker datalist)
    tier_dates = []
    if tier:
        tier_path = SNAPSHOT_ROOT / tier
        if tier_path.is_dir():
            tier_dates = sorted([d.name for d in tier_path.iterdir() if d.is_dir()], reverse=True)

    return templates.TemplateResponse("snapshots.html", {
        "request":       request,
        "snapshots":     snaps,
        "tiers":         TIERS,
        "classes":       CLASSES,
        "all_targets":   all_targets,
        "tier_dates":    tier_dates,
        "filter_tier":   tier,
        "filter_class":  cls,
        "filter_target": target,
        "filter_date":   snap_date,
        "today_str":     today_str,
    })


@app.get("/targets", response_class=HTMLResponse)
async def targets_page(request: Request, saved: str = ""):
    data = load_targets()
    return templates.TemplateResponse("targets.html", {
        "request": request,
        "targets": data,
        "saved":   saved == "1",
    })


@app.get("/targets/edit", response_class=HTMLResponse)
async def targets_edit_page(request: Request):
    try:
        content = TARGETS_FILE.read_text()
    except Exception as e:
        content = f"# Could not read {TARGETS_FILE}: {e}\n"
    return templates.TemplateResponse("targets_edit.html", {
        "request": request,
        "content": content,
        "error":   "",
    })


@app.post("/targets/edit", response_class=HTMLResponse)
async def targets_edit_submit(request: Request, content: str = Form(...)):
    error = ""
    try:
        parsed = yaml.safe_load(content)
        if parsed is not None and not isinstance(parsed, dict):
            error = "Top-level structure must be a YAML mapping (class1/class2/class3 keys)."
    except yaml.YAMLError as e:
        # Extract line/column from the mark if available
        mark = getattr(e, "problem_mark", None)
        problem = getattr(e, "problem", None) or str(e)
        if mark is not None:
            error = f"Line {mark.line + 1}, column {mark.column + 1}: {problem}"
        else:
            error = str(e)

    if not error:
        tmp = TARGETS_FILE.with_suffix(".yml.tmp")
        try:
            tmp.write_text(content)
            os.replace(tmp, TARGETS_FILE)
        except Exception as e:
            error = f"Failed to write file: {e}"

    if error:
        return templates.TemplateResponse("targets_edit.html", {
            "request": request,
            "content": content,
            "error":   error,
        })

    return RedirectResponse(url="/targets?saved=1", status_code=303)


@app.get("/browse", response_class=HTMLResponse)
async def browse_page(request: Request, path: str = ""):
    """File browser: list directory contents at path within a snapshot."""
    entries = []
    error   = None
    browse_path = None

    if path:
        browse_path = Path(path)
        # Safety: must be under SNAPSHOT_ROOT
        try:
            browse_path.relative_to(SNAPSHOT_ROOT)
        except ValueError:
            error = "Path is outside snapshot root."
            browse_path = None

    if browse_path and browse_path.is_dir():
        for entry in sorted(browse_path.iterdir(), key=lambda e: (e.is_file(), e.name)):
            stat = entry.stat(follow_symlinks=False)
            entries.append({
                "name":    entry.name,
                "path":    str(entry),
                "is_dir":  entry.is_dir(),
                "size":    stat.st_size if entry.is_file() else None,
                "mtime":   datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M"),
            })
    elif browse_path:
        error = f"Not a directory: {path}"

    # Build breadcrumb from path
    breadcrumbs = []
    if browse_path:
        parts = browse_path.parts
        snap_parts = SNAPSHOT_ROOT.parts
        rel_parts = parts[len(snap_parts):]
        for i, part in enumerate(rel_parts):
            crumb_path = SNAPSHOT_ROOT.joinpath(*rel_parts[:i+1])
            breadcrumbs.append({"name": part, "path": str(crumb_path)})

    return templates.TemplateResponse("browse.html", {
        "request":     request,
        "entries":     entries,
        "current_path": str(browse_path) if browse_path else "",
        "parent_path": str(browse_path.parent) if browse_path and str(browse_path.parent) != str(browse_path) else "",
        "breadcrumbs": breadcrumbs,
        "error":       error,
        "snapshot_root": str(SNAPSHOT_ROOT),
    })


@app.get("/restore", response_class=HTMLResponse)
async def restore_page(request: Request, snapshot_path: str = "", dest: str = ""):
    snapshots = list_snapshots()
    return templates.TemplateResponse("restore.html", {
        "request":       request,
        "snapshots":     snapshots,
        "snapshot_path": snapshot_path,
        "dest":          dest,
        "tiers":         TIERS,
        "classes":       CLASSES,
    })


@app.post("/api/run/restore", response_class=HTMLResponse)
async def api_restore(
    request: Request,
    snapshot_path: str = Form(default=""),
    dest: str = Form(default=""),
    dry_run: str = Form(default=""),
):
    """
    Run rsync to restore a snapshot directory to a destination path.
    snapshot_path: full path to snapshot directory (within SNAPSHOT_ROOT or MIRROR_ROOT)
    dest: local destination path
    dry_run: "1" if dry run (preview only)
    """
    is_dry = dry_run == "1"
    error = ""
    output = ""

    if not snapshot_path:
        error = "Snapshot path is required."
    elif not dest:
        error = "Destination path is required."
    else:
        snap = Path(snapshot_path)
        # Safety: must be within a known snapshot root
        allowed_roots = [SNAPSHOT_ROOT]
        if MIRROR_ROOT:
            allowed_roots.append(MIRROR_ROOT)
        try:
            resolved = snap.resolve()
            if not any(str(resolved).startswith(str(r)) for r in allowed_roots):
                error = f"Snapshot path must be within {SNAPSHOT_ROOT} or {MIRROR_ROOT}"
            elif not resolved.is_dir():
                error = f"Snapshot directory not found: {snapshot_path}"
        except Exception as e:
            error = str(e)

    if not error:
        cmd = ["rsync", "-a", "--stats"]
        if is_dry:
            cmd.append("--dry-run")
        cmd += [str(resolved) + "/", dest + "/"]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            output = r.stdout + r.stderr
            if r.returncode != 0 and not output.strip():
                output = f"rsync exited with code {r.returncode}"
        except subprocess.TimeoutExpired:
            error = "rsync timed out (>120s). For large restores use the command line."
        except Exception as e:
            error = str(e)

    return templates.TemplateResponse("partials/restore_result.html", {
        "request":  request,
        "error":    error,
        "output":   output,
        "is_dry":   is_dry,
    })


@app.get("/run", response_class=HTMLResponse)
async def run_page(request: Request):
    units = {}
    for cls in CLASSES:
        units[cls] = {
            "runner": systemd_service_status(f"fsbackup-runner@{cls}.service"),
            "doctor": systemd_service_status(f"fsbackup-doctor@{cls}.service"),
        }
    promote_status = systemd_service_status("fsbackup-promote.service")
    mirror_status  = systemd_service_status("fsbackup-mirror-daily.service")

    return templates.TemplateResponse("run.html", {
        "request":        request,
        "units":          units,
        "classes":        CLASSES,
        "promote_status": promote_status,
        "mirror_status":  mirror_status,
    })


@app.get("/api/run/status", response_class=HTMLResponse)
async def api_run_status(request: Request):
    """Return live status badges for all run-page units (HTMX polling target)."""
    units = {}
    for cls in CLASSES:
        units[cls] = {
            "runner": systemd_service_status(f"fsbackup-runner@{cls}.service"),
            "doctor": systemd_service_status(f"fsbackup-doctor@{cls}.service"),
        }
    promote_status = systemd_service_status("fsbackup-promote.service")
    mirror_status  = systemd_service_status("fsbackup-mirror-daily.service")
    return templates.TemplateResponse("partials/run_status.html", {
        "request":        request,
        "units":          units,
        "promote_status": promote_status,
        "mirror_status":  mirror_status,
    })


@app.get("/utilities", response_class=HTMLResponse)
async def utilities_page(request: Request):
    return templates.TemplateResponse("utilities.html", {"request": request})


@app.get("/s3", response_class=HTMLResponse)
async def s3_page(request: Request, prefix: str = ""):
    """S3 bucket browser. prefix is a key prefix like 'weekly/class1/myapp/'."""
    objects  = []
    prefixes = []
    error    = None

    try:
        s3  = s3_client()
        paginator = s3.get_paginator("list_objects_v2")
        pages = paginator.paginate(
            Bucket=S3_BUCKET,
            Prefix=prefix,
            Delimiter="/",
        )
        for page in pages:
            for cp in page.get("CommonPrefixes") or []:
                prefixes.append(cp["Prefix"])
            for obj in page.get("Contents") or []:
                if obj["Key"] == prefix:
                    continue  # skip the prefix itself if it appears as an object
                objects.append({
                    "key":           obj["Key"],
                    "name":          obj["Key"].split("/")[-1],
                    "size":          obj["Size"],
                    "last_modified": obj["LastModified"],
                    "storage_class": obj.get("StorageClass", "STANDARD"),
                })
    except (BotoCoreError, ClientError) as e:
        error = str(e)

    # Build breadcrumb from prefix
    breadcrumbs = []
    parts = [p for p in prefix.rstrip("/").split("/") if p]
    for i, part in enumerate(parts):
        breadcrumbs.append({
            "name":   part,
            "prefix": "/".join(parts[:i+1]) + "/",
        })

    return templates.TemplateResponse("s3.html", {
        "request":     request,
        "prefix":      prefix,
        "prefixes":    prefixes,
        "objects":     objects,
        "breadcrumbs": breadcrumbs,
        "bucket":      S3_BUCKET,
        "error":       error,
    })


@app.get("/api/s3/download")
async def s3_download(key: str):
    """Generate a presigned URL for the given S3 key and redirect to it."""
    try:
        s3  = s3_client()
        url = s3.generate_presigned_url(
            "get_object",
            Params={"Bucket": S3_BUCKET, "Key": key},
            ExpiresIn=PRESIGN_TTL,
        )
        return RedirectResponse(url)
    except (BotoCoreError, ClientError) as e:
        return HTMLResponse(f"<p class='text-red-400 text-sm'>Error: {e}</p>", status_code=500)


# ---------------------------------------------------------------------------
# HTMX API endpoints
# ---------------------------------------------------------------------------

@app.get("/api/snapshots", response_class=HTMLResponse)
async def api_snapshots(
    request: Request,
    tier: str = "",
    cls: str = "",
    target: str = "",
    snap_date: str = "",
):
    """Return just the snapshot table rows for HTMX filter updates."""
    snaps = list_snapshots(
        tier_filter=tier or None,
        class_filter=cls or None,
        target_filter=target or None,
        date_filter=snap_date or None,
    )
    return templates.TemplateResponse("partials/snapshot_rows.html", {
        "request":   request,
        "snapshots": snaps,
    })


@app.get("/api/tier-dates", response_class=HTMLResponse)
async def api_tier_dates(request: Request, tier: str = "daily"):
    """Return a datalist of available dates for a given tier (for the date picker)."""
    dates = []
    tier_path = SNAPSHOT_ROOT / tier
    if tier_path.is_dir():
        dates = sorted([d.name for d in tier_path.iterdir() if d.is_dir()], reverse=True)
    options = "".join(f'<option value="{d}"></option>' for d in dates)
    return HTMLResponse(f'<datalist id="tier-dates">{options}</datalist>')


@app.get("/api/browse", response_class=HTMLResponse)
async def api_browse(request: Request, path: str = ""):
    """Return directory listing partial for HTMX tree expansion."""
    entries = []
    error   = None

    if path:
        browse_path = Path(path)
        try:
            browse_path.relative_to(SNAPSHOT_ROOT)
        except ValueError:
            error = "Path is outside snapshot root."
            browse_path = None

        if browse_path and browse_path.is_dir():
            for entry in sorted(browse_path.iterdir(), key=lambda e: (e.is_file(), e.name)):
                stat = entry.stat(follow_symlinks=False)
                entries.append({
                    "name":   entry.name,
                    "path":   str(entry),
                    "is_dir": entry.is_dir(),
                    "size":   stat.st_size if entry.is_file() else None,
                    "mtime":  datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M"),
                })

    return templates.TemplateResponse("partials/dir_entries.html", {
        "request": request,
        "entries": entries,
        "error":   error,
    })


_LOG_DIR = Path("/var/lib/fsbackup/log")

# Map unit name prefixes to their log files (most specific first).
_UNIT_LOG_MAP = [
    ("fsbackup-runner@",       _LOG_DIR / "backup.log"),
    ("fsbackup-promote",       _LOG_DIR / "backup.log"),
    ("fsbackup-doctor@",       _LOG_DIR / "fs-orphans.log"),
    ("fsbackup-mirror-daily",  _LOG_DIR / "mirror.log"),
    ("fsbackup-mirror-retention", _LOG_DIR / "mirror-retention.log"),
    ("fsbackup-s3-export",     _LOG_DIR / "s3-export.log"),
]

def _unit_log_file(unit: str) -> Path | None:
    for prefix, path in _UNIT_LOG_MAP:
        if unit.startswith(prefix):
            return path
    return None


@app.get("/api/journal/{unit:path}", response_class=HTMLResponse)
async def api_journal(request: Request, unit: str, n: int = 200):
    """Return the last n lines of the unit's log file, falling back to journalctl."""
    lines: list[str] = []
    error: str = ""

    log_path = _unit_log_file(unit)
    if log_path:
        try:
            combined: list[str] = []
            # Include the most recent uncompressed rotated file (delaycompress),
            # giving ~1-2 nights of history in the viewer.
            rotated = sorted(log_path.parent.glob(
                f"{log_path.name}-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]"
            ))
            if rotated:
                combined += rotated[-1].read_text(errors="replace").splitlines()
            combined += log_path.read_text(errors="replace").splitlines()
            lines = combined[-n:]
        except Exception as e:
            error = str(e)
    else:
        try:
            r = subprocess.run(
                ["journalctl", "-u", unit, "-n", str(n), "--no-pager",
                 "--output=short-iso", "--no-hostname"],
                capture_output=True, text=True, timeout=8
            )
            lines = r.stdout.splitlines() if r.returncode == 0 else []
            error = r.stderr.strip() if r.returncode != 0 else ""
        except Exception as e:
            error = str(e)

    return templates.TemplateResponse("partials/journal.html", {
        "request": request,
        "unit":    unit,
        "lines":   lines,
        "error":   error,
    })


@app.post("/api/run/{action}", response_class=HTMLResponse)
async def api_run(request: Request, action: str, cls: str = Form(default="")):
    """
    Trigger a systemd service. action: runner | doctor | promote | mirror
    Returns an inline status badge for HTMX swap.
    """
    unit_map = {
        "runner":  f"fsbackup-runner@{cls}.service" if cls else None,
        "doctor":  f"fsbackup-doctor@{cls}.service" if cls else None,
        "promote": "fsbackup-promote.service",
        "mirror":  "fsbackup-mirror-daily.service",
    }
    unit = unit_map.get(action)
    result_msg = ""
    result_ok  = False

    if unit:
        try:
            # --no-block: send start signal and return immediately without
            # waiting for the service to reach active state. The 3s status
            # poller on the Run page will reflect the transition.
            cmd = ["systemctl", "start", "--no-block", unit]
            if os.geteuid() != 0:
                cmd = ["sudo"] + cmd
            r = subprocess.run(
                cmd,
                capture_output=True, text=True, timeout=5
            )
            result_ok  = r.returncode == 0
            result_msg = f"Started {unit}" if result_ok else r.stderr.strip()
        except Exception as e:
            result_msg = str(e)
    else:
        result_msg = f"Unknown action: {action}"

    return templates.TemplateResponse("partials/run_result.html", {
        "request":    request,
        "result_ok":  result_ok,
        "result_msg": result_msg,
        "unit":       unit or action,
    })


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "main:app",
        host=os.environ.get("HOST", "0.0.0.0"),
        port=int(os.environ.get("PORT", "8080")),
        reload=False,
    )
