#!/usr/bin/env bash
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

set -euo pipefail

# =============================================================================
# Setup Entra ID App Registrations for AgentCore + Teams Integration
#
# Creates two app registrations:
#   1. AgentCore-Teams-Bot: Used by the Teams bot (inbound auth to Gateway)
#   2. AgentCore-Outbound: Used by the agent for Graph API access (notifications)
#
# Prerequisites: az login to the tenant where Teams is configured
# =============================================================================

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TENANT_ID=$(az account show --query tenantId -o tsv)
echo "Using tenant: $TENANT_ID"

# =============================================================================
# App Registration 1: AgentCore-Teams-Bot
# - Bot Framework channel
# - Exposes API scope for Gateway inbound validation
# - Issues v2.0 tokens
# =============================================================================
echo ""
echo "=== Creating App Registration: AgentCore-Teams-Bot ==="

BOT_APP=$(az ad app create \
  --display-name "AgentCore-Teams-Bot" \
  --sign-in-audience "AzureADMyOrg" \
  --query "{appId:appId, id:id}" \
  -o json)

BOT_APP_ID=$(echo "$BOT_APP" | jq -r '.appId')
BOT_OBJECT_ID=$(echo "$BOT_APP" | jq -r '.id')

echo "  App (client) ID: $BOT_APP_ID"
echo "  Object ID: $BOT_OBJECT_ID"

# Set token version to v2.0
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$BOT_OBJECT_ID" \
  --headers "Content-Type=application/json" \
  --body '{"api":{"requestedAccessTokenVersion":2}}'

echo "  Set accessTokenAcceptedVersion = 2"

# Expose an API scope
SCOPE_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$BOT_OBJECT_ID" \
  --headers "Content-Type=application/json" \
  --body "{
    \"identifierUris\": [\"api://$BOT_APP_ID\"],
    \"api\": {
      \"requestedAccessTokenVersion\": 2,
      \"oauth2PermissionScopes\": [{
        \"id\": \"$SCOPE_ID\",
        \"adminConsentDisplayName\": \"Invoke AgentCore Agent\",
        \"adminConsentDescription\": \"Allows the app to invoke the AgentCore agent\",
        \"userConsentDisplayName\": \"Invoke AgentCore Agent\",
        \"userConsentDescription\": \"Allows the app to invoke the AgentCore agent\",
        \"isEnabled\": true,
        \"type\": \"Admin\",
        \"value\": \"Agent.Invoke\"
      }]
    }
  }"

echo "  Exposed API scope: api://$BOT_APP_ID/Agent.Invoke"

# Create client secret for the bot
BOT_SECRET=$(az ad app credential reset \
  --id "$BOT_OBJECT_ID" \
  --display-name "bot-secret" \
  --years 1 \
  --query password -o tsv)

echo "  Client secret created — written to .env (do not share)"

# =============================================================================
# App Registration 2: AgentCore-Outbound
# - Graph API permissions for sending Teams notifications
# - Client credentials for AgentCore Identity outbound
# =============================================================================
echo ""
echo "=== Creating App Registration: AgentCore-Outbound ==="

OUTBOUND_APP=$(az ad app create \
  --display-name "AgentCore-Outbound" \
  --sign-in-audience "AzureADMyOrg" \
  --query "{appId:appId, id:id}" \
  -o json)

OUTBOUND_APP_ID=$(echo "$OUTBOUND_APP" | jq -r '.appId')
OUTBOUND_OBJECT_ID=$(echo "$OUTBOUND_APP" | jq -r '.id')

echo "  App (client) ID: $OUTBOUND_APP_ID"
echo "  Object ID: $OUTBOUND_OBJECT_ID"

# Add Graph API permissions (application permissions)
# ChannelMessage.Send: 7ab1d382-f21e-4acd-a863-ba3e13f7da61
# Chat.Create: d9c48af6-9ad9-47ad-82c3-63757137b9af
# ChatMessage.Send (app): (not available as app permission - use ChannelMessage.Send)
# TeamsActivity.Send: 70b94f1b-68a0-483b-ba36-ebe032e0e608

GRAPH_API_ID="00000003-0000-0000-c000-000000000000"

az ad app permission add \
  --id "$OUTBOUND_OBJECT_ID" \
  --api "$GRAPH_API_ID" \
  --api-permissions \
    "7ab1d382-f21e-4acd-a863-ba3e13f7da61=Role" \
    "d9c48af6-9ad9-47ad-82c3-63757137b9af=Role" \
    "70b94f1b-68a0-483b-ba36-ebe032e0e608=Role"

echo "  Added Graph permissions: ChannelMessage.Send, Chat.Create, TeamsActivity.Send"

# Grant admin consent
echo "  Granting admin consent..."
az ad app permission admin-consent --id "$OUTBOUND_OBJECT_ID" 2>/dev/null || \
  echo "  WARNING: Admin consent may need to be granted manually in Entra portal"

# Create client secret for outbound
OUTBOUND_SECRET=$(az ad app credential reset \
  --id "$OUTBOUND_OBJECT_ID" \
  --display-name "agentcore-outbound-secret" \
  --years 1 \
  --query password -o tsv)

echo "  Client secret created — written to .env (do not share)"

# Create service principal for outbound app (needed for admin consent)
az ad sp create --id "$OUTBOUND_APP_ID" 2>/dev/null || true

# Retry admin consent after SP creation
az ad app permission admin-consent --id "$OUTBOUND_OBJECT_ID" 2>/dev/null || \
  echo "  NOTE: Grant admin consent at https://entra.microsoft.com -> App registrations -> AgentCore-Outbound -> API permissions -> Grant admin consent"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================================"
echo "SETUP COMPLETE - Save these values!"
echo "============================================================"
echo ""
echo "Tenant ID:                $TENANT_ID"
echo ""
echo "--- AgentCore-Teams-Bot ---"
echo "App (client) ID:          $BOT_APP_ID"
echo "Client Secret:            (stored in .env — do not share)"
echo "API Scope:                api://$BOT_APP_ID/Agent.Invoke"
echo "Discovery URL (v2):       https://login.microsoftonline.com/$TENANT_ID/v2.0/.well-known/openid-configuration"
echo ""
echo "--- AgentCore-Outbound ---"
echo "App (client) ID:          $OUTBOUND_APP_ID"
echo "Client Secret:            (stored in .env — do not share)"
echo ""
echo "Next steps:"
echo "  1. Create Azure Bot resource pointing to Bot App ID: $BOT_APP_ID"
echo "  2. Configure AgentCore Gateway inbound with Discovery URL + audience"
echo "  3. Create AgentCore Identity credential provider with Outbound app creds"
echo ""

# Save to env file (gitignored)
cat > "$PROJECT_ROOT/.env" <<EOF
# Entra ID Configuration - DO NOT COMMIT
TENANT_ID=$TENANT_ID
BOT_APP_ID=$BOT_APP_ID
BOT_APP_SECRET=$BOT_SECRET
BOT_API_SCOPE=api://$BOT_APP_ID/Agent.Invoke
OUTBOUND_APP_ID=$OUTBOUND_APP_ID
OUTBOUND_APP_SECRET=$OUTBOUND_SECRET
DISCOVERY_URL=https://login.microsoftonline.com/$TENANT_ID/v2.0/.well-known/openid-configuration
EOF

echo "Saved to .env file (add to .gitignore!)"
