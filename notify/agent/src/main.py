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

"""AgentCore Notify Agent.

An agent that can send proactive Teams notifications to ANY user or channel
in the tenant by calling the teams-notify-bot's /api/notify endpoint. The bot
handles target resolution + proactive installation; this agent just decides
what to send and to whom.

DATA PROTECTION NOTE: Routing notifications by user email/UPN and sending message
content involves processing personal data. Handling this data may be subject to
GDPR and similar frameworks. Under the AWS shared responsibility model, customers
deploying this sample are responsible for meeting applicable data-protection
requirements. See https://aws.amazon.com/compliance/shared-responsibility-model/
"""

import os
import json
import logging
import httpx
from strands import Agent, tool
from strands.models import BedrockModel
from bedrock_agentcore import BedrockAgentCoreApp

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

NOTIFY_BOT_URL = os.getenv("NOTIFY_BOT_URL", "")
NOTIFY_SECRET = os.getenv("NOTIFY_SECRET", "")


@tool
def send_notification(target: str, title: str, message: str) -> str:
    """Send a proactive notification (Adaptive Card) to a Teams user or channel.

    Args:
        target: Who to notify. Either a user's email/UPN (e.g. "jane@example.com")
                OR a channel as "Team Name / Channel Name" (e.g. "JP / General").
        title: Short bold title for the notification card.
        message: The notification body text.
    """
    if not NOTIFY_BOT_URL:
        return "Error: NOTIFY_BOT_URL is not configured."
    # Deny by default: never call /api/notify unauthenticated.
    if not NOTIFY_SECRET:
        return "Error: NOTIFY_SECRET is not configured; refusing to send."

    # Metadata-only audit trail: record that a notification was attempted and
    # whether the target is a channel or a user. Never log title/message content
    # or the target address (would expose personal data).
    logger.info("audit: notify tool invoked target_type=%s",
                "channel" if "/" in target else "user")

    headers = {"Content-Type": "application/json", "Authorization": f"Bearer {NOTIFY_SECRET}"}

    try:
        resp = httpx.post(
            NOTIFY_BOT_URL,
            headers=headers,
            json={"target": target, "title": title, "message": message},
            timeout=30,
        )
    except Exception as e:
        return f"Failed to reach notify bot: {type(e).__name__}: {e}"

    if resp.status_code == 200:
        data = resp.json()
        return f"Notification delivered to {target} ({data.get('type', 'unknown')})."
    return f"Notification failed ({resp.status_code}): {resp.text[:300]}"


app = BedrockAgentCoreApp()


@app.entrypoint
async def invoke(payload, context):
    message = payload.get("prompt", payload.get("message", ""))
    model = BedrockModel(model_id="us.anthropic.claude-sonnet-4-6")

    agent = Agent(
        model=model,
        system_prompt=(
            "You are an AI assistant that sends notifications to Microsoft Teams. "
            "Use the send_notification tool to notify a user (by email) or a channel "
            "(as 'Team Name / Channel Name'). When the user asks you to notify, alert, "
            "or message someone, extract the target, craft a concise title and message, "
            "and call the tool. Confirm what you sent and to whom."
        ),
        tools=[send_notification],
    )

    stream = agent.stream_async(message)
    async for event in stream:
        if "data" in event and isinstance(event["data"], str):
            yield event["data"]


if __name__ == "__main__":
    app.run()
