"""TeamGram API — runs on ECS Fargate behind the ALB.

GET  /        renders the class wall from DynamoDB
POST /intro   validates the form and enqueues the post on SQS
GET  /health  ALB health check
"""

import json
import os
import uuid
from datetime import datetime, timezone

import boto3
from flask import Flask, abort, redirect, render_template_string, request

app = Flask(__name__)

REGION = os.environ["AWS_REGION"]
TABLE_NAME = os.environ["DDB_TABLE"]
QUEUE_URL = os.environ["SQS_URL"]

ddb = boto3.resource("dynamodb", region_name=REGION).Table(TABLE_NAME)
sqs = boto3.client("sqs", region_name=REGION)


WALL_HTML = """<!doctype html>
<html><head><meta charset="utf-8"><title>TeamGram</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 900px; margin: 2em auto; padding: 0 1em; background: #fafafa; }
  h1 { font-size: 2.5em; margin-bottom: 0; }
  .sub { color: #666; margin-bottom: 2em; }
  form { background: #fff; padding: 1.5em; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,.08); margin-bottom: 2em; }
  form label { display: block; margin: .6em 0 .2em; font-size: .9em; color: #333; }
  form input { width: 100%; padding: .5em; font-size: 1em; box-sizing: border-box; border: 1px solid #ccc; border-radius: 4px; }
  form button { margin-top: 1em; padding: .6em 1.5em; font-size: 1em; background: #2563eb; color: #fff; border: none; border-radius: 4px; cursor: pointer; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 1em; }
  .card { background: #fff; padding: 1em; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,.08); }
  .card h3 { margin: 0 0 .5em; }
  .card .field { margin: .4em 0; font-size: .9em; }
  .card .field b { color: #555; }
  .empty { color: #999; text-align: center; padding: 3em; }
</style></head>
<body>
<h1>📸 TeamGram</h1>
<p class="sub">The capstone class wall. {{ count }} intro{{ '' if count == 1 else 's' }} so far.</p>

<form method="POST" action="/intro">
  <label>Name <input name="name" required maxlength="60"></label>
  <label>Nick Name <input name="nickname" required maxlength="20"></label>
  <label>Hobby <input name="hobby" required maxlength="120"></label>
  <label>Future career dream <input name="dream" required maxlength="200"></label>
  <button type="submit">Post to the wall</button>
</form>

{% if posts %}
<div class="grid">
  {% for p in posts %}
  <div class="card">
    <h3>{{ p.name }} <span style="font-weight:400;color:#888;font-size:.8em">· {{ p.nickname }}</span></h3>
    <div class="field"><b>Hobby:</b> {{ p.hobby }}</div>
    <div class="field"><b>Dream:</b> {{ p.dream }}</div>
  </div>
  {% endfor %}
</div>
{% else %}
<p class="empty">No intros yet. Be the first.</p>
{% endif %}
</body></html>
"""


@app.route("/health")
def health():
    return "ok", 200


@app.route("/")
def wall():
    resp = ddb.scan(Limit=200)
    posts = sorted(resp.get("Items", []), key=lambda x: x.get("created_at", ""), reverse=True)
    return render_template_string(WALL_HTML, posts=posts, count=len(posts))


@app.route("/intro", methods=["POST"])
def intro():
    fields = ["name", "nickname", "hobby", "dream"]
    payload = {f: (request.form.get(f) or "").strip() for f in fields}
    if not all(payload.values()):
        abort(400, "All fields are required.")

    payload["id"] = str(uuid.uuid4())
    payload["created_at"] = datetime.now(timezone.utc).isoformat()

    sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps(payload))
    return redirect("/", code=303)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
