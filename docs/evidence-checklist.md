# Evidence checklist

Save screenshots in `evidence/` with the file names below. Never show the API token
(`~/.loans_token`) or any password. Do not run `cat ~/.loans_token` on screen.

## Week 12: initial AWS infrastructure and connectivity

| File name | What to capture |
|---|---|
| `w12-01-lambda-functions.png` | Lambda console: `loan-read` and `loan-write` listed (region visible) |
| `w12-02-storage.png` | DynamoDB table `loans` (Overview) or the S3 bucket |
| `w12-03-front-door.png` | API Gateway routes page, or the ALB listener rules |
| `w12-04-iam-role.png` | A function's Configuration > Permissions showing execution role `LabRole` |
| `w12-05-health-check.png` | Terminal: `curl <base-url>/health` returning `{"status": "ok", ...}` |
| `smoke-test-output.txt` | Output of `./tests/smoke_test.sh` (proves read and write reach storage) |
| `w12-06-first-item-in-storage.png` | DynamoDB "Explore items" (or S3 object list) after a POST |

## Week 14: working application

| File name | What to capture |
|---|---|
| `w14-01-crud-curl.png` | Terminal showing POST, GET, PUT, DELETE results |
| `smoke-test-output.txt` | Final full run: all tests PASS |
| `w14-02-security-401.png` | POST without token returning 401 |
| `w14-03-env-vars-masked.png` | `loan-write` environment variables with the token value hidden |
| `persistence-output.txt` | Output of `./tests/persistence_test.sh check` after the restart |
| `w14-04-failure-500.png` | Terminal: writes return 500 while `GET /loans` returns 200 |
| `w14-05-recovery.png` | Terminal: smoke test passing again after `restore` |
| `w14-06-cloudwatch-logs.png` | CloudWatch log stream of `loan-write` with the JSON request lines |
| `w14-07-cleanup.png` | Console showing no Lambda functions, APIs, tables or buckets after `teardown.sh` |

## Before submitting

- [ ] Search the repository for secrets: `git grep -n -i -E "token|password|secret|AKIA"` shows no real value.
- [ ] No `.pem`, `.env` or token file is tracked: `git ls-files | grep -E "\.pem$|\.ppk$|\.env$|\.token$"` shows nothing
      except `.gitignore`.
- [ ] Screenshots show the region (`us-east-1`) and the resource names.
- [ ] Resources cleaned up with `./infra/teardown.sh`.
