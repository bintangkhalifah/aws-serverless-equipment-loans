"""Helpers to read requests and build responses.

The same Lambda code can sit behind two kinds of front doors:
  * Amazon API Gateway (HTTP API, payload format 2.0)
  * Application Load Balancer (Lambda target)
Their event shapes differ, so parse_event() turns both into one simple dict.
"""
import base64
import json
import re

_ID_PATH = re.compile(r"^/loans/([^/]+)$")

_REASONS = {
    200: "OK",
    201: "Created",
    400: "Bad Request",
    401: "Unauthorized",
    404: "Not Found",
    405: "Method Not Allowed",
    500: "Internal Server Error",
}


def parse_event(event):
    """Return {method, path, loan_id, headers, body} from an API Gateway or ALB event."""
    http = (event.get("requestContext") or {}).get("http") or {}
    method = (http.get("method") or event.get("httpMethod") or "").upper()
    path = http.get("path") or event.get("rawPath") or event.get("path") or "/"
    if len(path) > 1:
        path = path.rstrip("/")

    headers = {str(k).lower(): v for k, v in (event.get("headers") or {}).items()}

    body = event.get("body") or ""
    if event.get("isBase64Encoded") and body:
        body = base64.b64decode(body).decode("utf-8")

    match = _ID_PATH.match(path)
    return {
        "method": method,
        "path": path,
        "loan_id": match.group(1) if match else None,
        "headers": headers,
        "body": body,
    }


def parse_json_body(raw):
    """Parse a JSON object body. Raises ValueError if it is not a JSON object."""
    try:
        data = json.loads(raw) if raw else None
    except json.JSONDecodeError:
        raise ValueError("body must be valid JSON")
    if not isinstance(data, dict):
        raise ValueError("body must be a JSON object")
    return data


def response(status, payload):
    return {
        "statusCode": status,
        "statusDescription": f"{status} {_REASONS.get(status, '')}".strip(),
        "isBase64Encoded": False,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload, default=str),
    }
