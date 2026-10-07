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

import os
import boto3
from mcp.client.streamable_http import streamablehttp_client
from strands.tools.mcp.mcp_client import MCPClient
import requests

COGNITO_TOKEN_URL = os.getenv("COGNITO_TOKEN_URL")
COGNITO_CLIENT_ID = os.getenv("COGNITO_CLIENT_ID")
COGNITO_SCOPE = os.getenv("COGNITO_SCOPE")
# The client secret is delivered as a Secrets Manager ARN (preferred) so it is
# never stored as a plaintext runtime environment variable. COGNITO_CLIENT_SECRET
# remains supported only as a local-development fallback.
COGNITO_CLIENT_SECRET_ARN = os.getenv("COGNITO_CLIENT_SECRET_ARN")

_cached_secret = None


def _get_client_secret():
    """Resolve the Cognito client secret from Secrets Manager (preferred) or env."""
    global _cached_secret
    if _cached_secret is not None:
        return _cached_secret
    if COGNITO_CLIENT_SECRET_ARN:
        sm = boto3.client("secretsmanager")
        _cached_secret = sm.get_secret_value(SecretId=COGNITO_CLIENT_SECRET_ARN)["SecretString"]
    else:
        _cached_secret = os.getenv("COGNITO_CLIENT_SECRET")
    return _cached_secret


def _get_access_token():
    """
    Make a POST request to the Cognito OAuth token URL using client credentials.
    """
    response = requests.post(
        COGNITO_TOKEN_URL,
        auth=(COGNITO_CLIENT_ID, _get_client_secret()),
        data={
            "grant_type": "client_credentials",
            "scope": COGNITO_SCOPE,
        },
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        timeout=10,
    )
    response.raise_for_status()
    return response.json()["access_token"]


def get_streamable_http_mcp_client() -> MCPClient:
    """
    Returns an MCP Client for AgentCore Gateway compatible with Strands
    """
    gateway_url = os.getenv("GATEWAY_URL")
    if not gateway_url:
        raise RuntimeError("Missing required environment variable: GATEWAY_URL")
    access_token = _get_access_token()
    return MCPClient(lambda: streamablehttp_client(gateway_url, headers={"Authorization": f"Bearer {access_token}"}))