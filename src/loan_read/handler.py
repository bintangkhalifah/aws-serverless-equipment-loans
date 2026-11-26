"""loan-read microservice: read-only endpoints.

  GET /health
  GET /loans
  GET /loans/{id}

This function only needs read access to storage and never changes data.
"""
import json
import logging

from shared import http
from shared.store import get_store, sorted_loans

SERVICE = "loan-read"
logger = logging.getLogger()
logger.setLevel(logging.INFO)


def _route(req):
    method, path, loan_id = req["method"], req["path"], req["loan_id"]

    if path == "/health":
        if method != "GET":
            return http.response(405, {"error": "method not allowed"})
        return http.response(200, {"status": "ok", "service": SERVICE})

    if path == "/loans":
        if method != "GET":
            return http.response(405, {"error": "method not allowed"})
        items = sorted_loans(get_store().list())
        return http.response(200, {"count": len(items), "items": items})

    if loan_id:
        if method != "GET":
            return http.response(405, {"error": "method not allowed"})
        item = get_store().get(loan_id)
        if item is None:
            return http.response(404, {"error": "loan not found"})
        return http.response(200, item)

    return http.response(404, {"error": "route not found"})


def lambda_handler(event, context):
    req = http.parse_event(event)
    try:
        resp = _route(req)
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
