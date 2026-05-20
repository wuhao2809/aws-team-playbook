"""TeamGram SQS consumer.

Triggered by SQS. For each message, parse the post payload, do light
sanitization, and write to DynamoDB. Failures are raised so SQS retries
(and eventually sends to a DLQ if one is configured).
"""

import json
import os

import boto3

REGION = os.environ["AWS_REGION"]
TABLE_NAME = os.environ["DDB_TABLE"]

ddb = boto3.resource("dynamodb", region_name=REGION).Table(TABLE_NAME)

MAX_LEN = 240


def _clean(value: str) -> str:
    return value.replace("\n", " ").replace("\r", " ").strip()[:MAX_LEN]


def handler(event, _context):
    for record in event.get("Records", []):
        body = json.loads(record["body"])

        item = {
            "id": body["id"],
            "created_at": body["created_at"],
            "name": _clean(body["name"]),
            "team": _clean(body["team"]),
            "hobby": _clean(body["hobby"]),
            "dream": _clean(body["dream"]),
            "useful": _clean(body["useful"]),
            "useless": _clean(body["useless"]),
        }

        ddb.put_item(Item=item)

    return {"processed": len(event.get("Records", []))}
