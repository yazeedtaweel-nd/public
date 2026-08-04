#!/usr/bin/env bash
# Apply numbered etl-control migrations to the existing DWH database (Approach 2).
#
# Usage:
#   ./apply-migrations.sh -S SQLDWH01 -d SaudiRe_DW
#   ./apply-migrations.sh -S SQLDWH01 -d SaudiRe_DW -U sa -P '***'
#
# Requires: sqlcmd on PATH (mssql-tools18 / brew sqlcmd)

set -euo pipefail

SERVER=""
DATABASE=""
USERNAME=""
PASSWORD=""
TRUSTED=1

usage() {
  echo "Usage: $0 -S <server> -d <database> [-U <user> -P <password>]" >&2
  exit 1
}

while getopts "S:d:U:P:h" opt; do
  case "$opt" in
    S) SERVER="$OPTARG" ;;
    d) DATABASE="$OPTARG" ;;
    U) USERNAME="$OPTARG"; TRUSTED=0 ;;
    P) PASSWORD="$OPTARG" ;;
    h|*) usage ;;
  esac
done

[[ -n "$SERVER" && -n "$DATABASE" ]] || usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ETL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MIGRATIONS_DIR="$ETL_ROOT/migrations"
BOOTSTRAP_SQL="$SCRIPT_DIR/bootstrap_ledger.sql"

[[ -d "$MIGRATIONS_DIR" ]] || { echo "Migrations folder not found: $MIGRATIONS_DIR" >&2; exit 1; }
[[ -f "$BOOTSTRAP_SQL" ]] || { echo "Bootstrap script not found: $BOOTSTRAP_SQL" >&2; exit 1; }

auth_args=()
if [[ "$TRUSTED" -eq 1 ]]; then
  auth_args+=(-E)
else
  [[ -n "$USERNAME" ]] || { echo "Username required with -U" >&2; exit 1; }
  auth_args+=(-U "$USERNAME" -P "$PASSWORD")
fi

run_file() {
  local path="$1"
  sqlcmd -S "$SERVER" -d "$DATABASE" -b -I "${auth_args[@]}" -i "$path"
}

run_query() {
  local query="$1"
  sqlcmd -S "$SERVER" -d "$DATABASE" -b -h -1 -W "${auth_args[@]}" -Q "$query"
}

echo "Bootstrapping ledger on $SERVER / $DATABASE ..."
run_file "$BOOTSTRAP_SQL"

shopt -s nullglob
files=("$MIGRATIONS_DIR"/*.sql)
IFS=$'\n' files_sorted=($(printf '%s\n' "${files[@]}" | sort))
unset IFS

if [[ ${#files_sorted[@]} -eq 0 ]]; then
  echo "No migration scripts found in $MIGRATIONS_DIR"
  exit 0
fi

for path in "${files_sorted[@]}"; do
  name="$(basename "$path")"
  escaped="${name//\'/\'\'}"

  count="$(run_query "SET NOCOUNT ON; SELECT COUNT(1) FROM etl.SCHEMA_MIGRATION WHERE SCRIPT_NAME = N'$escaped';" \
    | tr -d '[:space:]' | grep -E '^[0-9]+$' | head -n1 || true)"
  count="${count:-0}"

  if [[ "$count" -gt 0 ]]; then
    echo "SKIP  $name (already applied)"
    continue
  fi

  echo "APPLY $name ..."
  run_file "$path"
  run_query "SET NOCOUNT ON; INSERT INTO etl.SCHEMA_MIGRATION (SCRIPT_NAME) VALUES (N'$escaped');" >/dev/null
  echo "OK    $name"
done

echo "Done. Applied migrations ledger:"
run_query "SET NOCOUNT ON; SELECT SCRIPT_NAME, CONVERT(varchar(30), APPLIED_DATE, 126), APPLIED_BY FROM etl.SCHEMA_MIGRATION ORDER BY SCRIPT_NAME;"
