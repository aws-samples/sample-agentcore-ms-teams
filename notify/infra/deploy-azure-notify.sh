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
# Deploy Azure infra for the Notify Bot
#   1. Azure Bot (SingleTenant) + Teams channel
#   2. Build + push container (Node 20)
#   3. Container App with env vars
#   4. Set bot messaging endpoint
#   5. Generate Teams app package (must be uploaded to catalog for proactive install)
#
# Prereq: ./setup-entra-notify.sh has run (../.env populated)
# Usage:  ./deploy-azure-notify.sh [--region REGION]
# =============================================================================

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found. Run setup-entra-notify.sh first."; exit 1; }
set -a; source "$ENV_FILE"; set +a

REGION="${REGION:-westus2}"
RESOURCE_GROUP="${RESOURCE_GROUP:-agentcore-msteams-rg}"
BOT_NAME="${BOT_NAME:-agentcore-notify-bot}"
APP_NAME="${APP_NAME:-agentcore-notify-bot}"
ACR_NAME="${ACR_NAME:-agentcoredemo2cr}"
ENV_NAME="${ENV_NAME:-bot-env-west}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

: "${TENANT_ID:?}"; : "${NOTIFY_BOT_APP_ID:?}"; : "${NOTIFY_BOT_APP_SECRET:?}"
echo "Bot App: $NOTIFY_BOT_APP_ID | Region: $REGION"
echo ""

# 1. Azure Bot
echo "=== 1. Azure Bot ==="
az bot create \
  --resource-group "$RESOURCE_GROUP" --name "$BOT_NAME" \
  --appid "$NOTIFY_BOT_APP_ID" --app-type "SingleTenant" --tenant-id "$TENANT_ID" \
  --sku "F0" --location "global" -o none 2>/dev/null || true
az bot msteams create --resource-group "$RESOURCE_GROUP" --name "$BOT_NAME" -o none 2>/dev/null || true
echo "  Bot + Teams channel ready: $BOT_NAME"

# 2. Build container
echo ""
echo "=== 2. Build container ==="
BOT_DIR="$(cd "$(dirname "$0")/../bot" && pwd)"
( cd "$BOT_DIR" && npm install --quiet >/dev/null 2>&1 && ./node_modules/.bin/tsc )
az acr build --registry "$ACR_NAME" --resource-group "$RESOURCE_GROUP" \
  --image "teams-notify-bot:latest" --file "$BOT_DIR/Dockerfile" "$BOT_DIR" -o none
echo "  Image: $ACR_NAME.azurecr.io/teams-notify-bot:latest"

# 3. Container App
echo ""
echo "=== 3. Container App ==="
ACR_PASSWORD=$(az acr credential show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query "passwords[0].value" -o tsv)
az containerapp create \
  --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" --environment "$ENV_NAME" \
  --image "$ACR_NAME.azurecr.io/teams-notify-bot:latest" \
  --registry-server "$ACR_NAME.azurecr.io" --registry-username "$ACR_NAME" --registry-password "$ACR_PASSWORD" \
  --target-port 3980 --ingress "external" --min-replicas 1 --max-replicas 1 \
  --env-vars \
    "NOTIFY_BOT_APP_ID=$NOTIFY_BOT_APP_ID" \
    "NOTIFY_BOT_APP_SECRET=$NOTIFY_BOT_APP_SECRET" \
    "TENANT_ID=$TENANT_ID" \
    "NOTIFY_SECRET=$NOTIFY_SECRET" \
    "TEAMS_APP_EXTERNAL_ID=$TEAMS_APP_EXTERNAL_ID" \
  -o none 2>/dev/null || \
az containerapp update \
  --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" \
  --image "$ACR_NAME.azurecr.io/teams-notify-bot:latest" \
  --set-env-vars \
    "NOTIFY_BOT_APP_ID=$NOTIFY_BOT_APP_ID" \
    "NOTIFY_BOT_APP_SECRET=$NOTIFY_BOT_APP_SECRET" \
    "TENANT_ID=$TENANT_ID" \
    "NOTIFY_SECRET=$NOTIFY_SECRET" \
    "TEAMS_APP_EXTERNAL_ID=$TEAMS_APP_EXTERNAL_ID" \
  -o none

APP_FQDN=$(az containerapp show --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" --query "properties.configuration.ingress.fqdn" -o tsv)
echo "  FQDN: $APP_FQDN"

# 4. Bot endpoint
az bot update --resource-group "$RESOURCE_GROUP" --name "$BOT_NAME" \
  --endpoint "https://$APP_FQDN/api/messages" -o none
echo "  Endpoint set"

# 5. Teams app package
echo ""
echo "=== 5. Teams app package ==="
MANIFEST_ID="${TEAMS_APP_EXTERNAL_ID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
PKG_DIR="$BOT_DIR/appPackage"
mkdir -p "$PKG_DIR"

cat > "$PKG_DIR/manifest.json" <<EOF
{
  "\$schema": "https://developer.microsoft.com/en-us/json-schemas/teams/v1.17/MicrosoftTeams.schema.json",
  "manifestVersion": "1.17",
  "version": "1.0.0",
  "id": "$MANIFEST_ID",
  "developer": {
    "name": "AgentCore Demo",
    "websiteUrl": "https://aws.amazon.com/bedrock/agentcore/",
    "privacyUrl": "https://aws.amazon.com/privacy/",
    "termsOfUseUrl": "https://aws.amazon.com/service-terms/"
  },
  "name": { "short": "AgentCore Notify", "full": "Amazon Bedrock AgentCore Notification Bot" },
  "description": {
    "short": "Proactive notifications from AgentCore agents",
    "full": "Delivers proactive Adaptive Card notifications to users and channels, sent by Amazon Bedrock AgentCore agents."
  },
  "icons": { "color": "color.png", "outline": "outline.png" },
  "accentColor": "#FF9900",
  "bots": [
    { "botId": "$NOTIFY_BOT_APP_ID", "scopes": ["personal", "team", "groupChat"], "supportsFiles": false, "isNotificationOnly": true }
  ],
  "permissions": ["identity", "messageTeamMembers"],
  "validDomains": ["$APP_FQDN"]
}
EOF

( cd "$PKG_DIR" && zip -r ../appPackage.zip manifest.json color.png outline.png >/dev/null )
echo "  Package: $BOT_DIR/appPackage.zip  (manifest id: $MANIFEST_ID)"

# Persist the external id (== manifest id) so the bot can find the catalog app
grep -v -E '^TEAMS_APP_EXTERNAL_ID=' "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
echo "TEAMS_APP_EXTERNAL_ID=$MANIFEST_ID" >> "$ENV_FILE"
echo "NOTIFY_BOT_FQDN=$APP_FQDN" >> "$ENV_FILE"

echo ""
echo "============================================================"
echo "  AZURE NOTIFY DEPLOYMENT COMPLETE"
echo "============================================================"
echo "Bot FQDN:        $APP_FQDN"
echo "Notify endpoint: https://$APP_FQDN/api/notify"
echo "App package:     $BOT_DIR/appPackage.zip"
echo ""
echo ">>> IMPORTANT: Upload appPackage.zip to the Teams ADMIN CENTER app catalog"
echo "    (Teams admin -> Manage apps -> Upload) so the bot can be proactively"
echo "    installed for users/teams. Sideloading to one chat is NOT enough."
echo ""
echo "Then re-run deploy-azure-notify.sh once (so TEAMS_APP_EXTERNAL_ID propagates"
echo "to the container), or just restart the container app."
echo ""
echo "Next: ./deploy-aws-notify.sh"
