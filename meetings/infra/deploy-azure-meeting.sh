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
# Deploy Azure infra for the Meeting Assistant
#   1. Build + push container (Node 20) - serves side panel + /api/agent proxy
#   2. Container App with env vars (incl. runtime id from .env)
#   3. Update Entra SPA redirect to the real FQDN
#   4. Generate Teams app package (configurableTabs / meetingSidePanel)
#
# Prereq: setup-entra-meeting.sh + deploy-aws-meeting.sh (../.env set)
# Usage:  ./deploy-azure-meeting.sh [--region REGION]
# =============================================================================

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: run setup-entra-meeting.sh first"; exit 1; }
set -a; source "$ENV_FILE"; set +a

REGION="${REGION:-westus2}"
RESOURCE_GROUP="${RESOURCE_GROUP:-agentcore-msteams-rg}"
APP_NAME="${APP_NAME:-agentcore-meeting-app}"
ACR_NAME="${ACR_NAME:-agentcoredemo2cr}"
ENV_NAME="${ENV_NAME:-bot-env-west}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

: "${TENANT_ID:?}"; : "${MEETING_APP_ID:?}"; : "${MEETING_APP_SECRET:?}"
echo "App: $MEETING_APP_ID | Region: $REGION"
echo ""

# 1. Build container
echo "=== 1. Build container ==="
APP_DIR="$(cd "$(dirname "$0")/../app" && pwd)"
( cd "$APP_DIR" && npm install --quiet >/dev/null 2>&1 && ./node_modules/.bin/tsc )
az acr build --registry "$ACR_NAME" --resource-group "$RESOURCE_GROUP" \
  --image "teams-meeting-app:latest" --file "$APP_DIR/Dockerfile" "$APP_DIR" -o none
echo "  Image: $ACR_NAME.azurecr.io/teams-meeting-app:latest"

# 2. Container App
echo ""
echo "=== 2. Container App ==="
ACR_PASSWORD=$(az acr credential show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query "passwords[0].value" -o tsv)
az containerapp create \
  --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" --environment "$ENV_NAME" \
  --image "$ACR_NAME.azurecr.io/teams-meeting-app:latest" \
  --registry-server "$ACR_NAME.azurecr.io" --registry-username "$ACR_NAME" --registry-password "$ACR_PASSWORD" \
  --target-port 3981 --ingress "external" --min-replicas 1 --max-replicas 1 \
  --env-vars \
    "TENANT_ID=$TENANT_ID" "MEETING_APP_ID=$MEETING_APP_ID" "MEETING_APP_SECRET=$MEETING_APP_SECRET" \
    "MEETING_AGENT_RUNTIME_ID=${MEETING_AGENT_RUNTIME_ID:-}" "AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID:-}" "AWS_REGION=${AWS_REGION:-us-east-1}" \
  -o none 2>/dev/null || \
az containerapp update \
  --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" \
  --image "$ACR_NAME.azurecr.io/teams-meeting-app:latest" \
  --set-env-vars \
    "TENANT_ID=$TENANT_ID" "MEETING_APP_ID=$MEETING_APP_ID" "MEETING_APP_SECRET=$MEETING_APP_SECRET" \
    "MEETING_AGENT_RUNTIME_ID=${MEETING_AGENT_RUNTIME_ID:-}" "AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID:-}" "AWS_REGION=${AWS_REGION:-us-east-1}" \
  -o none

APP_FQDN=$(az containerapp show --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" --query "properties.configuration.ingress.fqdn" -o tsv)
echo "  FQDN: $APP_FQDN"

# 3. Update Entra SPA redirect to real FQDN
echo ""
echo "=== 3. Entra SPA redirect ==="
OBJ_ID=$(az ad app show --id "$MEETING_APP_ID" --query "id" -o tsv)
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$OBJ_ID" \
  --headers "Content-Type=application/json" \
  --body "{\"spa\":{\"redirectUris\":[\"https://$APP_FQDN/auth-end.html\"]}}" -o none
echo "  https://$APP_FQDN/auth-end.html"

# 4. Teams app package (meeting side panel)
echo ""
echo "=== 4. Teams app package ==="
MANIFEST_ID="${MEETING_TEAMS_APP_ID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
PKG_DIR="$APP_DIR/appPackage"
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
  "name": { "short": "AgentCore Meeting", "full": "Amazon Bedrock AgentCore Meeting Assistant" },
  "description": {
    "short": "AI meeting copilot with memory",
    "full": "In-meeting assistant that summarizes meetings, captures decisions, and remembers context across meetings using Amazon Bedrock AgentCore Memory."
  },
  "icons": { "color": "color.png", "outline": "outline.png" },
  "accentColor": "#FF9900",
  "configurableTabs": [
    {
      "configurationUrl": "https://$APP_FQDN/config.html",
      "scopes": ["groupChat"],
      "context": ["meetingSidePanel", "meetingChatTab", "meetingDetailsTab"],
      "canUpdateConfiguration": true
    }
  ],
  "webApplicationInfo": {
    "id": "$MEETING_APP_ID",
    "resource": "api://$APP_FQDN/$MEETING_APP_ID"
  },
  "permissions": ["identity"],
  "validDomains": ["$APP_FQDN"]
}
EOF

( cd "$PKG_DIR" && zip -r ../appPackage.zip manifest.json color.png outline.png >/dev/null )
echo "  Package: $APP_DIR/appPackage.zip (manifest id: $MANIFEST_ID)"

# Persist
grep -v -E '^(MEETING_APP_FQDN|MEETING_TEAMS_APP_ID)=' "$ENV_FILE" > "$ENV_FILE.tmp" 2>/dev/null && mv "$ENV_FILE.tmp" "$ENV_FILE" || true
cat >> "$ENV_FILE" <<EOF
MEETING_APP_FQDN=$APP_FQDN
MEETING_TEAMS_APP_ID=$MANIFEST_ID
EOF

echo ""
echo "============================================================"
echo "  AZURE MEETING DEPLOYMENT COMPLETE"
echo "============================================================"
echo "App FQDN:    https://$APP_FQDN"
echo "App package: $APP_DIR/appPackage.zip"
echo ""
echo ">>> Upload appPackage.zip via Teams (Apps -> Manage your apps -> Upload"
echo "    a custom app), then add it to a meeting via the meeting's + (Add app)."
echo "    Requires: meeting transcription ON, and you are the organizer for transcripts."
