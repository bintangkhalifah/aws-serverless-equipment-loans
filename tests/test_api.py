"""Local tests for both microservices, using moto to fake DynamoDB and S3.

Run:  pip install -r requirements-dev.txt && pytest -v
"""
import json

import boto3
import pytest
from moto import mock_aws

from loan_read import handler as read_handler
from loan_write import handler as write_handler
from shared import store as store_mod

TOKEN = "test-token-not-a-real-secret"
LOAN = {"equipment_name": "Proyektor Epson", "borrower_name": "Bibin", "loan_date": "2026-11-26"}


# ---------- helpers to build events in both front-door formats ----------

def apigw_event(method, path, body=None, token=None):
    headers = {"content-type": "application/json"}
    if token:
        headers["x-api-key"] = token
    return {
        "version": "2.0",
        "rawPath": path,
        "headers": headers,
        "requestContext": {"http": {"method": method, "path": path}},
        "body": json.dumps(body) if body is not None else None,
        "isBase64Encoded": False,
    }


def alb_event(method, path, body=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["X-Api-Key"] = token
    return {
        "httpMethod": method,
        "path": path,
        "headers": headers,
        "body": json.dumps(body) if body is not None else "",
        "isBase64Encoded": False,
        "requestContext": {"elb": {"targetGroupArn": "arn:aws:elasticloadbalancing:..."}},
    }


def call(handler, event):
    resp = handler.lambda_handler(event, None)
    return resp["statusCode"], json.loads(resp["body"])


# ---------- fixtures ----------

@pytest.fixture(params=["dynamodb", "s3"])
def backend(request, monkeypatch):
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.setenv("API_TOKEN", TOKEN)
    monkeypatch.setenv("STORAGE_BACKEND", request.param)
    with mock_aws():
        if request.param == "dynamodb":
            boto3.client("dynamodb").create_table(
                TableName="loans",
                AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
                KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
                BillingMode="PAY_PER_REQUEST",
            )
            monkeypatch.setenv("LOANS_TABLE", "loans")
        else:
            boto3.client("s3").create_bucket(Bucket="loans-test-bucket")
            monkeypatch.setenv("LOANS_BUCKET", "loans-test-bucket")
        store_mod.reset_store()
        yield request.param
        store_mod.reset_store()


@pytest.fixture(params=[apigw_event, alb_event], ids=["apigw", "alb"])
def ev(request):
    return request.param


# ---------- CRUD ----------

def test_full_crud_flow(backend, ev):
    status, created = call(write_handler, ev("POST", "/loans", LOAN, TOKEN))
    assert status == 201
    loan_id = created["id"]
    assert created["status"] == "borrowed"
    assert created["return_date"] is None

    status, listing = call(read_handler, ev("GET", "/loans"))
    assert status == 200 and listing["count"] == 1
    assert listing["items"][0]["id"] == loan_id

    status, one = call(read_handler, ev("GET", f"/loans/{loan_id}"))
    assert status == 200 and one["equipment_name"] == "Proyektor Epson"

    status, updated = call(write_handler, ev("PUT", f"/loans/{loan_id}", {"status": "returned"}, TOKEN))
    assert status == 200
    assert updated["status"] == "returned"
    assert updated["return_date"]  # filled automatically

    status, deleted = call(write_handler, ev("DELETE", f"/loans/{loan_id}", None, TOKEN))
    assert status == 200 and deleted == {"deleted": loan_id}

    status, _ = call(read_handler, ev("GET", f"/loans/{loan_id}"))
    assert status == 404
    status, listing = call(read_handler, ev("GET", "/loans"))
    assert listing["count"] == 0


def test_data_survives_cold_start(backend, ev):
    _, created = call(write_handler, ev("POST", "/loans", LOAN, TOKEN))
    store_mod.reset_store()  # new execution environment, empty memory
    status, one = call(read_handler, ev("GET", f"/loans/{created['id']}"))
    assert status == 200 and one["borrower_name"] == "Bibin"


def test_health(backend, ev):
    status, body = call(read_handler, ev("GET", "/health"))
    assert status == 200 and body["service"] == "loan-read"


# ---------- validation ----------

@pytest.mark.parametrize("bad", [
    {"borrower_name": "A", "loan_date": "2026-11-26"},                      # missing equipment
    {"equipment_name": "X", "borrower_name": "A", "loan_date": "26-11-2026"},  # bad date
    {"equipment_name": "X", "borrower_name": "A", "loan_date": "2026-13-40"},  # impossible date
    {"equipment_name": " ", "borrower_name": "A", "loan_date": "2026-11-26"},  # blank
    {"equipment_name": "X", "borrower_name": "A", "loan_date": "2026-11-26", "status": "lost"},
])
def test_create_rejects_bad_input(backend, bad):
    status, body = call(write_handler, apigw_event("POST", "/loans", bad, TOKEN))
    assert status == 400 and "error" in body


def test_invalid_json_body(backend):
    event = apigw_event("POST", "/loans", None, TOKEN)
    event["body"] = "{not json"
    status, _ = call(write_handler, event)
    assert status == 400


def test_update_rejects_bad_status_and_empty(backend):
    _, created = call(write_handler, apigw_event("POST", "/loans", LOAN, TOKEN))
    path = f"/loans/{created['id']}"
    assert call(write_handler, apigw_event("PUT", path, {"status": "lost"}, TOKEN))[0] == 400
    assert call(write_handler, apigw_event("PUT", path, {"id": "hacked"}, TOKEN))[0] == 400


def test_id_cannot_be_overwritten(backend):
    _, created = call(write_handler, apigw_event("POST", "/loans", LOAN, TOKEN))
    path = f"/loans/{created['id']}"
    _, updated = call(write_handler, apigw_event("PUT", path, {"id": "x", "borrower_name": "Budi"}, TOKEN))
    assert updated["id"] == created["id"] and updated["borrower_name"] == "Budi"


def test_missing_items_return_404(backend):
    assert call(read_handler, apigw_event("GET", "/loans/nope"))[0] == 404
    assert call(write_handler, apigw_event("PUT", "/loans/nope", {"status": "returned"}, TOKEN))[0] == 404
    assert call(write_handler, apigw_event("DELETE", "/loans/nope", None, TOKEN))[0] == 404


# ---------- security ----------

def test_write_requires_token(backend, ev):
    assert call(write_handler, ev("POST", "/loans", LOAN))[0] == 401
    assert call(write_handler, ev("POST", "/loans", LOAN, "wrong"))[0] == 401
    assert call(read_handler, ev("GET", "/loans"))[1]["count"] == 0  # nothing was written


def test_write_fails_closed_when_token_not_configured(backend, monkeypatch):
    monkeypatch.delenv("API_TOKEN")
    status, _ = call(write_handler, apigw_event("POST", "/loans", LOAN, TOKEN))
    assert status == 500


def test_services_are_separated(backend):
    assert call(read_handler, apigw_event("POST", "/loans", LOAN, TOKEN))[0] == 405
    assert call(write_handler, apigw_event("GET", "/loans"))[0] == 405


# ---------- failure and recovery ----------

def test_write_failure_does_not_break_read(backend, monkeypatch):
    """Break only the write service's storage setting; read keeps working."""
    _, created = call(write_handler, apigw_event("POST", "/loans", LOAN, TOKEN))

    good_table = "loans"
    good_bucket = "loans-test-bucket"
    if backend == "dynamodb":
        monkeypatch.setenv("LOANS_TABLE", "wrong-table")
    else:
        monkeypatch.setenv("LOANS_BUCKET", "wrong-bucket")
    store_mod.reset_store()
    assert call(write_handler, apigw_event("POST", "/loans", LOAN, TOKEN))[0] == 500

    # recovery
    if backend == "dynamodb":
        monkeypatch.setenv("LOANS_TABLE", good_table)
    else:
        monkeypatch.setenv("LOANS_BUCKET", good_bucket)
    store_mod.reset_store()
    assert call(write_handler, apigw_event("POST", "/loans", LOAN, TOKEN))[0] == 201
    assert call(read_handler, apigw_event("GET", "/loans"))[1]["count"] == 2
    assert created["id"]
