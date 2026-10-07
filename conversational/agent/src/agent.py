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

# DATA PROTECTION NOTE: This agent processes user-directed messages and routes them
# as Teams notifications — content that may contain personal data. Handling this data
# may be subject to GDPR and similar frameworks. Under the AWS shared responsibility
# model, customers deploying this sample are responsible for meeting applicable
# data-protection requirements. https://aws.amazon.com/compliance/shared-responsibility-model/
import json
import os
from strands import Agent, tool
from strands.models.bedrock import BedrockModel
from src.teams_notify import send_teams_notification


@tool
def notify_teams(channel_webhook_url: str, title: str, message: str) -> str:
    """Send a notification to a Microsoft Teams channel.

    Args:
        channel_webhook_url: The Teams incoming webhook URL or channel ID
        title: Title of the notification card
        message: Body message for the notification
    """
    result = send_teams_notification(title, message)
    return f"Notification sent: {result}"


@tool
def get_status() -> str:
    """Get the current status of the AgentCore agent."""
    return json.dumps({
        "status": "running",
        "agent": "AgentCore-Teams-Demo",
        "capabilities": ["chat", "notifications"]
    })


def create_agent() -> Agent:
    model = BedrockModel(
        model_id="anthropic.claude-sonnet-4-20250514-v1:0",
        streaming=True,
    )

    agent = Agent(
        model=model,
        tools=[notify_teams, get_status],
        system_prompt=(
            "You are an AI assistant integrated with Microsoft Teams via Amazon Bedrock AgentCore. "
            "You can have conversations and send notifications to Teams channels. "
            "When asked to notify or alert a team, use the notify_teams tool. "
            "Be concise and helpful."
        ),
    )
    return agent
