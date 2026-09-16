#!/usr/bin/env bash
# QuantDinger native macOS install — no Docker.
#
# Result: two resident processes (postgres + gunicorn), ~320 MB, both managed
# by launchd so they come back after a reboot. The Flask process also serves
# frontend/dist, so no nginx is needed.
#
# Usage:  ./scripts/install-native-macos.sh
set -euo pipefail

PG_PORT="${QD_PG_PORT:-5433}"
APP_PORT="${QD_APP_PORT:-8888}"
PG_FORMULA="postgresql@16"
PY_FORMULA="python@3.12"
PIP_INDEX="${QD_PIP_INDEX:-https://mirrors.aliyun.com/pypi/simple/}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND="$REPO/backend_api_python"
PLIST="$HOME/Library/LaunchAgents/com.quantdinger.backend.plist"
BACKUP_PLIST="$HOME/Library/LaunchAgents/com.quantdinger.backup.plist"
UID_NUM="$(id -u)"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

# --- Preflight -------------------------------------------------------------
# launchd agents cannot read ~/Documents, ~/Desktop or ~/Downloads (macOS TCC),
# so a repo living there starts fine by hand but dies under launchd with
# "Operation not permitted". Refuse early instead of debugging it later.
case "$REPO" in
  "$HOME"/Documents/*|"$HOME"/Desktop/*|"$HOME"/Downloads/*)
    die "Repo is under a TCC-protected folder ($REPO).
    Move it somewhere like ~/QuantDinger and re-run." ;;
esac

command -v brew >/dev/null || die "Homebrew required: https://brew.sh"

# Port 5000 is taken by the AirPlay Receiver on modern macOS; it answers 403
# from AirTunes and gunicorn cannot bind 0.0.0.0:5000.
if [ "$APP_PORT" = "5000" ]; then
  die "Port 5000 collides with the macOS AirPlay Receiver. Use QD_APP_PORT=8888."
fi

# --- Dependencies ----------------------------------------------------------
say "Installing $PG_FORMULA and $PY_FORMULA"
brew list --formula | grep -qx "$PG_FORMULA" || brew install "$PG_FORMULA"
brew list --formula | grep -qx "$PY_FORMULA" || brew install "$PY_FORMULA"

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

# Restore a pg_dump passed as QD_RESTORE_SQL=/path/to/dump.sql
if [ -n "${QD_RESTORE_SQL:-}" ]; then
  say "Restoring $QD_RESTORE_SQL"
  "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -U quantdinger -d quantdinger -q -f "$QD_RESTORE_SQL"
fi

say "Building the virtualenv"
cd "$BACKEND"
[ -d .venv ] || "$PY_BIN" -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r requirements.txt -i "$PIP_INDEX"
.venv/bin/python -c "import flask, pandas, ccxt, psycopg2" || die "Dependency check failed"

say "Writing .env"
[ -f .env ] || cp env.example .env
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)"
.venv/bin/python - "$PG_PORT" "$APP_PORT" "$REPO" "$LAN_IP" <<'PY'
import re, secrets, sys, pathlib
pg_port, app_port, repo, lan_ip = sys.argv[1:5]
p = pathlib.Path('.env'); s = p.read_text()
values = {
    'DATABASE_URL': f'postgresql://quantdinger:quantdinger123@127.0.0.1:{pg_port}/quantdinger',
    'CACHE_ENABLED': 'false',                       # no Redis in the native setup
    'SERVE_FRONTEND_DIR': f'{repo}/frontend/dist',  # Flask serves the SPA itself
    'FRONTEND_URL': f'http://localhost:{app_port},http://{lan_ip}:{app_port}',
}
if re.search(r'^SECRET_KEY=quantdinger-secret-key-change-me$', s, re.M):
    values['SECRET_KEY'] = secrets.token_hex(32)
for k, v in values.items():
    pat = re.compile(rf'^{k}=.*$', re.M)
    s = pat.sub(f'{k}={v}', s) if pat.search(s) else s + f'\n{k}={v}\n'
p.write_text(s)
PY

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
launchctl kickstart "gui/$UID_NUM/com.quantdinger.backend"

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

$(printf '\033[1;32mQuantDinger is running.\033[0m')

  Local      http://localhost:$APP_PORT
  LAN        http://$LAN_IP:$APP_PORT
  Login      see ADMIN_USER / ADMIN_PASSWORD in $BACKEND/.env

  Logs       tail -f $BACKEND/logs/launchd.err.log
  Restart    launchctl kickstart -k gui/$UID_NUM/com.quantdinger.backend
  Stop       launchctl bootout gui/$UID_NUM/com.quantdinger.backend
  Database   $PG_BIN/psql -h 127.0.0.1 -p $PG_PORT -U quantdinger -d quantdinger
  Backup     daily 03:30 into $HOME/qd_backup (keeps 14); run now with
             launchctl kickstart -w gui/$UID_NUM/com.quantdinger.backup

Optional — connect an MCP client (Hermes, Cursor, Claude Code):
  1. Open http://localhost:$APP_PORT/#/agent-tokens and issue a token with R + B scopes.
  2. Point the client at: uvx --from $REPO/mcp_server quantdinger-mcp
     with QUANTDINGER_BASE_URL=http://127.0.0.1:$APP_PORT and QUANTDINGER_AGENT_TOKEN=<token>.
EOF
