#!/usr/bin/env bash
# End-to-end test against the deployed API.
#
#   ./tests/smoke_test.sh | tee evidence/smoke-test-output.txt
#
# BASE_URL and the API token are read from the environment, or from the files
# written by infra/deploy.sh (~/.loans_base_url, ~/.loans_token).
# The token is sent as a header but never printed.
set -uo pipefail

BASE_URL="${BASE_URL:-$(cat "$HOME/.loans_base_url" 2>/dev/null || true)}"
TOKEN="${API_TOKEN:-$(cat "$HOME/.loans_token" 2>/dev/null || true)}"
[ -n "$BASE_URL" ] || { echo "BASE_URL is not set" >&2; exit 2; }
[ -n "$TOKEN" ]    || { echo "API_TOKEN is not set" >&2; exit 2; }

PASS=0; FAIL=0
BODY="$(mktemp)"; trap 'rm -f "$BODY"' EXIT

# call METHOD PATH EXPECTED_STATUS [JSON] [use-token: yes|no]
call() {
  local method="$1" path="$2" expect="$3" data="${4:-}" auth="${5:-no}"
  local args=(-s -o "$BODY" -w '%{http_code}' -X "$method" "$BASE_URL$path" -H 'Content-Type: application/json')
  [ "$auth" = "yes" ] && args+=(-H "x-api-key: $TOKEN")
  [ -n "$data" ] && args+=(-d "$data")
  local status; status="$(curl "${args[@]}")"
  if [ "$status" = "$expect" ]; then PASS=$((PASS+1)); mark="PASS"; else FAIL=$((FAIL+1)); mark="FAIL"; fi
  echo "[$mark] $method $path -> HTTP $status (expected $expect)"
  cat "$BODY"; echo; echo
}

echo "== Smoke test: $BASE_URL =="; echo "Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo

echo "-- 1. Health check (loan-read)"
call GET /health 200

echo "-- 2. Security: write without token must be rejected"
call POST /loans 401 '{"equipment_name":"Proyektor","borrower_name":"Bibin","loan_date":"2026-11-26"}' no

echo "-- 3. CREATE (loan-write)"
call POST /loans 201 '{"equipment_name":"Proyektor Epson","borrower_name":"Bibin","loan_date":"2026-11-26"}' yes
LOAN_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$BODY" 2>/dev/null || true)"
[ -n "$LOAN_ID" ] || { echo "Could not read the new loan id; stopping."; exit 1; }

echo "-- 4. READ list and single item (loan-read)"
call GET /loans 200
call GET "/loans/$LOAN_ID" 200

echo "-- 5. UPDATE: mark as returned (loan-write)"
call PUT "/loans/$LOAN_ID" 200 '{"status":"returned"}' yes

echo "-- 6. Validation: bad date must give 400"
call POST /loans 400 '{"equipment_name":"Kamera","borrower_name":"Budi","loan_date":"26-11-2026"}' yes

echo "-- 7. DELETE (loan-write), then the item must be gone"
call DELETE "/loans/$LOAN_ID" 200 "" yes
call GET "/loans/$LOAN_ID" 404

echo "== Result: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
