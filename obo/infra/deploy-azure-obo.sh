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
# Deploy Azure Infrastructure for the OBO Demo  [WORKING ARCHITECTURE]
#
# Creates / updates:
#   1. User-Assigned Managed Identity (agentcore-bot-identity)
#   2. Federated Identity Credential on the bot app reg
#        subject  = MI principalId
#        issuer   = https://login.microsoftonline.com/<tenant>/v2.0
#        audience = api://AzureADTokenExchange
#      (lets the bot mint its OWN app token to call AgentCore WITHOUT a secret,
#       via ClientAssertionCredential -> ManagedIdentityCredential)
#   3. Azure Bot (UserAssignedMSI type — MultiTenant bot creation is deprecated)
#   4. ACR build + push of the bot container (Node 20 base image)
#   5. Container App with the MI assigned + all required env vars
#   6. Bot messaging endpoint
#   7. Teams app package (manifest w/ webApplicationInfo + validDomains + zip)
#
# IMPORTANT auth facts baked in here (see ARCHITECTURE-OBO.md "Gotchas"):
#   - App reg signInAudience = AzureADMultipleOrgs (set in setup-entra-obo.sh)
#     BUT the bot SDK MicrosoftAppType is "SingleTenant" (in code) AND the Azure
#     Bot resource is UserAssignedMSI. These are intentionally different.
#   - There is NO Bot Service OAuth connection (no `az bot authsetting`). teams-ai
#     does the SSO + OBO Graph-token exchange itself using the bot app's secret.
#
# Prerequisites:
#   - ./setup-entra-obo.sh has run (../.env populated)
#   - az logged in; Docker not required (uses `az acr build`)
#
# Usage:
#   ./deploy-azure-obo.sh [--region REGION] [--resource-group RG] [--bot-name NAME]
# =============================================================================

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run setup-entra-obo.sh first."
  exit 1
fi
set -a; source "$ENV_FILE"; set +a

# ---------- Defaults ----------
REGION="${REGION:-westus2}"
RESOURCE_GROUP="${RESOURCE_GROUP:-agentcore-msteams-rg}"
BOT_NAME="${BOT_NAME:-agentcore-obo-bot}"
APP_NAME="${APP_NAME:-agentcore-obo-bot}"
ACR_NAME="${ACR_NAME:-agentcoredemo2cr}"
MI_NAME="${MI_NAME:-agentcore-bot-identity}"
ENV_NAME="${ENV_NAME:-bot-env-west}"
SSO_CONNECTION_NAME="${SSO_CONNECTION_NAME:-TeamsSSO}"
TARGET_PORT="${TARGET_PORT:-3979}"

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2;;
    --bot-name) BOT_NAME="$2"; shift 2;;
    --app-name) APP_NAME="$2"; shift 2;;
    --acr-name) ACR_NAME="$2"; shift 2;;
    --mi-name) MI_NAME="$2"; shift 2;;
    --env-name) ENV_NAME="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

: "${TENANT_ID:?TENANT_ID required (run setup-entra-obo.sh)}"
: "${OBO_BOT_APP_ID:?OBO_BOT_APP_ID required (run setup-entra-obo.sh)}"
: "${OBO_BOT_APP_SECRET:?OBO_BOT_APP_SECRET required (run setup-entra-obo.sh)}"

BOT_OBJECT_ID=$(az ad app show --id "$OBO_BOT_APP_ID" --query "id" -o tsv)

echo "Tenant:   $TENANT_ID"
echo "Bot App:  $OBO_BOT_APP_ID"
echo "Region:   $REGION  RG: $RESOURCE_GROUP"
echo ""

# =============================================================================
# 0. Resource Group
# =============================================================================
echo "=== 0. Resource Group ==="
az group create --name "$RESOURCE_GROUP" --location "$REGION" -o none
echo "  $RESOURCE_GROUP ($REGION)"

# =============================================================================
# 1. User-Assigned Managed Identity
# =============================================================================
echo ""
echo "=== 1. Managed Identity ==="
MI_OUTPUT=$(az identity create \
  --name "$MI_NAME" --resource-group "$RESOURCE_GROUP" --location "$REGION" \
  --query "{clientId:clientId, principalId:principalId, id:id}" -o json 2>/dev/null \
  || az identity show \
  --name "$MI_NAME" --resource-group "$RESOURCE_GROUP" \
  --query "{clientId:clientId, principalId:principalId, id:id}" -o json)

MI_CLIENT_ID=$(echo "$MI_OUTPUT" | jq -r '.clientId')
MI_PRINCIPAL_ID=$(echo "$MI_OUTPUT" | jq -r '.principalId')
MI_RESOURCE_ID=$(echo "$MI_OUTPUT" | jq -r '.id')
echo "  Name:        $MI_NAME"
echo "  Client ID:   $MI_CLIENT_ID"
echo "  Principal:   $MI_PRINCIPAL_ID"

# =============================================================================
# 2. Federated Identity Credential (MI -> bot app, no secret for AgentCore call)
# =============================================================================
echo ""
echo "=== 2. Federated Identity Credential ==="
# subject MUST be the MI principalId; audience MUST be api://AzureADTokenExchange.
az ad app federated-credential create \
  --id "$BOT_OBJECT_ID" \
  --parameters "{
    \"name\": \"managed-identity-federation\",
    \"issuer\": \"https://login.microsoftonline.com/$TENANT_ID/v2.0\",
    \"subject\": \"$MI_PRINCIPAL_ID\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" -o none 2>/dev/null \
  || echo "  (federated credential already exists)"
echo "  MI ($MI_PRINCIPAL_ID) -> bot app ($OBO_BOT_APP_ID)"

# =============================================================================
# 3. Azure Bot (UserAssignedMSI)
# =============================================================================
echo ""
echo "=== 3. Azure Bot ==="
# UserAssignedMSI: MultiTenant bot creation is deprecated by Azure. The app reg
# is still multi-tenant for the OAuth popup; the bot RESOURCE uses the MSI type.
az bot create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$BOT_NAME" \
  --app-type "UserAssignedMSI" \
  --appid "$OBO_BOT_APP_ID" \
  --tenant-id "$TENANT_ID" \
  --msi-resource-id "$MI_RESOURCE_ID" \
  --sku "F0" \
  --location "global" \
  -o none 2>/dev/null || true
echo "  Bot: $BOT_NAME (UserAssignedMSI)"

az bot msteams create --resource-group "$RESOURCE_GROUP" --name "$BOT_NAME" -o none 2>/dev/null || true
echo "  Teams channel enabled"
echo "  (No Bot Service OAuth connection — teams-ai handles SSO/OBO itself)"

# =============================================================================
# 4. Build + push bot container (Node 20)
# =============================================================================
echo ""
echo "=== 4. Build Container Image ==="
az acr create --resource-group "$RESOURCE_GROUP" --name "$ACR_NAME" \
  --sku "Basic" --admin-enabled true -o none 2>/dev/null || true

BOT_DIR="$(cd "$(dirname "$0")/../bot" && pwd)"
echo "  Compiling TypeScript..."
( cd "$BOT_DIR" && npm install --quiet >/dev/null 2>&1 && ./node_modules/.bin/tsc )

# Dockerfile uses node:20-slim (Node 22 had a botframework signing-key fetch bug).
az acr build \
  --registry "$ACR_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --image "teams-bot-obo:latest" \
  --file "$BOT_DIR/Dockerfile" \
  "$BOT_DIR" -o none
echo "  Image: $ACR_NAME.azurecr.io/teams-bot-obo:latest"

# =============================================================================
# 5. Container Apps Environment + Container App (MI assigned + env vars)
# =============================================================================
echo ""
echo "=== 5. Container App ==="
az containerapp env create --name "$ENV_NAME" --resource-group "$RESOURCE_GROUP" \
  --location "$REGION" -o none 2>/dev/null || true

ACR_PASSWORD=$(az acr credential show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" \
  --query "passwords[0].value" -o tsv)

# Env vars consumed by the bot (src/index.ts + src/agentcoreClient.ts):
#   OBO_BOT_APP_ID, OBO_BOT_APP_SECRET, TENANT_ID, MI_CLIENT_ID, BOT_DOMAIN,
#   AGENTCORE_RUNTIME_ID, AWS_ACCOUNT_ID, AWS_REGION, SSO_CONNECTION_NAME
# BOT_DOMAIN must be the FQDN — set after the app exists (two-pass below).
ENV_ARGS=(
  "OBO_BOT_APP_ID=$OBO_BOT_APP_ID"
  "OBO_BOT_APP_SECRET=$OBO_BOT_APP_SECRET"
  "TENANT_ID=$TENANT_ID"
  "MI_CLIENT_ID=$MI_CLIENT_ID"
  "SSO_CONNECTION_NAME=$SSO_CONNECTION_NAME"
  "AGENTCORE_RUNTIME_ID=${AGENTCORE_RUNTIME_ID:-}"
  "AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID:-}"
  "AWS_REGION=${AWS_REGION:-us-east-1}"
)

az containerapp create \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --environment "$ENV_NAME" \
  --image "$ACR_NAME.azurecr.io/teams-bot-obo:latest" \
  --registry-server "$ACR_NAME.azurecr.io" \
  --registry-username "$ACR_NAME" \
  --registry-password "$ACR_PASSWORD" \
  --target-port "$TARGET_PORT" \
  --ingress "external" \
  --min-replicas 1 \
  --max-replicas 1 \
  --user-assigned "$MI_RESOURCE_ID" \
  --env-vars "${ENV_ARGS[@]}" \
  -o none 2>/dev/null || {
    # Update path: ensure MI is assigned, refresh image + env.
    az containerapp identity assign --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" \
      --user-assigned "$MI_RESOURCE_ID" -o none 2>/dev/null || true
    az containerapp update \
      --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" \
      --image "$ACR_NAME.azurecr.io/teams-bot-obo:latest" \
      --set-env-vars "${ENV_ARGS[@]}" -o none
  }

APP_FQDN=$(az containerapp show --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" \
  --query "properties.configuration.ingress.fqdn" -o tsv)
BOT_ENDPOINT="https://$APP_FQDN/api/messages"
echo "  FQDN: $APP_FQDN"

# Second pass: set BOT_DOMAIN now that we know the FQDN (auth-start/end.html use it).
az containerapp update --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" \
  --set-env-vars "BOT_DOMAIN=$APP_FQDN" -o none
echo "  BOT_DOMAIN=$APP_FQDN"

# =============================================================================
# 6. Bot messaging endpoint
# =============================================================================
echo ""
echo "=== 6. Bot Endpoint ==="
az bot update --resource-group "$RESOURCE_GROUP" --name "$BOT_NAME" \
  --endpoint "$BOT_ENDPOINT" -o none
echo "  $BOT_ENDPOINT"

# =============================================================================
# 7. SPA redirect URI on the app reg (now that FQDN is known)
# =============================================================================
echo ""
echo "=== 7. SPA Redirect URI ==="
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$BOT_OBJECT_ID" \
  --headers "Content-Type=application/json" \
  --body "{
    \"web\": {\"redirectUris\": [\"https://token.botframework.com/.auth/web/redirect\"]},
    \"spa\": {\"redirectUris\": [\"https://$APP_FQDN/auth-end.html\"]}
  }" -o none
echo "  SPA: https://$APP_FQDN/auth-end.html"
echo "  Web: https://token.botframework.com/.auth/web/redirect"

# =============================================================================
# 8. Teams App Package
# =============================================================================
echo ""
echo "=== 8. Teams App Package ==="
MANIFEST_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')

cat > "$BOT_DIR/appPackage/manifest.json" <<EOF
{
  "\$schema": "https://developer.microsoft.com/en-us/json-schemas/teams/v1.17/MicrosoftTeams.schema.json",
  "manifestVersion": "1.17",
  "version": "1.0.0",
  "id": "$MANIFEST_ID",
  "developer": {
    "name": "AgentCore OBO Demo",
    "websiteUrl": "https://aws.amazon.com/bedrock/agentcore/",
    "privacyUrl": "https://aws.amazon.com/privacy/",
    "termsOfUseUrl": "https://aws.amazon.com/service-terms/"
  },
  "name": {
    "short": "AgentCore OBO",
    "full": "AgentCore Bot (On-Behalf-Of User Identity)"
  },
  "description": {
    "short": "AI agent acting on YOUR behalf",
    "full": "An AI agent that accesses your Microsoft 365 data using YOUR identity. Demonstrates On-Behalf-Of user identity passthrough through Amazon Bedrock AgentCore."
  },
  "icons": {
    "color": "color.png",
    "outline": "outline.png"
  },
  "accentColor": "#232F3E",
  "bots": [
    {
      "botId": "$OBO_BOT_APP_ID",
      "scopes": ["personal", "team", "groupChat"],
      "supportsFiles": false,
      "isNotificationOnly": false,
      "commandLists": [
        {
          "scopes": ["personal"],
          "commands": [
            {"title": "whoami", "description": "Show your authenticated identity"},
            {"title": "my-emails", "description": "Read your recent emails"},
            {"title": "my-calendar", "description": "Show your upcoming meetings"}
          ]
        }
      ]
    }
  ],
  "permissions": ["identity", "messageTeamMembers"],
  "validDomains": ["$APP_FQDN"],
  "webApplicationInfo": {
    "id": "$OBO_BOT_APP_ID",
    "resource": "api://botid-$OBO_BOT_APP_ID"
  }
}
EOF

# Icons (reuse from the other bot package if present)

( cd "$BOT_DIR/appPackage" && zip -q -r ../appPackage.zip manifest.json color.png outline.png )
echo "  Package: $BOT_DIR/appPackage.zip"

# =============================================================================
# 9. Persist values to ../.env
# =============================================================================
echo ""
echo "=== 9. Save .env ==="
# Drop old MI/BOT_DOMAIN lines, re-append fresh.
grep -v -E '^(MI_CLIENT_ID|MI_PRINCIPAL_ID|BOT_DOMAIN)=' "$ENV_FILE" > "$ENV_FILE.tmp" || true
mv "$ENV_FILE.tmp" "$ENV_FILE"
cat >> "$ENV_FILE" <<EOF
MI_CLIENT_ID=$MI_CLIENT_ID
MI_PRINCIPAL_ID=$MI_PRINCIPAL_ID
BOT_DOMAIN=$APP_FQDN
EOF
echo "  Saved: $ENV_FILE"

# =============================================================================
# Output
# =============================================================================
echo ""
echo "============================================================"
echo "  AZURE OBO DEPLOYMENT COMPLETE"
echo "============================================================"
echo ""
echo "Bot endpoint:  $BOT_ENDPOINT"
echo "MI client ID:  $MI_CLIENT_ID"
echo "App package:   $BOT_DIR/appPackage.zip"
echo ""
echo "Next:"
echo "  1. ./deploy-aws-obo.sh   (IAM role + agentcore deploy + JWT authorizer)"
echo "  2. After AWS deploy, re-run a containerapp update to inject"
echo "     AGENTCORE_RUNTIME_ID / AWS_ACCOUNT_ID (deploy-aws-obo.sh prints them"
echo "     into .env; re-run this script or update env vars directly)."
echo "  3. Sideload appPackage.zip into Teams, message the bot: 'whoami'."
