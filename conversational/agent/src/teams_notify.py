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

"""Teams notification sender using Microsoft Graph API with AgentCore Identity credentials.

DATA PROTECTION NOTE: Message content sent to Teams channels/users here may
contain personal data. Handling this data may be subject to GDPR and similar
frameworks. Under the AWS shared responsibility model, customers deploying this
sample are responsible for meeting applicable data-protection requirements.
See https://aws.amazon.com/compliance/shared-responsibility-model/
"""

import json
import os
import httpx
from typing import Optional


def get_graph_token() -> str:
    """Acquire a Graph API token using client credentials.

    In production on AgentCore Runtime, this would use the AgentCore Identity
    credential provider. For local dev, falls back to direct MSAL client credentials.
    """
    tenant_id = os.environ["TENANT_ID"]
    client_id = os.environ["OUTBOUND_APP_ID"]
    client_secret = os.environ["OUTBOUND_APP_SECRET"]

    token_url = f"https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token"

    response = httpx.post(
        token_url,
        data={
            "grant_type": "client_credentials",
            "client_id": client_id,
            "client_secret": client_secret,
            "scope": "https://graph.microsoft.com/.default",
        },
    )
    response.raise_for_status()
    return response.json()["access_token"]


def send_teams_notification(title: str, message: str, team_id: Optional[str] = None, channel_id: Optional[str] = None) -> str:
    """Send an Adaptive Card notification to a Teams channel via Graph API."""
    team_id = team_id or os.environ.get("TEAMS_TEAM_ID")
    channel_id = channel_id or os.environ.get("TEAMS_CHANNEL_ID")

    if not team_id or not channel_id:
        return "Error: TEAMS_TEAM_ID and TEAMS_CHANNEL_ID must be set"

    token = get_graph_token()

    adaptive_card = {
        "contentType": "application/vnd.microsoft.card.adaptive",
        "content": {
            "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
            "type": "AdaptiveCard",
            "version": "1.4",
            "body": [
                {
                    "type": "TextBlock",
                    "text": title,
                    "weight": "Bolder",
                    "size": "Medium",
                    "color": "Accent",
                },
                {
                    "type": "TextBlock",
                    "text": message,
                    "wrap": True,
                },
                {
                    "type": "TextBlock",
                    "text": "Sent by AgentCore Agent",
                    "size": "Small",
                    "isSubtle": True,
                },
            ],
        },
    }

    url = f"https://graph.microsoft.com/v1.0/teams/{team_id}/channels/{channel_id}/messages"

    response = httpx.post(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        json={
            "body": {
                "contentType": "html",
                "content": f"<attachment id=\"card\"></attachment>",
            },
            "attachments": [
                {
                    "id": "card",
                    "contentType": "application/vnd.microsoft.card.adaptive",
                    "content": json.dumps(adaptive_card["content"]),
                }
            ],
        },
    )

    if response.status_code in (200, 201):
        return f"Success - message ID: {response.json().get('id', 'unknown')}"
    else:
        return f"Error {response.status_code}: {response.text}"
