#!/usr/bin/env bash
# Persistence test: data must survive a restart of the functions.
#
#   ./tests/persistence_test.sh write     # 1. create a loan and remember its id
#   ./infra/restart_functions.sh          # 2. discard the running execution environments
#   ./tests/persistence_test.sh check     # 3. read the same loan back
#
# Save the output with:  ./tests/persistence_test.sh check | tee -a evidence/persistence-output.txt
set -uo pipefail

BASE_URL="${BASE_URL:-$(cat "$HOME/.loans_base_url" 2>/dev/null || true)}"
TOKEN="${API_TOKEN:-$(cat "$HOME/.loans_token" 2>/dev/null || true)}"
ID_FILE="$HOME/.loans_persist_id"
[ -n "$BASE_URL" ] && [ -n "$TOKEN" ] || { echo "BASE_URL or API_TOKEN missing" >&2; exit 2; }

case "${1:-}" in
  write)
    out="$(curl -s -X POST "$BASE_URL/loans" -H 'Content-Type: application/json' -H "x-api-key: $TOKEN" \
      -d '{"equipment_name":"Tes Persistensi","borrower_name":"Bibin","loan_date":"2026-11-26"}')"
    echo "$out"
    python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$out" > "$ID_FILE" \
      && echo "WRITE ok. Saved id to $ID_FILE. Now run ./infra/restart_functions.sh"
    ;;
  check)
    [ -s "$ID_FILE" ] || { echo "run '$0 write' first" >&2; exit 2; }
    id="$(cat "$ID_FILE")"
    status="$(curl -s -o /tmp/persist.json -w '%{http_code}' "$BASE_URL/loans/$id")"
    cat /tmp/persist.json; echo
    if [ "$status" = "200" ]; then echo "[PASS] loan $id still exists after restart"; else echo "[FAIL] HTTP $status"; exit 1; fi
    ;;
  *)
    echo "usage: $0 write|check" >&2; exit 1 ;;
esac
