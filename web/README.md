# fsbackup web UI

A lightweight read-mostly admin interface for the fsbackup system. Built with
FastAPI, HTMX, and Tailwind CSS. Runs as a systemd service on the backup server.

---

## Architecture

```
web/
  main.py              # FastAPI application — all routes and business logic
  requirements.txt     # Python dependencies
  .env.example         # Configuration template (copy to .env)
  static/              # Static assets (currently empty; Tailwind and HTMX are CDN)
  templates/
    base.html          # Shared layout: sidebar nav, dark/light toggle, CDN scripts
    index.html         # Dashboard
    snapshots.html     # Snapshot browser with live HTMX filters
    targets.html       # targets.yml viewer
    browse.html        # Filesystem browser inside a snapshot
    restore.html       # Restore form
    run.html           # Trigger systemd services
    s3.html            # S3 offsite bucket browser
    utilities.html     # Admin utilities (placeholder)
    partials/
      snapshot_rows.html   # HTMX swap target: snapshot table body
      dir_entries.html     # HTMX swap target: directory listing rows
      run_result.html      # HTMX swap target: inline start/error badge
```

### Stack

| Layer     | Technology | Notes |
|-----------|-----------|-------|
| Backend   | [FastAPI](https://fastapi.tiangolo.com/) | Async Python, served by uvicorn |
| Templates | [Jinja2](https://jinja.palletsprojects.com/) | Server-rendered HTML |
| Interactivity | [HTMX](https://htmx.org/) 1.9 | Swaps HTML fragments without a JS framework |
| Styles    | [Tailwind CSS](https://tailwindcss.com/) 3 (CDN) | No build step required |
| S3 client | [boto3](https://boto3.amazonaws.com/v1/documentation/api/latest/index.html) | Uses the `fsbackup` AWS profile |

Tailwind and HTMX are loaded from CDN in `base.html`. There is no frontend build
step and no Node.js requirement.

---

## Pages and routes

| Route | Page | Description |
|-------|------|-------------|
| `GET /` | Dashboard | Class status cards read from `.prom` metric files |
| `GET /snapshots` | Snapshots | Filterable table of all local snapshots; defaults to daily tier + today |
| `GET /targets` | Targets | Parsed view of `/etc/fsbackup/targets.yml`, grouped by class |
| `GET /browse` | Browse | Directory tree walker inside a snapshot path |
| `GET /restore` | Restore | Restore form with recent-snapshot quick-select sidebar |
| `GET /run` | Run | Trigger runner/doctor per class, promote, mirror |
| `GET /s3` | S3 Offsite | Prefix-based S3 bucket browser with presigned download |
| `GET /utilities` | Utilities | Admin tool stubs (coming soon) |

### HTMX partial endpoints

| Route | Returns | Triggered by |
|-------|---------|--------------|
| `GET /api/snapshots` | `partials/snapshot_rows.html` | Filter change on `/snapshots` |
| `GET /api/tier-dates` | `<datalist>` HTML | Tier dropdown change on `/snapshots` |
| `GET /api/browse` | `partials/dir_entries.html` | *(reserved for future lazy tree)* |
| `GET /api/s3/download?key=…` | Redirect to presigned URL | Download button on `/s3` |
| `POST /api/run/{action}` | `partials/run_result.html` | Start buttons on `/run` |

---

## How scripts and services are called

### Systemd (Run page)

`POST /api/run/{action}` runs:

```python
subprocess.run(["systemctl", "start", "<unit>"], ...)
```

The process running the web UI must be able to call `systemctl start` for the
fsbackup units. If running as the `fsbackup` user, add sudoers entries:

```
fsbackup ALL=(root) NOPASSWD: /bin/systemctl start fsbackup-runner@*.service
fsbackup ALL=(root) NOPASSWD: /bin/systemctl start fsbackup-doctor@*.service
fsbackup ALL=(root) NOPASSWD: /bin/systemctl start fsbackup-promote.service
fsbackup ALL=(root) NOPASSWD: /bin/systemctl start fsbackup-mirror-daily.service
```

Then update the `api_run` handler to prepend `sudo` to the command.

### S3 (S3 Offsite page)

Uses boto3 with the `fsbackup` AWS profile (`/var/lib/fsbackup/.aws/credentials`).
`ListObjectsV2` is used to browse prefixes. Downloads generate a **presigned URL**
via `generate_presigned_url("get_object", ...)` — the browser fetches directly from
S3, nothing is proxied through the web server.

Presigned URLs expire after `PRESIGN_TTL` seconds (default: 3600).

### Restore (Restore page)

Currently displays the form and instructions. Wiring the form POST to invoke
`utils/fs-restore.sh` is the next step — see `POST /api/run/restore` stub in
`main.py`.

---

## Configuration

Copy `.env.example` to `.env` in the `web/` directory and edit as needed.
The app loads `.env` automatically at startup via `python-dotenv`.

```bash
cp web/.env.example web/.env
```

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST` | `0.0.0.0` | Address uvicorn binds to |
| `PORT` | `8080` | Port uvicorn listens on |
| `SNAPSHOT_ROOT` | `/backup/snapshots` | Primary snapshot directory |
| `MIRROR_ROOT` | `/backup2/snapshots` | Mirror snapshot directory |
| `TARGETS_FILE` | `/etc/fsbackup/targets.yml` | targets.yml path |
| `S3_BUCKET` | `fsbackup-snapshots-947012` | S3 bucket name |
| `S3_PROFILE` | `fsbackup` | AWS credentials profile name |
| `S3_REGION` | `us-west-2` | AWS region |
| `PRESIGN_TTL` | `3600` | Presigned URL expiry in seconds |

When running under systemd, variables can also be set via `Environment=` or
`EnvironmentFile=` in the unit file instead of using `.env`.

---

## Running locally

```bash
cd /opt/fsbackup/web
pip install -r requirements.txt

# With .env file (reads HOST/PORT automatically):
uvicorn main:app --host "${HOST:-0.0.0.0}" --port "${PORT:-8080}" --reload
```

Or simply:

```bash
uvicorn main:app --reload
```

The `--reload` flag restarts on file changes — useful during development. Remove it
in production.

---

## Deploying as a systemd service

Create `/etc/systemd/system/fsbackup-web.service`:

```ini
[Unit]
Description=fsbackup web UI
After=network.target

[Service]
Type=simple
User=fsbackup
WorkingDirectory=/opt/fsbackup/web
ExecStart=/usr/local/bin/uvicorn main:app --host 0.0.0.0 --port 8080 --workers 2
Restart=on-failure
RestartSec=5
EnvironmentFile=/opt/fsbackup/web/.env

[Install]
WantedBy=multi-user.target
```

Then enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now fsbackup-web.service
```

> The unit file above is a starting point. A copy will be added to `systemd/` in
> the repo once the web UI is stable enough for production use.

---

## Dark / light mode

The toggle button in the top-right of the sidebar switches between dark and light
mode. The preference is saved in `localStorage` and applied before first paint to
avoid a flash.

---

## Extending the UI

- **New page**: add a route in `main.py`, create `templates/<page>.html` extending
  `base.html`, add the nav entry to the `nav` list in `base.html`.
- **New HTMX partial**: add a `GET /api/...` route returning a
  `TemplateResponse("partials/<name>.html", ...)`, target it with `hx-get` and
  `hx-target` in the calling template.
- **New utility**: add a card to `utilities.html` and a `POST /api/run/<action>`
  handler that calls the relevant script in `utils/`.
