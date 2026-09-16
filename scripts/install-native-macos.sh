#!/usr/bin/env bash
# QuantDinger v5 native macOS install — no Docker at runtime.
#
# Result: two resident processes (postgres + gunicorn), both managed by launchd.
# The Flask process also serves the SPA, so no nginx is needed.
#
# v5 differs from v3 in two ways that this script papers over:
#   - The repo no longer ships frontend source, only a ghcr image. We pull the
#     built assets out of it with crane; no Docker daemon is involved.
#   - migrations/init.sql is not idempotent against a v3 database, so a restored
#     v3 dump needs pre_v5_backfill_columns.py before the migration runs.
#
# Usage:  ./scripts/install-native-macos.sh
#         QD_RESTORE_SQL=~/qd_backup/qd.sql ./scripts/install-native-macos.sh
set -euo pipefail

PG_PORT="${QD_PG_PORT:-5433}"
APP_PORT="${QD_APP_PORT:-8888}"
PG_FORMULA="postgresql@16"
PY_FORMULA="python@3.12"
PIP_INDEX="${QD_PIP_INDEX:-https://mirrors.aliyun.com/pypi/simple/}"
FRONTEND_IMAGE="${QD_FRONTEND_IMAGE:-ghcr.io/openbyteinc/quantdinger-frontend}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND="$REPO/backend_api_python"
FRONTEND_DIR="$REPO/frontend_dist"
PLIST="$HOME/Library/LaunchAgents/com.quantdinger.backend.plist"
BACKUP_PLIST="$HOME/Library/LaunchAgents/com.quantdinger.backup.plist"
UID_NUM="$(id -u)"

# Frontend and backend are released in lockstep; pin the image to the checked
# out tag so a rollback of the code rolls the UI back with it.
FRONTEND_TAG="${QD_FRONTEND_TAG:-$(git -C "$REPO" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
[ -n "$FRONTEND_TAG" ] || FRONTEND_TAG="latest"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

# --- Preflight -------------------------------------------------------------
# launchd agents cannot read ~/Documents, ~/Desktop or ~/Downloads (macOS TCC),
# so a repo living there starts fine by hand but dies under launchd with
# "Operation not permitted". Refuse early instead of debugging it later.
case "$REPO" in
  "$HOME"/Documents/*|"$HOME"/Desktop/*|"$HOME"/Downloads/*)
    die "Repo is under a TCC-protected folder ($REPO).
    Move it somewhere like ~/qd-v5 and re-run." ;;
esac

command -v brew >/dev/null || die "Homebrew required: https://brew.sh"

# Port 5000 is taken by the AirPlay Receiver on modern macOS; it answers 403
# from AirTunes and gunicorn cannot bind 0.0.0.0:5000.
if [ "$APP_PORT" = "5000" ]; then
  die "Port 5000 collides with the macOS AirPlay Receiver. Use QD_APP_PORT=8888."
fi

# --- Dependencies ----------------------------------------------------------
say "Installing $PG_FORMULA, $PY_FORMULA and crane"
brew list --formula | grep -qx "$PG_FORMULA" || brew install "$PG_FORMULA"
brew list --formula | grep -qx "$PY_FORMULA" || brew install "$PY_FORMULA"
command -v crane >/dev/null || brew install crane

PG_BIN="$(brew --prefix "$PG_FORMULA")/bin"
PG_DATA="$(brew --prefix)/var/$PG_FORMULA"
PY_BIN="$(brew --prefix "$PY_FORMULA")/bin/python3.12"

say "Configuring PostgreSQL on port $PG_PORT"
[ -d "$PG_DATA" ] || "$PG_BIN/initdb" --locale=C -E UTF-8 "$PG_DATA"
sed -i '' "s/^#*port = .*/port = $PG_PORT/" "$PG_DATA/postgresql.conf"

brew services start "$PG_FORMULA" >/dev/null 2>&1 || true
# RunAtLoad is unreliable on recent macOS; kickstart forces the job to run.
launchctl kickstart -k "gui/$UID_NUM/sh.brew.$PG_FORMULA" 2>/dev/null || true
for _ in $(seq 1 20); do
  "$PG_BIN/pg_isready" -h 127.0.0.1 -p "$PG_PORT" >/dev/null 2>&1 && break
  sleep 1
done
"$PG_BIN/pg_isready" -h 127.0.0.1 -p "$PG_PORT" >/dev/null || die "PostgreSQL did not start"

say "Creating role and database"
"$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -d postgres -tAc \
  "SELECT 1 FROM pg_roles WHERE rolname='quantdinger'" | grep -q 1 || \
  "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -d postgres -c \
  "CREATE USER quantdinger WITH PASSWORD 'quantdinger123' SUPERUSER;"
"$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -d postgres -tAc \
  "SELECT 1 FROM pg_database WHERE datname='quantdinger'" | grep -q 1 || \
  "$PG_BIN/createdb" -h 127.0.0.1 -p "$PG_PORT" -O quantdinger quantdinger
# Silences a recurring "database <user> does not exist" in the postgres log.
"$PG_BIN/createdb" -h 127.0.0.1 -p "$PG_PORT" "$(whoami)" 2>/dev/null || true

if [ -n "${QD_RESTORE_SQL:-}" ]; then
  say "Restoring $QD_RESTORE_SQL"
  "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -U quantdinger -d quantdinger -q -f "$QD_RESTORE_SQL"
fi

say "Building the virtualenv"
cd "$BACKEND"
[ -d .venv ] || "$PY_BIN" -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r requirements.txt -i "$PIP_INDEX"
.venv/bin/python -c "import flask, pandas, ccxt, psycopg2, talib" || die "Dependency check failed"

say "Fetching the frontend from $FRONTEND_IMAGE:$FRONTEND_TAG"
# The image is just nginx + static assets. We only want the web root; the SPA
# talks to a relative /api on the same origin, so nothing needs rewriting.
TMP_FE="$(mktemp -d)"
trap 'rm -rf "$TMP_FE"' EXIT
crane export "$FRONTEND_IMAGE:$FRONTEND_TAG" - | tar -xf - -C "$TMP_FE" 2>/dev/null || true
[ -f "$TMP_FE/usr/share/nginx/html/index.html" ] \
  || die "No index.html in $FRONTEND_IMAGE:$FRONTEND_TAG — check the tag exists (crane ls $FRONTEND_IMAGE)"
rm -rf "$FRONTEND_DIR"
mkdir -p "$FRONTEND_DIR"
cp -R "$TMP_FE/usr/share/nginx/html/." "$FRONTEND_DIR/"

say "Writing .env"
[ -f .env ] || cp env.example .env
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)"
.venv/bin/python - "$PG_PORT" "$APP_PORT" "$FRONTEND_DIR" "$LAN_IP" <<'PY'
import re, secrets, sys, pathlib
pg_port, app_port, frontend_dir, lan_ip = sys.argv[1:5]
p = pathlib.Path('.env'); s = p.read_text()
values = {
    'DATABASE_URL': f'postgresql://quantdinger:quantdinger123@127.0.0.1:{pg_port}/quantdinger',
    'PYTHON_API_HOST': '0.0.0.0',
    'PYTHON_API_PORT': app_port,
    'SERVE_FRONTEND_DIR': frontend_dir,      # Flask serves the SPA itself
    'FRONTEND_URL': f'http://localhost:{app_port},http://{lan_ip}:{app_port}',
    # Single-process mode: no Redis, no Celery, no separate worker roles.
    'QD_PROCESS_ROLE': 'legacy',
    'CACHE_ENABLED': 'false',
    'CELERY_TASKS_ENABLED': 'false',
    'STRATEGY_COMMANDS_ENABLED': 'false',
}
if not re.search(r'^SECRET_KEY=.+$', s, re.M):
    values['SECRET_KEY'] = secrets.token_hex(32)
for k, v in values.items():
    pat = re.compile(rf'^{k}=.*$', re.M)
    s = pat.sub(f'{k}={v}', s) if pat.search(s) else s + f'\n{k}={v}\n'
p.write_text(s)
p.chmod(0o600)
PY

say "Migrating the database"
# init.sql adds new columns only inside CREATE TABLE IF NOT EXISTS, so tables
# carried over from v3 keep the old shape and the indexes that follow fail on
# the missing column. Backfill first; it is a no-op on a fresh or current DB.
.venv/bin/python migrations/pre_v5_backfill_columns.py --apply
QD_PROCESS_ROLE=migration .venv/bin/python -m app.commands.migrate

say "Installing the launchd agent"
mkdir -p "$BACKEND/logs"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>com.quantdinger.backend</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BACKEND/.venv/bin/gunicorn</string>
		<string>-c</string><string>$BACKEND/gunicorn_config.py</string>
		<string>run:app</string>
	</array>
	<key>WorkingDirectory</key><string>$BACKEND</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key><string>$PG_BIN:$(brew --prefix)/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>PYTHON_API_HOST</key><string>0.0.0.0</string>
		<key>PYTHON_API_PORT</key><string>$APP_PORT</string>
		<key>LC_ALL</key><string>en_US.UTF-8</string>
		<!-- Without this, a gunicorn worker forked after the master has touched
		     an ObjC framework aborts on +[NSCharacterSet initialize] and the
		     master respawns it forever. -->
		<key>OBJC_DISABLE_INITIALIZE_FORK_SAFETY</key><string>YES</string>
	</dict>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
	<key>ThrottleInterval</key><integer>15</integer>
	<key>StandardOutPath</key><string>$BACKEND/logs/launchd.out.log</string>
	<key>StandardErrorPath</key><string>$BACKEND/logs/launchd.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$UID_NUM/com.quantdinger.backend" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
# bootstrap often leaves the job loaded but unspawned ("pended nondemand
# spawn"); -k forces it up regardless of what launchd decided to defer.
launchctl kickstart -k "gui/$UID_NUM/com.quantdinger.backend"

say "Scheduling the daily backup"
mkdir -p "$HOME/qd_backup"
cat > "$BACKUP_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>com.quantdinger.backup</string>
	<key>ProgramArguments</key><array><string>$REPO/scripts/backup-db.sh</string></array>
	<key>WorkingDirectory</key><string>$REPO</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key><string>$PG_BIN:$(brew --prefix)/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>QD_PG_PORT</key><string>$PG_PORT</string>
		<key>QD_KEEP</key><string>14</string>
		<key>LC_ALL</key><string>en_US.UTF-8</string>
	</dict>
	<!-- A run missed with the lid closed fires once the machine wakes. -->
	<key>StartCalendarInterval</key>
	<dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>30</integer></dict>
	<key>RunAtLoad</key><false/>
	<key>ProcessType</key><string>Background</string>
	<key>StandardOutPath</key><string>$HOME/qd_backup/backup.log</string>
	<key>StandardErrorPath</key><string>$HOME/qd_backup/backup.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$UID_NUM/com.quantdinger.backup" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$BACKUP_PLIST"

say "Waiting for the API"
for _ in $(seq 1 40); do
  curl -sf -m 3 "http://127.0.0.1:$APP_PORT/api/health" >/dev/null 2>&1 && break
  sleep 2
done
curl -sf -m 5 "http://127.0.0.1:$APP_PORT/api/health" >/dev/null \
  || die "API did not come up — check $BACKEND/logs/launchd.err.log"

cat <<EOF

$(printf '\033[1;32mQuantDinger %s is running.\033[0m' "$FRONTEND_TAG")

  Local      http://localhost:$APP_PORT
  LAN        http://$LAN_IP:$APP_PORT
  Login      see ADMIN_USER / ADMIN_PASSWORD in $BACKEND/.env

  Logs       tail -f $BACKEND/logs/launchd.err.log
  Restart    launchctl kickstart -k gui/$UID_NUM/com.quantdinger.backend
  Stop       launchctl bootout gui/$UID_NUM/com.quantdinger.backend
  Database   $PG_BIN/psql -h 127.0.0.1 -p $PG_PORT -U quantdinger -d quantdinger
  Backup     daily 03:30 into $HOME/qd_backup (keeps 14); run now with
             launchctl kickstart -w gui/$UID_NUM/com.quantdinger.backup
  Frontend   re-pull after a code upgrade:
             QD_FRONTEND_TAG=<ver> ./scripts/install-native-macos.sh

Optional — connect an MCP client (Hermes, Cursor, Claude Code):
  1. Open http://localhost:$APP_PORT/#/agent-tokens and issue a token with R + B scopes.
  2. Point the client at: uvx --from $REPO/mcp_server quantdinger-mcp
     with QUANTDINGER_BASE_URL=http://127.0.0.1:$APP_PORT and QUANTDINGER_AGENT_TOKEN=<token>.
EOF
