#!/usr/bin/env python3
"""fsbackup web UI — FastAPI + HTMX + Tailwind"""

import os
import subprocess
import yaml
from datetime import date, datetime, timedelta
from pathlib import Path

from dotenv import load_dotenv
load_dotenv(Path(__file__).parent / ".env")

import boto3
from botocore.config import Config as BotoConfig
from botocore.exceptions import BotoCoreError, ClientError

from fastapi import FastAPI, Request, Form
from fastapi.responses import HTMLResponse, RedirectResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

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
S3_BUCKET  = os.environ.get("S3_BUCKET",  "fsbackup-snapshots-947012")
S3_PROFILE = os.environ.get("S3_PROFILE", "fsbackup")
S3_REGION  = os.environ.get("S3_REGION",  "us-west-2")
PRESIGN_TTL = 3600  # seconds


def s3_client():
    session = boto3.Session(profile_name=S3_PROFILE)
    return session.client("s3", region_name=S3_REGION, config=BotoConfig(signature_version="s3v4"))

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

app = FastAPI(title="fsbackup")
app.mount("/static", StaticFiles(directory=Path(__file__).parent / "static"), name="static")
templates = Jinja2Templates(directory=Path(__file__).parent / "templates")

# Inject `now` into every template context
@app.middleware("http")
async def inject_globals(request: Request, call_next):
    response = await call_next(request)
    return response

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
):
    # Default date to today for daily tier; blank for other tiers
    today_str = date.today().strftime("%Y-%m-%d")
    if not snap_date and tier == "daily":
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
async def targets_page(request: Request):
    data = load_targets()
    return templates.TemplateResponse("targets.html", {
        "request": request,
        "targets": data,
    })


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
            r = subprocess.run(
                ["systemctl", "start", unit],
                capture_output=True, text=True, timeout=10
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
