"""loan-write microservice: endpoints that change data.

  POST   /loans
  PUT    /loans/{id}
  DELETE /loans/{id}

Every request must carry the header  x-api-key: <token>.
The token is set as the API_TOKEN environment variable of this function
(from the console or deploy script), never stored in Git.
"""
import hmac
import json
import logging
import os

from shared import http
from shared.loans import ValidationError, apply_update, build_new_loan
from shared.store import get_store

SERVICE = "loan-write"
logger = logging.getLogger()
logger.setLevel(logging.INFO)


def _authorize(req):
    """Return an error response, or None when the caller is allowed."""
    expected = os.environ.get("API_TOKEN")
    if not expected:
        logger.error("API_TOKEN is not configured")
        return http.response(500, {"error": "service is not configured"})
    given = req["headers"].get("x-api-key", "")
    if not hmac.compare_digest(given.encode("utf-8"), expected.encode("utf-8")):
        return http.response(401, {"error": "missing or invalid x-api-key"})
    return None


def _route(req):
    method, path, loan_id = req["method"], req["path"], req["loan_id"]

    known = path == "/loans" or loan_id is not None
    if not known:
        return http.response(404, {"error": "route not found"})

    allowed = ("POST",) if path == "/loans" else ("PUT", "DELETE")
    if method not in allowed:
        return http.response(405, {"error": "method not allowed"})

    denied = _authorize(req)
    if denied:
        return denied

    store = get_store()

    if method == "POST":
        loan = build_new_loan(http.parse_json_body(req["body"]))
        store.put(loan)
        return http.response(201, loan)

    existing = store.get(loan_id)
    if existing is None:
        return http.response(404, {"error": "loan not found"})

    if method == "PUT":
        loan = apply_update(existing, http.parse_json_body(req["body"]))
        store.put(loan)
        return http.response(200, loan)

    store.delete(loan_id)
    return http.response(200, {"deleted": loan_id})


def lambda_handler(event, context):
    req = http.parse_event(event)
    try:
        resp = _route(req)
    except (ValidationError, ValueError) as err:
        resp = http.response(400, {"error": str(err)})
    except Exception:
        logger.exception("unhandled error")
        resp = http.response(500, {"error": "internal error"})
    logger.info(json.dumps({
        "service": SERVICE,
        "method": req["method"],
        "path": req["path"],
        "status": resp["statusCode"],
    }))
    return resp
