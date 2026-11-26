# Demo video script (3 to 5 minutes)

Goal from the slide: working application, AWS console walkthrough, explain architecture and
trade-offs. Flow: live endpoint, CRUD, stored data, AWS resources, test evidence.

Tips: record one browser window (AWS console) and one terminal; zoom the terminal font; hide the
token; speak slowly. Do a dry run first. Target length 4 minutes.

| Time | On screen | What to say (own words) |
|---|---|---|
| 0:00 - 0:25 | Architecture diagram | Name, use case (equipment loans), Track C serverless. One sentence on the flow: client, API entry point, two Lambda functions, storage. Say that the API is split into `loan-read` and `loan-write`. |
| 0:25 - 1:40 | Terminal: smoke test or manual `curl` | Show `/health`. POST a loan (with token), GET the list, GET one item, PUT status `returned`, DELETE it, then GET returns 404. Mention the validation error (bad date gives 400). |
| 1:40 - 2:15 | DynamoDB or S3 console | Show the stored item after a POST, so the data is really in AWS storage, not in memory. |
| 2:15 - 3:00 | Lambda, API Gateway/ALB, IAM, CloudWatch | Show the two functions, the routes (which method goes to which function), the execution role `LabRole`, the environment variable list with the token hidden, and the CloudWatch log lines. |
| 3:00 - 3:30 | Terminal: persistence | `persistence_test.sh write`, `restart_functions.sh`, `persistence_test.sh check` returns PASS: data survives a restart. |
| 3:30 - 4:20 | Terminal: failure and recovery | `failure_demo.sh break`: POST returns 500 but GET still returns 200 (benefit of microservices). `failure_demo.sh restore`: POST works again. |
| 4:20 - 4:50 | Diagram or README | Trade-offs: serverless means no servers to manage and pay-per-use, but cold starts and a shared `LabRole`; token in a header is simple but not full authentication; scan is fine for a demo only. If the alternative services were used, explain why (sandbox restriction). Mention cleanup (`teardown.sh`). |

## Commands in order (copy to a notes file next to the recorder)

```bash
export BASE_URL=$(cat ~/.loans_base_url); export API_TOKEN=$(cat ~/.loans_token)
curl $BASE_URL/health
./tests/smoke_test.sh
./tests/persistence_test.sh write
./infra/restart_functions.sh
./tests/persistence_test.sh check
./infra/failure_demo.sh break
curl -i -X POST $BASE_URL/loans -H "Content-Type: application/json" -H "x-api-key: $API_TOKEN" -d '{"equipment_name":"Kamera","borrower_name":"Budi","loan_date":"2026-11-26"}'
curl $BASE_URL/loans
./infra/failure_demo.sh restore
./tests/smoke_test.sh
```

Do not run `echo $API_TOKEN` or `cat ~/.loans_token` on camera.
