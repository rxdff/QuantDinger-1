#!/usr/bin/env bash
# Dump the QuantDinger database for migration to another machine.
# Restore with: QD_RESTORE_SQL=<file> ./scripts/install-native-macos.sh
set -euo pipefail
PG_PORT="${QD_PG_PORT:-5433}"
OUT="${1:-$HOME/qd_backup/qd_$(date +%Y%m%d_%H%M).sql}"
mkdir -p "$(dirname "$OUT")"
"$(brew --prefix postgresql@16)/bin/pg_dump" -h 127.0.0.1 -p "$PG_PORT" \
  -U quantdinger -d quantdinger --no-owner --no-acl > "$OUT"
echo "Wrote $OUT"
