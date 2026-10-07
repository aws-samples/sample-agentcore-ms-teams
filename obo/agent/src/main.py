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

"""AgentCore OBO Agent — acts on behalf of the user.

The Teams bot performs SSO + OBO token exchange (via teams-ai) to get the user's
Microsoft Graph token, and passes it to this agent in the payload. The agent's
tools use that delegated token to call Microsoft Graph AS the user.

DATA PROTECTION NOTE: The tools below (whoami, get_my_emails, get_my_calendar)
read personal data from Microsoft Graph — user profile, email content, and
calendar events. Handling this data may be subject to privacy regulations such
as GDPR. Under the AWS shared responsibility model, customers deploying this
sample are responsible for meeting the applicable data-protection requirements
(lawful basis, retention, minimization, and access controls) for the personal
data this agent processes. See https://aws.amazon.com/compliance/shared-responsibility-model/
"""

import json
import contextvars
import logging
import httpx
from strands import Agent, tool
from strands.models import BedrockModel
from bedrock_agentcore import BedrockAgentCoreApp

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Holds the current user's Graph token for the duration of a request
_graph_token: contextvars.ContextVar = contextvars.ContextVar("graph_token", default=None)


def _graph_get(path: str) -> httpx.Response:
    token = _graph_token.get()
    if not token:
        raise ValueError("No Graph token available for this request")
    # Metadata-only audit trail: record the Graph route accessed on behalf of the
    # user. Never log the token or the response content (would expose personal data).
    logger.info("audit: OBO Graph access route=%s", path.split("?", 1)[0])
    return httpx.get(
        f"https://graph.microsoft.com/v1.0{path}",
        headers={"Authorization": f"Bearer {token}"},
        timeout=10,
    )


@tool
def whoami() -> str:
    """Show who the current user is, using their delegated Microsoft 365 identity."""
    if not _graph_token.get():
        return "You are not signed in. Please sign in via the Teams bot to use your identity."
    resp = _graph_get("/me?$select=displayName,mail,userPrincipalName,jobTitle")
    if resp.status_code == 200:
        u = resp.json()
        return json.dumps({
            "display_name": u.get("displayName"),
            "email": u.get("mail") or u.get("userPrincipalName"),
            "job_title": u.get("jobTitle"),
            "note": "Accessed using YOUR delegated identity, not a service account.",
        }, indent=2)
    return f"Graph error: {resp.status_code} - {resp.text[:200]}"


@tool
def get_my_emails(count: int = 5) -> str:
    """Read the user's recent emails.

    Args:
        count: Number of recent emails (default 5, max 20)
    """
    count = min(count, 20)
    resp = _graph_get(f"/me/messages?$top={count}&$select=subject,from,receivedDateTime,isRead")
    if resp.status_code == 200:
        msgs = resp.json().get("value", [])
        if not msgs:
            return "No emails in your inbox."
        return json.dumps([{
            "subject": m["subject"],
            "from": m["from"]["emailAddress"]["address"],
            "received": m["receivedDateTime"],
            "read": m["isRead"],
        } for m in msgs], indent=2)
    return f"Graph error: {resp.status_code} - {resp.text[:200]}"


@tool
def get_my_calendar(days: int = 7) -> str:
    """Read the user's upcoming calendar events.

    Args:
        days: Days ahead to look (default 7, max 30)
    """
    from datetime import datetime, timedelta, timezone
    days = min(days, 30)
    now = datetime.now(timezone.utc)
    end = now + timedelta(days=days)
    resp = _graph_get(
        f"/me/calendarView?startDateTime={now.isoformat()}&endDateTime={end.isoformat()}"
        f"&$select=subject,start,end,organizer&$top=10&$orderby=start/dateTime"
    )
    if resp.status_code == 200:
        events = resp.json().get("value", [])
        if not events:
            return f"No events in the next {days} days."
        return json.dumps([{
            "subject": e["subject"],
            "start": e["start"]["dateTime"],
            "end": e["end"]["dateTime"],
            "organizer": e.get("organizer", {}).get("emailAddress", {}).get("name", ""),
        } for e in events], indent=2)
    return f"Graph error: {resp.status_code} - {resp.text[:200]}"


app = BedrockAgentCoreApp()


@app.entrypoint
async def invoke(payload, context):
    message = payload.get("prompt", payload.get("message", ""))
    graph_token = payload.get("graph_token")
    user_name = payload.get("user_name", "user")

    # Make the user's Graph token available to tools for this request
    _graph_token.set(graph_token)

    model = BedrockModel(model_id="us.anthropic.claude-sonnet-4-6")
    agent = Agent(
        model=model,
        system_prompt=(
            f"You are an AI assistant acting ON BEHALF OF {user_name}. "
            "You access their Microsoft 365 data (emails, calendar, profile) using THEIR "
            "delegated identity via Microsoft Graph. When asked about emails, calendar, or "
            "identity, use the appropriate tool. Make clear you're using THEIR identity. "
            "If a tool says the user isn't signed in, ask them to sign in via the Teams bot."
        ),
        tools=[whoami, get_my_emails, get_my_calendar],
    )

    stream = agent.stream_async(message)
    async for event in stream:
        if "data" in event and isinstance(event["data"], str):
            yield event["data"]


if __name__ == "__main__":
    app.run()
