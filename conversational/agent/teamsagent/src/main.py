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

# DATA PROTECTION NOTE: This agent processes Teams messages and user identifiers —
# personal data under GDPR and similar frameworks. Under the AWS shared responsibility
# model, customers deploying this sample are responsible for meeting applicable
# data-protection requirements. https://aws.amazon.com/compliance/shared-responsibility-model/
import os
import json
import httpx
from strands import Agent, tool
from strands.models import BedrockModel
from bedrock_agentcore import BedrockAgentCoreApp

TENANT_ID = os.getenv("TENANT_ID", "")
OUTBOUND_APP_ID = os.getenv("OUTBOUND_APP_ID", "")
OUTBOUND_APP_SECRET = os.getenv("OUTBOUND_APP_SECRET", "")
TEAMS_TEAM_ID = os.getenv("TEAMS_TEAM_ID", "")
TEAMS_CHANNEL_ID = os.getenv("TEAMS_CHANNEL_ID", "")
TEAMS_BOT_NOTIFY_URL = os.getenv("TEAMS_BOT_NOTIFY_URL", "")


@tool
def send_teams_notification(title: str, message: str) -> str:
    """Send a notification as an Adaptive Card to a Microsoft Teams channel.

    Args:
        title: Title of the notification card
        message: Body text for the notification
    """
    if TEAMS_BOT_NOTIFY_URL:
        resp = httpx.post(
            TEAMS_BOT_NOTIFY_URL,
            json={"title": title, "message": message},
            timeout=10,
        )
        if resp.status_code == 200:
            return f"Notification sent via bot: {resp.json()}"
        return f"Bot notify failed: {resp.status_code} - {resp.text[:200]}"

    return "Error: TEAMS_BOT_NOTIFY_URL is not configured"


@tool
def get_agent_status() -> str:
    """Get the current status of this AgentCore agent."""
    return json.dumps({
        "status": "running",
        "agent": "AgentCore-Teams-Demo",
        "runtime": "Amazon Bedrock AgentCore",
        "protocol": "HTTP",
        "auth": "Entra ID JWT (inbound)",
        "capabilities": ["conversational AI", "Teams notifications", "Entra ID auth"],
    })


@tool
def chat_with_agent(message: str) -> str:
    """Process a chat message and return the AI response.

    Args:
        message: The user's chat message
    """
    model = BedrockModel(model_id="us.anthropic.claude-sonnet-4-6")
    agent = Agent(
        model=model,
        system_prompt=(
            "You are an AI assistant powered by Amazon Bedrock AgentCore, integrated with Microsoft Teams. "
            "You can have conversations and send notifications to Teams channels. "
            "Be concise and helpful."
        ),
        tools=[send_teams_notification, get_agent_status],
    )
    result = agent(message)
    return str(result.message) if hasattr(result, "message") else str(result)


app = BedrockAgentCoreApp()


@app.entrypoint
async def invoke(payload, context):
    message = payload.get("prompt", payload.get("message", ""))
    model = BedrockModel(model_id="us.anthropic.claude-sonnet-4-6")
    agent = Agent(
        model=model,
        system_prompt=(
            "You are an AI assistant powered by Amazon Bedrock AgentCore, integrated with Microsoft Teams. "
            "You can have conversations and send notifications to Teams channels using the send_teams_notification tool. "
            "When asked to notify or alert, use the tool. Be concise and helpful."
        ),
        tools=[send_teams_notification, get_agent_status],
    )

    stream = agent.stream_async(message)
    async for event in stream:
        if "data" in event and isinstance(event["data"], str):
            yield event["data"]


if __name__ == "__main__":
    app.run()
