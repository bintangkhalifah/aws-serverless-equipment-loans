#!/usr/bin/env bash
# Failure and recovery scenario for the demo.
#
#   ./infra/failure_demo.sh break     # point loan-write at storage that does not exist
#   ./infra/failure_demo.sh restore   # put the correct storage settings back
#
# While broken: POST/PUT/DELETE return HTTP 500, but GET still works,
# because loan-read is a separate function with its own configuration.
set -euo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

case "${1:-}" in
  break)
    python3 "$HERE/lambda_env.py" set loan-write LOANS_TABLE=loans-does-not-exist LOANS_BUCKET=bucket-does-not-exist
    echo "loan-write is now broken. Run ./tests/smoke_test.sh or curl a POST to see the 500."
    ;;
  restore)
    python3 "$HERE/lambda_env.py" set loan-write LOANS_TABLE=loans "LOANS_BUCKET=equipment-loans-${ACCOUNT_ID}"
    echo "loan-write is restored."
    ;;
  *)
    echo "usage: $0 break|restore" >&2; exit 1 ;;
esac
