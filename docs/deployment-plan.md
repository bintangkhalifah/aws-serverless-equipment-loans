# Deployment plan

Target: AWS Academy Cloud Foundations Sandbox, region `us-east-1`.
All commands run in AWS CloudShell (or the sandbox Lab IDE terminal) from the repo root.

## 0. Before starting the lab

- [ ] Repository is on GitHub and public (or readable for the lecturer).
- [ ] `pytest` passes on the laptop.
- [ ] Architecture diagram and design brief are ready.
- [ ] Screen recorder is ready for the demo video.

## 1. Check which services the sandbox allows

Open each console page in `us-east-1` and note whether it loads or shows an access error:

| Service | Result | Decision |
|---|---|---|
| Lambda (Create function form opens) | | required |
| API Gateway | | if blocked, use the ALB front door |
| DynamoDB | | if blocked, use S3 storage |
| S3 | | needed only for the S3 variant |
| EC2 > Load Balancers | | needed only for the ALB variant |
| CloudWatch Logs | | observability |

Choose one variant:

| Variant | Command |
|---|---|
| A. API Gateway + DynamoDB (slide) | `./infra/deploy.sh` |
| B. API Gateway + S3 | `STORAGE_BACKEND=s3 ./infra/deploy.sh` |
| C. ALB + DynamoDB | `API_FRONT=alb ./infra/deploy.sh` |
| D. ALB + S3 | `API_FRONT=alb STORAGE_BACKEND=s3 ./infra/deploy.sh` |

## 2. Get the code into the sandbox

```bash
git clone https://github.com/<github-user>/<repo-name>.git
cd <repo-name>
```

## 3. Deploy

```bash
./infra/deploy.sh          # add the variables from the table above if needed
```

What the script does, in order:

1. Packages `loan-read.zip` and `loan-write.zip` (`infra/build.py`).
2. Creates storage: DynamoDB table `loans` (key `id`, on-demand) or an S3 bucket
   `equipment-loans-<account-id>` with Block Public Access.
3. Creates two Lambda functions with the existing `LabRole`, handler `handler.lambda_handler`,
   10 s timeout, 128 MB. `loan-write` also gets the `API_TOKEN` environment variable.
4. Creates the front door:
   - API Gateway: HTTP API with route `GET /health`, `GET /loans`, `GET /loans/{id}` to
     `loan-read` and `POST /loans`, `PUT /loans/{id}`, `DELETE /loans/{id}` to `loan-write`,
     `$default` stage with auto-deploy.
   - ALB: security group (HTTP 80), two Lambda target groups, listener with rules by HTTP method
     and path.
5. Grants the front door permission to invoke each function.
6. Prints the base URL and saves it to `~/.loans_base_url`.

## 4. Verify connectivity (Week 12 evidence)

```bash
curl "$(cat ~/.loans_base_url)/health"
./tests/smoke_test.sh | tee evidence/smoke-test-output.txt
```

## 5. Full verification (Week 14 evidence)

1. Smoke test (create, read, update, delete, validation, 401 without token).
2. Persistence: `./tests/persistence_test.sh write`, then `./infra/restart_functions.sh`, then
   `./tests/persistence_test.sh check`.
3. Failure and recovery: `./infra/failure_demo.sh break`, run the smoke test (writes fail, reads
   work), `./infra/failure_demo.sh restore`, run the smoke test again.
4. Logs: CloudWatch Logs > `/aws/lambda/loan-read` and `/aws/lambda/loan-write`.

## 6. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `AccessDenied` on API Gateway or DynamoDB | service blocked in the sandbox | use the alternative variant |
| `curl` returns `{"message":"Internal Server Error"}` | Lambda error | check the function's CloudWatch log |
| `401` on POST | wrong or missing token | `export API_TOKEN=$(cat ~/.loans_token)` |
| `500` on POST only | `loan-write` misconfigured | `./infra/failure_demo.sh restore` or redeploy |
| ALB returns 503 right after deploy | targets still registering | wait one minute and retry |
| `ResourceConflictException` during deploy | resource already exists | run `./infra/teardown.sh` then deploy again |

## 7. Cleanup (before submitting)

```bash
./infra/teardown.sh
rm -f ~/.loans_token
```

Confirm in the console that no Lambda function, API, load balancer, table or bucket is left.
