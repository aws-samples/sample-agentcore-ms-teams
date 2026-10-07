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
# Deploy Azure Infrastructure for AgentCore + Microsoft Teams Integration
#
# Creates:
#   - Resource Group
#   - Entra ID App Registrations (Bot + Outbound)
#   - Azure Bot resource with Teams channel
#   - Azure Container Registry (ACR)
#   - Container Apps Environment + Bot container deployment
#   - Configures bot messaging endpoint
#
# Prerequisites:
#   - Azure CLI installed and logged in (az login)
#   - Docker installed (for building/pushing container image)
#   - jq installed
#   - Logged into the correct Entra ID tenant
#
# Usage:
#   ./deploy-azure.sh [--tenant-id TENANT_ID] [--region REGION] [--bot-name BOT_NAME]
#
# =============================================================================

# ---------- Defaults ----------
REGION="${REGION:-westus2}"
BOT_NAME="${BOT_NAME:-agentcore-bot-demo}"
RESOURCE_GROUP="${RESOURCE_GROUP:-agentcore-msteams-rg}"
ACR_NAME="${ACR_NAME:-agentcoredemo2cr}"
CONTAINER_APP_ENV="${CONTAINER_APP_ENV:-agentcore-teams-env}"
CONTAINER_APP_NAME="${CONTAINER_APP_NAME:-agentcore-teams-bot}"

# ---------- Parse CLI Args ----------
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

# ---------- Resolve Tenant ----------
TENANT_ID="${TENANT_ID:-$(az account show --query tenantId -o tsv)}"
echo "============================================================"
echo " AgentCore + Teams - Azure Deployment"
echo "============================================================"
echo ""
echo "  Tenant ID:        $TENANT_ID"
echo "  Region:           $REGION"
echo "  Resource Group:   $RESOURCE_GROUP"
echo "  Bot Name:         $BOT_NAME"
echo "  ACR:              $ACR_NAME"
echo "  Container App:    $CONTAINER_APP_NAME"
echo ""

# =============================================================================
# Step 1: Create Resource Group
# =============================================================================
echo "--- Step 1: Resource Group ---"
az group create --name "$RESOURCE_GROUP" --location "$REGION" -o none
echo "  Created: $RESOURCE_GROUP in $REGION"

# =============================================================================
# Step 2: Create Entra ID App Registrations
# =============================================================================
echo ""
echo "--- Step 2: Entra ID App Registrations ---"

# --- App 1: AgentCore-Teams-Bot ---
echo "  Creating AgentCore-Teams-Bot app registration..."
BOT_APP=$(az ad app create \
  --display-name "AgentCore-Teams-Bot" \
  --sign-in-audience "AzureADMyOrg" \
  --query "{appId:appId, id:id}" \
  -o json)

BOT_APP_ID=$(echo "$BOT_APP" | jq -r '.appId')
BOT_OBJECT_ID=$(echo "$BOT_APP" | jq -r '.id')
echo "    App (client) ID: $BOT_APP_ID"

# Set token version to v2.0
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$BOT_OBJECT_ID" \
  --headers "Content-Type=application/json" \
  --body '{"api":{"requestedAccessTokenVersion":2}}' 2>/dev/null
echo "    Set accessTokenAcceptedVersion = 2"

# Expose an API scope for Gateway JWT validation
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
  }" 2>/dev/null
echo "    Exposed API: api://$BOT_APP_ID/Agent.Invoke"

# Create service principal for the bot app
az ad sp create --id "$BOT_APP_ID" 2>/dev/null || true

# Create client secret
BOT_APP_SECRET=$(az ad app credential reset \
  --id "$BOT_OBJECT_ID" \
  --display-name "bot-secret" \
  --years 1 \
  --query password -o tsv)
echo "    Client secret created"

# --- App 2: AgentCore-Outbound (Graph API for notifications) ---
echo ""
echo "  Creating AgentCore-Outbound app registration..."
OUTBOUND_APP=$(az ad app create \
  --display-name "AgentCore-Outbound" \
  --sign-in-audience "AzureADMyOrg" \
  --query "{appId:appId, id:id}" \
  -o json)

OUTBOUND_APP_ID=$(echo "$OUTBOUND_APP" | jq -r '.appId')
OUTBOUND_OBJECT_ID=$(echo "$OUTBOUND_APP" | jq -r '.id')
echo "    App (client) ID: $OUTBOUND_APP_ID"

# Add Graph API application permissions
GRAPH_API_ID="00000003-0000-0000-c000-000000000000"
az ad app permission add \
  --id "$OUTBOUND_OBJECT_ID" \
  --api "$GRAPH_API_ID" \
  --api-permissions \
    "7ab1d382-f21e-4acd-a863-ba3e13f7da61=Role" \
    "d9c48af6-9ad9-47ad-82c3-63757137b9af=Role" \
    "70b94f1b-68a0-483b-ba36-ebe032e0e608=Role" \
  2>/dev/null
echo "    Added Graph permissions: ChannelMessage.Send, Chat.Create, TeamsActivity.Send"

# Create service principal and grant admin consent
az ad sp create --id "$OUTBOUND_APP_ID" 2>/dev/null || true
echo "    Granting admin consent..."
az ad app permission admin-consent --id "$OUTBOUND_OBJECT_ID" 2>/dev/null || \
  echo "    WARNING: Admin consent may need manual grant in Entra portal"

# Create client secret for outbound
OUTBOUND_APP_SECRET=$(az ad app credential reset \
  --id "$OUTBOUND_OBJECT_ID" \
  --display-name "agentcore-outbound-secret" \
  --years 1 \
  --query password -o tsv)
echo "    Client secret created"

# =============================================================================
# Step 3: Create Azure Bot Resource
# =============================================================================
echo ""
echo "--- Step 3: Azure Bot Resource ---"

az bot create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$BOT_NAME" \
  --kind registration \
  --sku F0 \
  --app-type SingleTenant \
  --appid "$BOT_APP_ID" \
  --tenant-id "$TENANT_ID" \
  -o none 2>/dev/null || echo "  Bot resource may already exist, continuing..."

echo "  Created Azure Bot: $BOT_NAME (F0, SingleTenant)"

# Enable Teams channel
az bot msteams create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$BOT_NAME" \
  -o none 2>/dev/null || echo "  Teams channel may already be enabled"
echo "  Enabled Teams channel"

# =============================================================================
# Step 4: Create Azure Container Registry
# =============================================================================
echo ""
echo "--- Step 4: Azure Container Registry ---"

az acr create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ACR_NAME" \
  --sku Basic \
  --admin-enabled true \
  --location "$REGION" \
  -o none 2>/dev/null || echo "  ACR may already exist, continuing..."

ACR_LOGIN_SERVER="${ACR_NAME}.azurecr.io"
echo "  ACR: $ACR_LOGIN_SERVER"

# =============================================================================
# Step 5: Build and Push Container Image
# =============================================================================
echo ""
echo "--- Step 5: Build and Push Bot Container ---"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BOT_DIR="$PROJECT_ROOT/bot"

# Build TypeScript
echo "  Building TypeScript..."
(cd "$BOT_DIR" && npm ci && npm run build)

# Login to ACR
az acr login --name "$ACR_NAME"

# Build and push Docker image
IMAGE_TAG="${ACR_LOGIN_SERVER}/teams-bot:$(date +%Y%m%d-%H%M%S)"
IMAGE_LATEST="${ACR_LOGIN_SERVER}/teams-bot:latest"

echo "  Building Docker image..."
docker build -t "$IMAGE_TAG" -t "$IMAGE_LATEST" "$BOT_DIR"

echo "  Pushing to ACR..."
docker push "$IMAGE_TAG"
docker push "$IMAGE_LATEST"
echo "  Pushed: $IMAGE_TAG"

# =============================================================================
# Step 6: Create Container Apps Environment and Deploy
# =============================================================================
echo ""
echo "--- Step 6: Container Apps Deployment ---"

# Create Container Apps environment
az containerapp env create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CONTAINER_APP_ENV" \
  --location "$REGION" \
  -o none 2>/dev/null || echo "  Environment may already exist, continuing..."

# Get ACR credentials
ACR_PASSWORD=$(az acr credential show --name "$ACR_NAME" --query "passwords[0].value" -o tsv)

# Deploy container app
az containerapp create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CONTAINER_APP_NAME" \
  --environment "$CONTAINER_APP_ENV" \
  --image "$IMAGE_LATEST" \
  --registry-server "$ACR_LOGIN_SERVER" \
  --registry-username "$ACR_NAME" \
  --registry-password "$ACR_PASSWORD" \
  --target-port 3978 \
  --ingress external \
  --min-replicas 1 \
  --max-replicas 3 \
  --env-vars \
    "BOT_APP_ID=$BOT_APP_ID" \
    "BOT_APP_SECRET=$BOT_APP_SECRET" \
    "TENANT_ID=$TENANT_ID" \
  -o none 2>/dev/null || \
az containerapp update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CONTAINER_APP_NAME" \
  --image "$IMAGE_LATEST" \
  --set-env-vars \
    "BOT_APP_ID=$BOT_APP_ID" \
    "BOT_APP_SECRET=$BOT_APP_SECRET" \
    "TENANT_ID=$TENANT_ID" \
  -o none

# Get the FQDN
BOT_FQDN=$(az containerapp show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CONTAINER_APP_NAME" \
  --query "properties.configuration.ingress.fqdn" -o tsv)

BOT_ENDPOINT="https://$BOT_FQDN/api/messages"
NOTIFY_ENDPOINT="https://$BOT_FQDN/api/notify"

echo "  Deployed: $CONTAINER_APP_NAME"
echo "  FQDN: $BOT_FQDN"
echo "  Bot Endpoint: $BOT_ENDPOINT"
echo "  Notify Endpoint: $NOTIFY_ENDPOINT"

# =============================================================================
# Step 7: Set Bot Messaging Endpoint
# =============================================================================
echo ""
echo "--- Step 7: Configure Bot Messaging Endpoint ---"

az bot update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$BOT_NAME" \
  --endpoint "$BOT_ENDPOINT" \
  -o none

echo "  Bot messaging endpoint set to: $BOT_ENDPOINT"

# =============================================================================
# Output Summary
# =============================================================================
echo ""
echo "============================================================"
echo " DEPLOYMENT COMPLETE"
echo "============================================================"
echo ""
echo " Resource Group:     $RESOURCE_GROUP"
echo " Region:             $REGION"
echo " Tenant ID:          $TENANT_ID"
echo ""
echo " --- Entra ID Apps ---"
echo " Bot App ID:         $BOT_APP_ID"
echo " Bot App Secret:     (stored in .env — do not share)"
echo " Bot API Scope:      api://$BOT_APP_ID/Agent.Invoke"
echo " Outbound App ID:    $OUTBOUND_APP_ID"
echo " Outbound Secret:    (stored in .env — do not share)"
echo ""
echo " --- Azure Bot ---"
echo " Bot Name:           $BOT_NAME"
echo " Messaging Endpoint: $BOT_ENDPOINT"
echo ""
echo " --- Container Apps ---"
echo " FQDN:               $BOT_FQDN"
echo " Notify URL:         $NOTIFY_ENDPOINT"
echo " Image:              $IMAGE_LATEST"
echo ""
echo " --- Values for AWS deploy-aws.sh ---"
echo " BOT_APP_ID=$BOT_APP_ID"
echo " TENANT_ID=$TENANT_ID"
echo " BOT_NOTIFY_URL=$NOTIFY_ENDPOINT"
echo ""
echo " --- Discovery URL (for AgentCore JWT auth) ---"
echo " https://login.microsoftonline.com/$TENANT_ID/v2.0/.well-known/openid-configuration"
echo ""

# Save .env file
ENV_FILE="$PROJECT_ROOT/.env"
cat > "$ENV_FILE" <<EOF
# AgentCore + Teams Integration - Generated by deploy-azure.sh
# DO NOT COMMIT THIS FILE

# Entra ID / Azure AD
TENANT_ID=$TENANT_ID
BOT_APP_ID=$BOT_APP_ID
BOT_APP_SECRET=$BOT_APP_SECRET
BOT_API_SCOPE=api://$BOT_APP_ID/Agent.Invoke
OUTBOUND_APP_ID=$OUTBOUND_APP_ID
OUTBOUND_APP_SECRET=$OUTBOUND_APP_SECRET
DISCOVERY_URL=https://login.microsoftonline.com/$TENANT_ID/v2.0/.well-known/openid-configuration

# Azure Bot
BOT_NAME=$BOT_NAME
BOT_ENDPOINT=$BOT_ENDPOINT

# Container Apps
BOT_FQDN=$BOT_FQDN
TEAMS_BOT_NOTIFY_URL=$NOTIFY_ENDPOINT

# AWS (fill after running deploy-aws.sh)
# AWS_REGION=us-east-1
# AGENTCORE_RUNTIME_ID=
# AGENTCORE_GATEWAY_URL=
EOF

echo "  Saved environment values to: $ENV_FILE"
echo ""
echo " Next steps:"
echo "   1. Run deploy-aws.sh to deploy the AgentCore agent"
echo "   2. Upload Teams app package (appPackage.zip) to Teams Admin Center"
echo "   3. Test by messaging @AgentCore Bot in Teams"
