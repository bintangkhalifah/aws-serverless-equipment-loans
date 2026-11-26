"""Storage layer. The backend is chosen with the STORAGE_BACKEND environment variable.

  dynamodb (default)  table name from LOANS_TABLE
  s3                  bucket name from LOANS_BUCKET, one JSON object per loan

DynamoDB is the planned service. S3 is the equivalent alternative if DynamoDB
is not available in the AWS Academy sandbox.
"""
import json
import os

import boto3
from botocore.exceptions import ClientError


class DynamoStore:
    def __init__(self, table_name=None):
        name = table_name or os.environ["LOANS_TABLE"]
        self._table = boto3.resource("dynamodb").Table(name)

    def put(self, item):
        self._table.put_item(Item=item)

    def get(self, loan_id):
        return self._table.get_item(Key={"id": loan_id}).get("Item")

    def list(self):
        items = []
        kwargs = {}
        while True:
            page = self._table.scan(**kwargs)
            items.extend(page.get("Items", []))
            if "LastEvaluatedKey" not in page:
                return items
            kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]

    def delete(self, loan_id):
        resp = self._table.delete_item(Key={"id": loan_id}, ReturnValues="ALL_OLD")
        return "Attributes" in resp


class S3Store:
    PREFIX = "loans/"

    def __init__(self, bucket=None):
        self._bucket = bucket or os.environ["LOANS_BUCKET"]
        self._s3 = boto3.client("s3")

    def _key(self, loan_id):
        return f"{self.PREFIX}{loan_id}.json"

    def put(self, item):
        self._s3.put_object(
            Bucket=self._bucket,
            Key=self._key(item["id"]),
            Body=json.dumps(item).encode("utf-8"),
            ContentType="application/json",
        )

    def get(self, loan_id):
        try:
            obj = self._s3.get_object(Bucket=self._bucket, Key=self._key(loan_id))
        except ClientError as err:
            if err.response["Error"]["Code"] == "NoSuchKey":
                return None
            raise
        return json.loads(obj["Body"].read())

    def list(self):
        items = []
        paginator = self._s3.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=self._bucket, Prefix=self.PREFIX):
            for entry in page.get("Contents", []):
                body = self._s3.get_object(Bucket=self._bucket, Key=entry["Key"])["Body"]
                items.append(json.loads(body.read()))
        return items

    def delete(self, loan_id):
        if self.get(loan_id) is None:
            return False
        self._s3.delete_object(Bucket=self._bucket, Key=self._key(loan_id))
        return True


_STORE = None


def get_store():
    """Create the store once per Lambda execution environment and reuse it."""
    global _STORE
    if _STORE is None:
        backend = os.environ.get("STORAGE_BACKEND", "dynamodb").lower()
        if backend == "dynamodb":
            _STORE = DynamoStore()
        elif backend == "s3":
            _STORE = S3Store()
        else:
            raise RuntimeError(f"unknown STORAGE_BACKEND: {backend}")
    return _STORE


def reset_store():
    """Used by tests to force a fresh store (simulates a cold start)."""
    global _STORE
    _STORE = None


def sorted_loans(items):
    return sorted(items, key=lambda x: (x.get("created_at", ""), x.get("id", "")))
