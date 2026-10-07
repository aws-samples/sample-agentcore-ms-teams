#!/usr/bin/env python3
# Copyright 2026 Amazon.com, Inc. or its affiliates
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Send Teams notifications via the AgentCore notify agent.

Invokes the `notifyAgent` Bedrock AgentCore runtime (IAM / SigV4 auth) which
in turn calls the teams-notify-bot to deliver a proactive Adaptive Card to any
Teams user (by email/UPN) or channel ("Team Name / Channel Name").

Config is read from notify/.env (NOTIFY_AGENT_RUNTIME_ID, AWS_REGION).

Privacy: when run interactively (a TTY) or with --verbose, the full agent reply
is printed and MAY contain personal data (emails, message text) echoed from the
prompt or recalled by the agent. Do not run interactively on shared or logged
terminals. When output is piped/redirected (e.g. in CI), only a non-sensitive
summary is printed. Customers are responsible for applicable data-protection
requirements under the AWS shared responsibility model.
See https://aws.amazon.com/compliance/shared-responsibility-model/

Examples:
  # Natural-language prompt (the agent extracts target/title/message):
  ./notify.py "notify jane@example.com that the build passed"
  ./notify.py "notify JP / General that deployment is complete"

  # Structured — target + message given explicitly:
  ./notify.py --to jane@example.com --message "Build #42 passed" --title "CI"
  ./notify.py --to "JP / General" -m "Deploy done" -t "Release"

  # Read the message body from stdin:
  echo "Nightly job finished" | ./notify.py --to jane@example.com -t "Cron"
"""

import argparse
import json
import os
import sys
import uuid

try:
    import boto3
except ImportError:
    sys.exit("boto3 is required: pip install boto3")


def load_env(env_path):
    """Load KEY=VALUE lines from a .env file into a dict (no export needed)."""
    env = {}
    if not os.path.isfile(env_path):
        return env
    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            env[key.strip()] = val.strip()
    return env


def build_prompt(args):
    """Turn CLI args into the natural-language prompt the agent expects."""
    if args.prompt:
        return " ".join(args.prompt)

    message = args.message
    if message is None and not sys.stdin.isatty():
        message = sys.stdin.read().strip()
    if not args.to or not message:
        return None

    title = f' with the title "{args.title}"' if args.title else ""
    return f'Notify {args.to}{title} that: {message}'


def invoke(runtime_id, region, prompt, session_id):
    client = boto3.client("bedrock-agentcore", region_name=region)
    resp = client.invoke_agent_runtime(
        agentRuntimeArn=runtime_id if runtime_id.startswith("arn:")
        else _arn(client, region, runtime_id),
        runtimeSessionId=session_id,
        payload=json.dumps({"prompt": prompt}).encode("utf-8"),
    )

    # The response body is a streaming payload; concatenate its chunks.
    raw = []
    body = resp.get("response")
    if body is None:
        return ""
    for chunk in body.iter_chunks() if hasattr(body, "iter_chunks") else [body.read()]:
        if not chunk:
            continue
        raw.append(chunk.decode("utf-8") if isinstance(chunk, bytes) else str(chunk))
    return _decode_sse("".join(raw))


def _decode_sse(raw):
    """Reconstruct agent text from the runtime's `data: <json>` SSE stream.

    Each streamed token arrives as a line like: data: "some text". Concatenate
    the JSON-decoded payloads back into the original message. Falls back to the
    raw text if it isn't in SSE form.
    """
    parts = []
    saw_data = False
    for line in raw.splitlines():
        if not line.startswith("data:"):
            continue
        saw_data = True
        payload = line[len("data:"):].strip()
        if not payload:
            continue
        try:
            parts.append(json.loads(payload))
        except json.JSONDecodeError:
            parts.append(payload)
    return "".join(str(p) for p in parts) if saw_data else raw


def _arn(client, region, runtime_id):
    account = boto3.client("sts", region_name=region).get_caller_identity()["Account"]
    return f"arn:aws:bedrock-agentcore:{region}:{account}:runtime/{runtime_id}"


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    env = load_env(os.path.join(here, ".env"))

    p = argparse.ArgumentParser(
        description="Send a Teams notification via the AgentCore notify agent.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("prompt", nargs="*",
                   help="Natural-language notify instruction (alternative to --to/--message).")
    p.add_argument("--to", help="Target: user email/UPN or 'Team Name / Channel Name'.")
    p.add_argument("-m", "--message", help="Notification body (or pipe via stdin).")
    p.add_argument("-t", "--title", help="Optional card title.")
    p.add_argument("--runtime-id", default=env.get("NOTIFY_AGENT_RUNTIME_ID"),
                   help="AgentCore runtime id or ARN (default: from .env).")
    p.add_argument("--region", default=env.get("AWS_REGION", "us-east-1"),
                   help="AWS region (default: from .env or us-east-1).")
    p.add_argument("--session-id", default=None,
                   help="Runtime session id (default: random per call).")
    p.add_argument("-v", "--verbose", action="store_true",
                   help="Echo the resolved prompt to stderr (may contain user data).")
    args = p.parse_args()

    prompt = build_prompt(args)
    if not prompt:
        p.error("provide a prompt, or --to plus --message/stdin.")
    if not args.runtime_id:
        p.error("no runtime id: set NOTIFY_AGENT_RUNTIME_ID in notify/.env or pass --runtime-id.")

    # Session id must be >=33 chars for AgentCore; pad a uuid to be safe.
    session_id = args.session_id or f"notify-{uuid.uuid4().hex}"

    print(f"→ {args.region}  {args.runtime_id}", file=sys.stderr)
    # DATA PROTECTION NOTE: the prompt may contain personal data (emails, message text),
    # regulated under GDPR and similar frameworks. Under the AWS shared responsibility
    # model, customers are responsible for applicable data-protection requirements.
    # https://aws.amazon.com/compliance/shared-responsibility-model/
    # Even with --verbose, only show a short truncated prefix so full personal data is
    # never emitted. Do NOT enable --verbose in production or CI.
    if args.verbose:
        preview = prompt[:20] + ("[...]" if len(prompt) > 20 else "")
        print(f"→ prompt (truncated): {preview}", file=sys.stderr)

    try:
        result = invoke(args.runtime_id, args.region, prompt, session_id)
    except Exception as e:
        sys.exit(f"invoke failed: {type(e).__name__}: {e}")

    # The reply may echo personal data from the prompt. Only print the full reply in
    # an interactive terminal (or with --verbose); when piped/automated (e.g. CI),
    # emit a non-sensitive summary so personal data is not written to logs/pipelines.
    reply = result.strip()
    if args.verbose or sys.stdout.isatty():
        print(reply or "(no output from agent)")
    else:
        print(f"notification sent ({len(reply)} chars)" if reply else "(no output from agent)")


if __name__ == "__main__":
    main()
