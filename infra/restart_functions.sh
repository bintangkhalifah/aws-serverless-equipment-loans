#!/usr/bin/env bash
# "Restart" for serverless: a configuration change makes Lambda discard the running
# execution environments, so the next request is a cold start with empty memory.
# Used in the persistence test: data written before must still be readable afterwards.
set -euo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
STAMP="$(date +%s)"
python3 "$HERE/lambda_env.py" set loan-read  RESTARTED_AT="$STAMP"
python3 "$HERE/lambda_env.py" set loan-write RESTARTED_AT="$STAMP"
echo "Both functions restarted. Now read the data again (GET /loans)."
