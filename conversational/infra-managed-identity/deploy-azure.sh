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
# Deploy Azure Infrastructure (v2 - Managed Identity)
#
# Creates:
#   - Resource Group
#   - User-Assigned Managed Identity
#   - Entra ID App Registrations (Bot + Outbound) with Federated Credential
#   - Azure Bot (SingleTenant) with Teams channel
#   - Azure Container Registry
#   - Container Apps Environment + Bot deployment
#
# Security:
#   - Bot → AgentCore uses Managed Identity + Federated Credential (no secret)
#   - Bot Framework SDK still requires client secret (SDK v4 limitation)
#   - /api/notify endpoint protected by NOTIFY_SECRET
#
# Usage:
#   ./deploy-azure.sh [--tenant-id ID] [--region REGION] [--bot-name NAME]
# =============================================================================

# ---------- Defaults ----------
REGION="${REGION:-westus2}"
BOT_NAME="${BOT_NAME:-agentcore-bot-demo}"
RESOURCE_GROUP="${RESOURCE_GROUP:-agentcore-msteams-rg}"
ACR_NAME="${ACR_NAME:-agentcoredemo2cr}"
MI_NAME="${MI_NAME:-agentcore-bot-identity}"
ENV_NAME="${ENV_NAME:-bot-env-west}"
APP_NAME="${APP_NAME:-agentcore-teams-bot}"

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant-id) TENANT_ID="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --bot-name) BOT_NAME="$2"; shift 2;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2;;
    --acr-name) ACR_NAME="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

# ---------- Detect tenant ----------
TENANT_ID="${TENANT_ID:-$(az account show --query tenantId -o tsv)}"
echo "Tenant: $TENANT_ID"
echo "Region: $REGION"
echo ""

# =============================================================================
# 1. Resource Group
# =============================================================================
echo "=== 1. Resource Group ==="
az group create --name "$RESOURCE_GROUP" --location "$REGION" -o none
echo "  Created: $RESOURCE_GROUP ($REGION)"

# =============================================================================
# 2. User-Assigned Managed Identity
# =============================================================================
echo ""
echo "=== 2. Managed Identity ==="
MI_OUTPUT=$(az identity create \
  --name "$MI_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$REGION" \
  --query "{clientId:clientId, principalId:principalId, id:id}" \
  -o json 2>/dev/null || az identity show \
  --name "$MI_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "{clientId:clientId, principalId:principalId, id:id}" \
  -o json)

MI_CLIENT_ID=$(echo "$MI_OUTPUT" | jq -r '.clientId')
MI_PRINCIPAL_ID=$(echo "$MI_OUTPUT" | jq -r '.principalId')
MI_RESOURCE_ID=$(echo "$MI_OUTPUT" | jq -r '.id')
echo "  Name: $MI_NAME"
echo "  Client ID: $MI_CLIENT_ID"
echo "  Principal ID: $MI_PRINCIPAL_ID"

# =============================================================================
# 3. Entra App Registration: AgentCore-Teams-Bot
# =============================================================================
echo ""
echo "=== 3. App Registration: AgentCore-Teams-Bot ==="
BOT_APP=$(az ad app create \
  --display-name "AgentCore-Teams-Bot" \
  --sign-in-audience "AzureADMyOrg" \
  --query "{appId:appId, id:id}" \
  -o json)
BOT_APP_ID=$(echo "$BOT_APP" | jq -r '.appId')
BOT_OBJECT_ID=$(echo "$BOT_APP" | jq -r '.id')
echo "  App ID: $BOT_APP_ID"

# Set token version to v2.0 and expose API scope
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
        \"adminConsentDescription\": \"Allows invocation of the AgentCore agent\",
        \"userConsentDisplayName\": \"Invoke AgentCore Agent\",
        \"userConsentDescription\": \"Allows invocation of the AgentCore agent\",
        \"isEnabled\": true,
        \"type\": \"Admin\",
        \"value\": \"Agent.Invoke\"
      }]
    }
  }" -o none
echo "  API scope: api://$BOT_APP_ID/Agent.Invoke"

# Create client secret (required for Bot Framework SDK v4)
BOT_SECRET=$(az ad app credential reset --id "$BOT_OBJECT_ID" --display-name "bot-framework-secret" --years 1 --query password -o tsv)
echo "  Client secret created (Bot Framework SDK requirement)"

# Create service principal
az ad sp create --id "$BOT_APP_ID" -o none 2>/dev/null || true

# Add Federated Identity Credential for Managed Identity
az ad app federated-credential create \
  --id "$BOT_OBJECT_ID" \
  --parameters "{
    \"name\": \"managed-identity-federation\",
    \"issuer\": \"https://login.microsoftonline.com/$TENANT_ID/v2.0\",
    \"subject\": \"$MI_PRINCIPAL_ID\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" -o none
echo "  Federated credential: Managed Identity → Bot App"

# =============================================================================
# 4. Entra App Registration: AgentCore-Outbound
# =============================================================================
echo ""
echo "=== 4. App Registration: AgentCore-Outbound ==="
OUTBOUND_APP=$(az ad app create \
  --display-name "AgentCore-Outbound" \
  --sign-in-audience "AzureADMyOrg" \
  --query "{appId:appId, id:id}" \
  -o json)
OUTBOUND_APP_ID=$(echo "$OUTBOUND_APP" | jq -r '.appId')
OUTBOUND_OBJECT_ID=$(echo "$OUTBOUND_APP" | jq -r '.id')
echo "  App ID: $OUTBOUND_APP_ID"

# Create SP and get Graph permission IDs
az ad sp create --id "$OUTBOUND_APP_ID" -o none 2>/dev/null || true
OUTBOUND_SP_ID=$(az ad sp show --id "$OUTBOUND_APP_ID" --query "id" -o tsv)
GRAPH_SP_ID=$(az ad sp show --id "00000003-0000-0000-c000-000000000000" --query "id" -o tsv)

TEAMS_ACTIVITY_SEND=$(az ad sp show --id "00000003-0000-0000-c000-000000000000" --query "appRoles[?value=='TeamsActivity.Send'].id" -o tsv)
CHAT_CREATE=$(az ad sp show --id "00000003-0000-0000-c000-000000000000" --query "appRoles[?value=='Chat.Create'].id" -o tsv)
GROUP_READ=$(az ad sp show --id "00000003-0000-0000-c000-000000000000" --query "appRoles[?value=='Group.Read.All'].id" -o tsv)
TEAM_READ=$(az ad sp show --id "00000003-0000-0000-c000-000000000000" --query "appRoles[?value=='Team.ReadBasic.All'].id" -o tsv)
CHANNEL_READ=$(az ad sp show --id "00000003-0000-0000-c000-000000000000" --query "appRoles[?value=='ChannelMessage.Read.All'].id" -o tsv)

# Grant permissions
for ROLE_ID in $TEAMS_ACTIVITY_SEND $CHAT_CREATE $GROUP_READ $TEAM_READ $CHANNEL_READ; do
  az rest --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$OUTBOUND_SP_ID/appRoleAssignments" \
    --headers "Content-Type=application/json" \
    --body "{\"principalId\":\"$OUTBOUND_SP_ID\",\"resourceId\":\"$GRAPH_SP_ID\",\"appRoleId\":\"$ROLE_ID\"}" \
    -o none 2>/dev/null || true
done
echo "  Graph permissions granted (admin consent)"

# Create client secret (stored in AgentCore Identity token vault, not in app)
OUTBOUND_SECRET=$(az ad app credential reset --id "$OUTBOUND_OBJECT_ID" --display-name "agentcore-identity-vault" --years 1 --query password -o tsv)
echo "  Client secret created (for AgentCore Identity token vault)"

# =============================================================================
# 5. Azure Bot (SingleTenant with secret for Bot Framework SDK)
# =============================================================================
echo ""
echo "=== 5. Azure Bot ==="
az bot create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$BOT_NAME" \
  --appid "$BOT_APP_ID" \
  --app-type "SingleTenant" \
  --tenant-id "$TENANT_ID" \
  --sku "F0" \
  --location "global" \
  -o none
echo "  Created: $BOT_NAME (SingleTenant, F0)"

az bot msteams create --resource-group "$RESOURCE_GROUP" --name "$BOT_NAME" -o none 2>/dev/null
echo "  Teams channel enabled"

# =============================================================================
# 6. Container Registry
# =============================================================================
echo ""
echo "=== 6. Container Registry ==="
az acr create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ACR_NAME" \
  --sku "Basic" \
  --admin-enabled true \
  -o none 2>/dev/null || true
echo "  ACR: $ACR_NAME.azurecr.io"

# =============================================================================
# 7. Build and push container image
# =============================================================================
echo ""
echo "=== 7. Build Container Image ==="
TEAMS_BOT_DIR="$(cd "$(dirname "$0")/../bot" && pwd)"
az acr build \
  --registry "$ACR_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --image "teams-bot:latest" \
  --file "$TEAMS_BOT_DIR/Dockerfile" \
  "$TEAMS_BOT_DIR" \
  -o none
echo "  Image: $ACR_NAME.azurecr.io/teams-bot:latest"

# =============================================================================
# 8. Container Apps Environment
# =============================================================================
echo ""
echo "=== 8. Container Apps Environment ==="
az containerapp env create \
  --name "$ENV_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$REGION" \
  -o none 2>/dev/null || true
echo "  Environment: $ENV_NAME"

# =============================================================================
# 9. Deploy Container App with Managed Identity
# =============================================================================
echo ""
echo "=== 9. Container App Deployment ==="
ACR_PASSWORD=$(az acr credential show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query "passwords[0].value" -o tsv)

# Generate a random notify secret
NOTIFY_SECRET=$(openssl rand -hex 32)

az containerapp create \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --environment "$ENV_NAME" \
  --image "$ACR_NAME.azurecr.io/teams-bot:latest" \
  --registry-server "$ACR_NAME.azurecr.io" \
  --registry-username "$ACR_NAME" \
  --registry-password "$ACR_PASSWORD" \
  --target-port 3978 \
  --ingress "external" \
  --min-replicas 1 \
  --max-replicas 1 \
  --user-assigned "$MI_RESOURCE_ID" \
  --env-vars \
    "BOT_APP_ID=$BOT_APP_ID" \
    "BOT_APP_SECRET=$BOT_SECRET" \
    "TENANT_ID=$TENANT_ID" \
    "MI_CLIENT_ID=$MI_CLIENT_ID" \
    "NOTIFY_SECRET=$NOTIFY_SECRET" \
  -o none 2>/dev/null || \
az containerapp update \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --image "$ACR_NAME.azurecr.io/teams-bot:latest" \
  --set-env-vars \
    "BOT_APP_ID=$BOT_APP_ID" \
    "BOT_APP_SECRET=$BOT_SECRET" \
    "TENANT_ID=$TENANT_ID" \
    "MI_CLIENT_ID=$MI_CLIENT_ID" \
    "NOTIFY_SECRET=$NOTIFY_SECRET" \
  -o none

APP_FQDN=$(az containerapp show --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" --query "properties.configuration.ingress.fqdn" -o tsv)
BOT_ENDPOINT="https://$APP_FQDN/api/messages"
NOTIFY_URL="https://$APP_FQDN/api/notify"
echo "  FQDN: $APP_FQDN"
echo "  Bot endpoint: $BOT_ENDPOINT"
echo "  Notify URL: $NOTIFY_URL"

# =============================================================================
# 10. Set Bot messaging endpoint
# =============================================================================
echo ""
echo "=== 10. Configure Bot Endpoint ==="
az bot update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$BOT_NAME" \
  --endpoint "$BOT_ENDPOINT" \
  -o none
echo "  Endpoint set: $BOT_ENDPOINT"

# =============================================================================
# Output
# =============================================================================
echo ""
echo "============================================================"
echo "  AZURE DEPLOYMENT COMPLETE"
echo "============================================================"
echo ""
echo "Tenant ID:            $TENANT_ID"
echo "Bot App ID:           $BOT_APP_ID"
echo "Bot App Secret:       (stored in .env — do not share)"
echo "Outbound App ID:      $OUTBOUND_APP_ID"
echo "Outbound App Secret:  (stored in .env — do not share)"
echo "MI Client ID:         $MI_CLIENT_ID"
echo "Bot Endpoint:         $BOT_ENDPOINT"
echo "Notify URL:           $NOTIFY_URL"
echo "Notify Secret:        (stored in .env — do not share)"
echo ""
echo "Security:"
echo "  - Bot → AgentCore: Managed Identity + Federated Credential (no secret)"
echo "  - Bot Framework:   Client secret (SDK v4 requirement)"
echo "  - /api/notify:     Protected by NOTIFY_SECRET bearer token"
echo "  - Outbound secret: Goes into AgentCore Identity token vault (not in app)"
echo ""

# Save .env
ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
cat > "$ENV_FILE" <<EOF
# Azure / Entra ID Configuration
TENANT_ID=$TENANT_ID
BOT_APP_ID=$BOT_APP_ID
BOT_APP_SECRET=$BOT_SECRET
BOT_API_SCOPE=api://$BOT_APP_ID/Agent.Invoke
OUTBOUND_APP_ID=$OUTBOUND_APP_ID
OUTBOUND_APP_SECRET=$OUTBOUND_SECRET
MI_CLIENT_ID=$MI_CLIENT_ID
DISCOVERY_URL=https://login.microsoftonline.com/$TENANT_ID/v2.0/.well-known/openid-configuration

# Endpoints
BOT_ENDPOINT=$BOT_ENDPOINT
NOTIFY_URL=$NOTIFY_URL
NOTIFY_SECRET=$NOTIFY_SECRET
EOF
echo "Saved to: $ENV_FILE"
echo ""
echo "Next: Run ./deploy-aws.sh to set up AgentCore Runtime + Identity"
