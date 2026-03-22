#!/usr/bin/env python3
"""fsbackup web UI — FastAPI + HTMX + Tailwind"""

import os
import secrets
import shutil
import subprocess
import threading
import yaml
from collections import deque
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
from starlette.middleware.sessions import SessionMiddleware

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

SNAPSHOT_ROOT = Path(os.environ.get("SNAPSHOT_ROOT", "/backup/snapshots"))
MIRROR_ROOT   = Path(os.environ.get("MIRROR_ROOT",   "/backup2/snapshots"))
TARGETS_FILE  = Path(os.environ.get("TARGETS_FILE",  "/etc/fsbackup/targets.yml"))
SCRIPTS_DIR   = Path(os.environ.get("SCRIPTS_DIR",   "/opt/fsbackup"))
CRONTAB_FILE  = Path(os.environ.get("CRONTAB_FILE",  "/etc/fsbackup/fsbackup.crontab"))
PROM_DIR      = Path(os.environ.get("PROM_DIR",      "/var/lib/node_exporter/textfile_collector"))

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

SECRET_KEY        = os.environ.get("SECRET_KEY", secrets.token_hex(32))
AUTH_ENABLED      = os.environ.get("AUTH_ENABLED", "true").lower() not in ("false", "0", "no")
AUTH_PASSWORD_HASH = os.environ.get("AUTH_PASSWORD_HASH", "")

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
# Starlette 1.0 changed signature to TemplateResponse(request, name, context)
_orig_response = templates.TemplateResponse
def _template_response(name, context, *args, **kwargs):
    context.setdefault("now", datetime.now())
    request = context.get("request")
    return _orig_response(request, name, context, *args, **kwargs)
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


def list_orphan_snapshots() -> list[dict]:
    """Return snapshot dirs whose target ID is not in targets.yml, for primary and mirror."""
    targets = load_targets()
    valid_ids: set[str] = set()
    for entries in targets.values():
        if isinstance(entries, list):
            for entry in entries:
                if isinstance(entry, dict) and "id" in entry:
                    valid_ids.add(entry["id"])

    orphans = []
    for root_path, root_label in [(SNAPSHOT_ROOT, "primary"), (MIRROR_ROOT, "mirror")]:
        if not root_path.is_dir():
            continue
        for tier_dir in root_path.iterdir():
            if not tier_dir.is_dir():
                continue
            tier = tier_dir.name
            for date_dir in sorted(tier_dir.iterdir(), reverse=True):
                if not date_dir.is_dir():
                    continue
                for cls_dir in sorted(date_dir.iterdir()):
                    if not cls_dir.is_dir():
                        continue
                    for target_dir in sorted(cls_dir.iterdir()):
                        if not target_dir.is_dir():
                            continue
                        if target_dir.name not in valid_ids:
                            orphans.append({
                                "root":   root_label,
                                "tier":   tier,
                                "date":   date_dir.name,
                                "class":  cls_dir.name,
                                "target": target_dir.name,
                                "path":   str(target_dir),
                            })
    return orphans


# ---------------------------------------------------------------------------
# Job runner (Docker-compatible: direct subprocess, no systemd dependency)
# ---------------------------------------------------------------------------

def _build_job_commands() -> dict[str, list[str]]:
    b = SCRIPTS_DIR / "bin"
    s = SCRIPTS_DIR / "s3"
    return {
        "runner-class1": [str(b / "fs-runner.sh"), "daily",   "--class", "class1"],
        "runner-class2": [str(b / "fs-runner.sh"), "daily",   "--class", "class2"],
        "runner-class3": [str(b / "fs-runner.sh"), "monthly", "--class", "class3"],
        "doctor-class1": [str(b / "fs-doctor.sh"), "--class", "class1"],
        "doctor-class2": [str(b / "fs-doctor.sh"), "--class", "class2"],
        "doctor-class3": [str(b / "fs-doctor.sh"), "--class", "class3"],
        "promote":       [str(b / "fs-promote.sh")],
        "mirror":        [str(b / "fs-mirror.sh"), "daily"],
    }

_JOB_COMMANDS = _build_job_commands()
_jobs: dict[str, dict] = {}
_jobs_lock = threading.Lock()


def _stream_job(key: str, proc: subprocess.Popen) -> None:
    """Background thread: drain proc stdout/stderr into the job's line buffer."""
    job = _jobs[key]
    for raw in proc.stdout:  # type: ignore[union-attr]
        job["lines"].append(raw.rstrip("\n"))
    proc.wait()
    with _jobs_lock:
        job["rc"]       = proc.returncode
        job["status"]   = "done" if proc.returncode == 0 else "failed"
        job["ended_at"] = datetime.now()


def _job_status(key: str) -> str:
    job = _jobs.get(key)
    return job["status"] if job else "idle"


def _job_tail(key: str) -> list[str]:
    job = _jobs.get(key)
    return list(job["lines"]) if job else []


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
    import bcrypt
    ok = False
    if AUTH_PASSWORD_HASH:
        try:
            ok = bcrypt.checkpw(password.encode(), AUTH_PASSWORD_HASH.encode())
        except Exception:
            ok = False
    if ok:
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
            "runner": _job_status(f"runner-{cls}"),
            "doctor": _job_status(f"doctor-{cls}"),
        }
    promote_status = _job_status("promote")
    mirror_status  = _job_status("mirror")
    tails = {key: _job_tail(key) for key in _JOB_COMMANDS}

    return templates.TemplateResponse("run.html", {
        "request":        request,
        "units":          units,
        "classes":        CLASSES,
        "promote_status": promote_status,
        "mirror_status":  mirror_status,
        "tails":          tails,
    })


@app.get("/api/run/status", response_class=HTMLResponse)
async def api_run_status(request: Request):
    """Return live status badges + output tails for all run-page jobs (HTMX polling target)."""
    units = {}
    for cls in CLASSES:
        units[cls] = {
            "runner": _job_status(f"runner-{cls}"),
            "doctor": _job_status(f"doctor-{cls}"),
        }
    promote_status = _job_status("promote")
    mirror_status  = _job_status("mirror")
    tails = {key: _job_tail(key) for key in _JOB_COMMANDS}
    return templates.TemplateResponse("partials/run_status.html", {
        "request":        request,
        "units":          units,
        "promote_status": promote_status,
        "mirror_status":  mirror_status,
        "tails":          tails,
    })


@app.get("/utilities", response_class=HTMLResponse)
async def utilities_page(request: Request):
    return templates.TemplateResponse("utilities.html", {"request": request})


# ---------------------------------------------------------------------------
# Orphan cleanup
# ---------------------------------------------------------------------------

@app.get("/orphans", response_class=HTMLResponse)
async def orphans_page(request: Request):
    orphans = list_orphan_snapshots()
    return _template_response("orphans.html", {"request": request, "orphans": orphans})


@app.post("/api/orphans/delete", response_class=HTMLResponse)
async def api_orphans_delete(request: Request, paths: list[str] = Form(...)):
    """Delete selected orphan snapshot directories."""
    allowed_roots = [SNAPSHOT_ROOT, MIRROR_ROOT]
    errors: list[str] = []
    deleted: list[str] = []

    for raw_path in paths:
        p = Path(raw_path).resolve()
        # Safety: must be under SNAPSHOT_ROOT or MIRROR_ROOT, at least 4 levels deep
        # (root/tier/date/class/target)
        in_allowed = any(
            p == root or p.is_relative_to(root) for root in allowed_roots
        )
        depth = len(p.parts) - len(SNAPSHOT_ROOT.parts)
        if not in_allowed or depth < 4:
            errors.append(f"Refused: {raw_path}")
            continue
        try:
            shutil.rmtree(p)
            deleted.append(str(p))
        except Exception as e:
            errors.append(f"{p.name}: {e}")

    orphans = list_orphan_snapshots()

    # Update the Prometheus orphan metric so the dashboard reflects the deletion
    if deleted:
        try:
            counts: dict[str, int] = {"primary": 0, "mirror": 0}
            for o in orphans:
                counts[o["root"]] = counts.get(o["root"], 0) + 1
            prom_path = PROM_DIR / "fsbackup_orphans.prom"
            tmp = prom_path.with_suffix(".prom.tmp")
            tmp.write_text(
                f'fsbackup_orphan_snapshots_total{{root="primary"}} {counts["primary"]}\n'
                f'fsbackup_orphan_snapshots_total{{root="mirror"}} {counts["mirror"]}\n'
            )
            try:
                import grp
                gid = grp.getgrnam("nodeexp_txt").gr_gid
                os.chown(tmp, -1, gid)
            except (KeyError, AttributeError, OSError):
                pass
            tmp.chmod(0o644)
            tmp.rename(prom_path)
        except Exception:
            pass  # non-fatal — metric will self-correct on next doctor run

    return _template_response("partials/orphan_table.html", {
        "request": request,
        "orphans": orphans,
        "deleted": deleted,
        "errors":  errors,
    })


# ---------------------------------------------------------------------------
# Logs page
# ---------------------------------------------------------------------------

# Log sections shown on /logs — (unit_key, label, description)
_LOG_SECTIONS = [
    ("fsbackup-runner@class1.service",      "Backup — class1",       "backup.log"),
    ("fsbackup-runner@class2.service",      "Backup — class2",       "backup.log"),
    ("fsbackup-runner@class3.service",      "Backup — class3",       "backup.log"),
    ("fsbackup-mirror-daily.service",       "Mirror (daily)",        "mirror.log"),
    ("fsbackup-mirror-retention.service",   "Mirror retention",      "mirror-retention.log"),
    ("fsbackup-s3-export.service",          "S3 export",             "s3-export.log"),
    ("fsbackup-orphans",                    "Orphan scan",           "fs-orphans.log"),
    ("fsbackup-annual-promote.service",     "Annual promote",        "annual-promote.log"),
]


def _parse_prom_files() -> list[dict]:
    """Read all fsbackup*.prom files and return parsed metric rows."""
    rows: list[dict] = []
    try:
        prom_files = sorted(PROM_DIR.glob("fsbackup*.prom"))
    except Exception:
        return rows

    for pf in prom_files:
        try:
            text = pf.read_text(errors="replace")
        except Exception:
            continue
        help_map: dict[str, str] = {}
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("# HELP"):
                parts = line.split(None, 3)
                if len(parts) == 4:
                    help_map[parts[2]] = parts[3]
            elif line and not line.startswith("#"):
                # metric{labels} value [timestamp]
                parts = line.split()
                if not parts:
                    continue
                raw_name = parts[0]
                value    = parts[1] if len(parts) > 1 else ""
                # split name and labels
                if "{" in raw_name:
                    metric_name = raw_name[:raw_name.index("{")]
                    labels_str  = raw_name[raw_name.index("{")+1:raw_name.rindex("}")]
                else:
                    metric_name = raw_name
                    labels_str  = ""
                rows.append({
                    "metric":  metric_name,
                    "labels":  labels_str,
                    "value":   value,
                    "help":    help_map.get(metric_name, ""),
                    "file":    pf.name,
                })
    return rows


@app.get("/logs", response_class=HTMLResponse)
async def logs_page(request: Request):
    metrics = _parse_prom_files()
    return _template_response("logs.html", {
        "request":      request,
        "log_sections": _LOG_SECTIONS,
        "metrics":      metrics,
    })


# ---------------------------------------------------------------------------
# Configuration page
# ---------------------------------------------------------------------------

def _load_crontab() -> list[dict]:
    """Parse fsbackup.crontab into a list of {schedule, command, label} dicts."""
    # Human-readable labels for known job patterns
    _LABELS = {
        "fs-logrotate-metric.sh": "Logrotate health metric",
        "fs-doctor.sh --class class1": "Doctor — class1",
        "fs-doctor.sh --class class2": "Doctor — class2",
        "fs-doctor.sh --class class3": "Doctor — class3",
        "fs-db-export.sh": "DB export",
        "fs-runner.sh daily --class class1": "Backup runner — class1 (daily)",
        "fs-runner.sh daily --class class2": "Backup runner — class2 (daily)",
        "fs-runner.sh monthly --class class3": "Backup runner — class3 (monthly)",
        "fs-mirror.sh daily": "Mirror — daily pass",
        "fs-retention.sh": "Retention",
        "fs-promote.sh": "Promote daily→weekly/monthly",
        "fs-mirror.sh promote": "Mirror — promote pass",
        "fs-mirror-retention.sh": "Mirror retention",
        "fs-export-s3.sh": "S3 export",
        "fs-annual-promote.sh": "Annual promote (Jan 5)",
    }

    entries = []
    try:
        lines = CRONTAB_FILE.read_text().splitlines()
    except Exception:
        return entries

    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        parts = stripped.split(None, 5)
        if len(parts) < 6:
            continue
        schedule = " ".join(parts[:5])
        command  = parts[5]
        label = next(
            (lbl for key, lbl in _LABELS.items() if key in command),
            command.split("/")[-1],
        )
        entries.append({"schedule": schedule, "command": command, "label": label})
    return entries


def _disk_info(path: Path) -> dict:
    """Return df-style info for a path: total, used, free (bytes), and pct_used."""
    try:
        st = os.statvfs(path)
        total = st.f_blocks * st.f_frsize
        free  = st.f_bavail * st.f_frsize
        used  = total - st.f_bfree * st.f_frsize
        pct   = round(used / total * 100) if total else 0
        return {"path": str(path), "total": total, "used": used, "free": free, "pct_used": pct, "error": None}
    except Exception as exc:
        return {"path": str(path), "total": 0, "used": 0, "free": 0, "pct_used": 0, "error": str(exc)}


def _fmt_bytes(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"


@app.get("/configuration", response_class=HTMLResponse)
async def configuration_page(request: Request, tab: str = "hosts"):
    targets = load_targets()

    # Extract unique hosts from all classes
    hosts: list[str] = []
    seen: set[str] = set()
    for class_targets in targets.values():
        for t in class_targets:
            h = t.get("host", "")
            if h and h not in seen:
                seen.add(h)
                hosts.append(h)

    # Build per-target volume info: which snapshot root has data for it?
    target_volumes: dict[str, list[str]] = {}
    for class_targets in targets.values():
        for t in class_targets:
            tid = t.get("id", "")
            vols = []
            for root in (SNAPSHOT_ROOT, MIRROR_ROOT):
                for tier_dir in root.glob("*"):
                    for date_dir in tier_dir.glob("*"):
                        for cls_dir in date_dir.glob("*"):
                            if (cls_dir / tid).exists():
                                vols.append(str(root))
                                break
                        else:
                            continue
                        break
                    else:
                        continue
                    break
            target_volumes[tid] = list(set(vols))

    primary_disk = _disk_info(SNAPSHOT_ROOT)
    mirror_disk  = _disk_info(MIRROR_ROOT)

    primary_disk["fmt_used"]  = _fmt_bytes(primary_disk["used"])
    primary_disk["fmt_free"]  = _fmt_bytes(primary_disk["free"])
    primary_disk["fmt_total"] = _fmt_bytes(primary_disk["total"])
    mirror_disk["fmt_used"]   = _fmt_bytes(mirror_disk["used"])
    mirror_disk["fmt_free"]   = _fmt_bytes(mirror_disk["free"])
    mirror_disk["fmt_total"]  = _fmt_bytes(mirror_disk["total"])

    crontab = _load_crontab()

    return _template_response("configuration.html", {
        "request":        request,
        "tab":            tab,
        "hosts":          hosts,
        "targets":        targets,
        "target_volumes": target_volumes,
        "primary_disk":   primary_disk,
        "mirror_disk":    mirror_disk,
        "crontab":        crontab,
        "snapshot_root":  str(SNAPSHOT_ROOT),
        "mirror_root":    str(MIRROR_ROOT),
    })


@app.post("/api/config/crontab/schedule", response_class=HTMLResponse)
async def api_crontab_schedule(
    request: Request,
    command:  str = Form(...),
    schedule: str = Form(...),
):
    """Update the cron schedule for a single job identified by its command string."""
    error = ""
    saved = False

    # Validate: must be exactly 5 whitespace-separated fields, no newlines or semicolons
    fields = schedule.strip().split()
    if len(fields) != 5:
        error = "Schedule must be exactly 5 fields (minute hour day month weekday)"
    elif any(c in schedule for c in (";", "\n", "\r", "|", "`", "$")):
        error = "Invalid characters in schedule expression"

    if not error:
        try:
            lines = CRONTAB_FILE.read_text().splitlines()
            new_lines = []
            matched = False
            for line in lines:
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    new_lines.append(line)
                    continue
                parts = stripped.split(None, 5)
                if len(parts) == 6 and parts[5] == command:
                    new_lines.append(f"{schedule} {command}")
                    matched = True
                else:
                    new_lines.append(line)
            if not matched:
                error = f"Job not found in crontab: {command}"
            else:
                tmp = CRONTAB_FILE.with_suffix(".crontab.tmp")
                tmp.write_text("\n".join(new_lines) + "\n")
                os.replace(tmp, CRONTAB_FILE)
                saved = True
        except Exception as e:
            error = str(e)

    crontab = _load_crontab()
    return _template_response("partials/crontab_table.html", {
        "request": request,
        "crontab": crontab,
        "saved":   saved,
        "error":   error,
    })


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
    ("fsbackup-runner@",          _LOG_DIR / "backup.log"),
    ("fsbackup-promote",          _LOG_DIR / "backup.log"),
    ("fsbackup-doctor@",          _LOG_DIR / "fs-orphans.log"),
    ("fsbackup-mirror-daily",     _LOG_DIR / "mirror.log"),
    ("fsbackup-mirror-retention", _LOG_DIR / "mirror-retention.log"),
    ("fsbackup-s3-export",        _LOG_DIR / "s3-export.log"),
    ("fsbackup-annual-promote",   _LOG_DIR / "annual-promote.log"),
    ("fsbackup-orphans",          _LOG_DIR / "fs-orphans.log"),
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


@app.post("/api/run/rename-target", response_class=HTMLResponse)
async def api_rename_target(
    request: Request,
    cls:      str = Form(...),
    from_id:  str = Form(...),
    to_id:    str = Form(...),
    mode:     str = Form(...),       # "move" or "delete"
    dry_run:  str = Form(default=""), # "1" if checked
):
    """Run fs-target-rename.sh with the given parameters."""
    key = "rename-target"
    result_msg = ""
    result_ok  = False

    if _jobs.get(key, {}).get("status") == "running":
        result_msg = "A rename is already running"
    elif mode not in ("move", "delete"):
        result_msg = "Invalid mode — must be move or delete"
    elif not from_id.strip() or not to_id.strip():
        result_msg = "from and to target IDs are required"
    else:
        script = SCRIPTS_DIR / "utils" / "fs-target-rename.sh"
        cmd = ["sudo", str(script),
               "--class", cls,
               "--from",  from_id.strip(),
               "--to",    to_id.strip(),
               f"--{mode}"]
        if dry_run == "1":
            cmd.append("--dry-run")
        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            with _jobs_lock:
                _jobs[key] = {
                    "status":     "running",
                    "rc":         None,
                    "started_at": datetime.now(),
                    "ended_at":   None,
                    "lines":      deque(maxlen=200),
                }
            threading.Thread(target=_stream_job, args=(key, proc), daemon=True).start()
            result_ok  = True
            mode_label = "move" if mode == "move" else "wipe history"
            result_msg = f"Started: {from_id} → {to_id} ({mode_label}{'  dry-run' if dry_run == '1' else ''})"
        except Exception as e:
            result_msg = str(e)

    return templates.TemplateResponse("partials/run_result.html", {
        "request":    request,
        "result_ok":  result_ok,
        "result_msg": result_msg,
        "unit":       key,
    })


@app.post("/api/run/{action}", response_class=HTMLResponse)
async def api_run(request: Request, action: str, cls: str = Form(default="")):
    """
    Trigger a backup job. action: runner | doctor | promote | mirror
    Spawns the script directly as a subprocess; output streamed into an
    in-memory deque visible via the status poller. No systemd dependency.
    """
    key = f"{action}-{cls}" if cls else action
    cmd = _JOB_COMMANDS.get(key)
    result_msg = ""
    result_ok  = False

    if not cmd:
        result_msg = f"Unknown job: {key}"
    elif _jobs.get(key, {}).get("status") == "running":
        result_msg = f"{key} is already running"
    else:
        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            with _jobs_lock:
                _jobs[key] = {
                    "status":     "running",
                    "rc":         None,
                    "started_at": datetime.now(),
                    "ended_at":   None,
                    "lines":      deque(maxlen=20),
                }
            threading.Thread(target=_stream_job, args=(key, proc), daemon=True).start()
            result_ok  = True
            result_msg = f"Started {key}"
        except Exception as e:
            result_msg = str(e)

    return templates.TemplateResponse("partials/run_result.html", {
        "request":    request,
        "result_ok":  result_ok,
        "result_msg": result_msg,
        "unit":       key,
    })


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "main:app",
        host=os.environ.get("HOST", "0.0.0.0"),
        port=int(os.environ.get("PORT", "8080")),
        reload=False,
    )
