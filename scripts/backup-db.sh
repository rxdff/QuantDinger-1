#!/usr/bin/env bash
# Dump the QuantDinger database for migration to another machine.
# Restore with: QD_RESTORE_SQL=<file> ./scripts/install-native-macos.sh
set -euo pipefail
PG_PORT="${QD_PG_PORT:-5433}"
KEEP="${QD_KEEP:-14}"
OUT="${1:-$HOME/qd_backup/qd_$(date +%Y%m%d_%H%M).sql}"
mkdir -p "$(dirname "$OUT")"
# Resolve pg_dump directly. `brew --prefix` reaches for the network when it
# runs with a cold cache under an unusual HOME, and on failure it expands to a
# bare "/bin/pg_dump".
PG_DUMP=""
for candidate in /opt/homebrew/opt/postgresql@16/bin/pg_dump \
                 /usr/local/opt/postgresql@16/bin/pg_dump; do
  [ -x "$candidate" ] && { PG_DUMP="$candidate"; break; }
done
[ -n "$PG_DUMP" ] || PG_DUMP="$(command -v pg_dump || true)"
[ -n "$PG_DUMP" ] || { echo "pg_dump not found" >&2; exit 1; }

# Dump aside and promote only once the file is proven complete. A truncated
# dump that looks like a backup is worse than no backup, and the pruning below
# must never trade good copies for a broken one.
TMP="$OUT.partial"
trap 'rm -f "$TMP"' EXIT
"$PG_DUMP" -h 127.0.0.1 -p "$PG_PORT" \
  -U quantdinger -d quantdinger --no-owner --no-acl > "$TMP"
grep -q "PostgreSQL database dump complete" "$TMP" \
  || { echo "Dump is incomplete; keeping previous backups" >&2; exit 1; }
mv "$TMP" "$OUT"
# A dump carries password hashes and whatever keys live in the database.
chmod 600 "$OUT"
echo "Wrote $OUT"

# Unattended runs would otherwise fill the disk. An explicit $1 is left alone.
if [ -z "${1:-}" ] && [ "$KEEP" -gt 0 ]; then
  ls -t "$HOME/qd_backup"/qd_*.sql 2>/dev/null | tail -n "+$((KEEP + 1))" | while read -r old; do
    rm -f "$old" && echo "Pruned $old"
  done
fi
