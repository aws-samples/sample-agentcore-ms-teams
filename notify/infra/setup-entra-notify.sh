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
# Setup Entra App Registration for the Notify Bot
#
# Creates AgentCore-Notify-Bot with APPLICATION permissions needed to:
#   - install the bot app for any user/team (proactive install)
#   - resolve users/teams/channels
#   - send activity notifications (optional future use)
#
# Application Graph permissions (admin consent required - you are tenant admin):
#   TeamsAppInstallation.ReadWriteForUser.All  (install for any user)
#   TeamsAppInstallation.ReadWriteForTeam.All  (install in any team)
#   AppCatalog.Read.All                        (look up catalog app id)
#   Group.Read.All                             (resolve teams)
#   Team.ReadBasic.All                         (read teams)
#   Channel.ReadBasic.All                      (resolve channels)
#   TeamsActivity.Send                         (activity feed - optional)
#
# Usage: ./setup-entra-notify.sh [--tenant-id ID] [--new-secret]
# =============================================================================

APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-AgentCore-Notify-Bot}"
TENANT_ID="${TENANT_ID:-}"
NEW_SECRET=false
GRAPH_API_ID="00000003-0000-0000-c000-000000000000"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant-id) TENANT_ID="$2"; shift 2;;
    --new-secret) NEW_SECRET=true; shift;;
    --name) APP_DISPLAY_NAME="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

TENANT_ID="${TENANT_ID:-$(az account show --query tenantId -o tsv)}"
ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
echo "Tenant: $TENANT_ID"
echo "App:    $APP_DISPLAY_NAME"
echo ""

# ---------------------------------------------------------------------------
# 1. Create or reuse the app registration
# ---------------------------------------------------------------------------
echo "=== 1. App Registration ==="
EXISTING=$(az ad app list --display-name "$APP_DISPLAY_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)
if [[ -n "$EXISTING" && "$EXISTING" != "None" ]]; then
  APP_ID="$EXISTING"
  OBJ_ID=$(az ad app show --id "$APP_ID" --query "id" -o tsv)
  echo "  Reusing app: $APP_ID"
else
  APP=$(az ad app create --display-name "$APP_DISPLAY_NAME" --sign-in-audience "AzureADMyOrg" \
    --query "{appId:appId, id:id}" -o json)
  APP_ID=$(echo "$APP" | jq -r '.appId')
  OBJ_ID=$(echo "$APP" | jq -r '.id')
  echo "  Created app: $APP_ID"
fi

az ad sp create --id "$APP_ID" -o none 2>/dev/null || true
SP_ID=$(az ad sp show --id "$APP_ID" --query "id" -o tsv)
GRAPH_SP_ID=$(az ad sp show --id "$GRAPH_API_ID" --query "id" -o tsv)

# Expose an identifier URI + v2 tokens so callers can request an app token whose
# audience the AgentCore runtime customJWTAuthorizer accepts (api://botid-<appId>).
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$OBJ_ID" \
  --headers "Content-Type=application/json" \
  --body "{\"identifierUris\":[\"api://botid-$APP_ID\"],\"api\":{\"requestedAccessTokenVersion\":2}}" -o none
echo "  Identifier URI: api://botid-$APP_ID"

# ---------------------------------------------------------------------------
# 2. Add application permissions + grant admin consent
# ---------------------------------------------------------------------------
echo ""
echo "=== 2. Application Graph permissions ==="

PERM_VALUES=(
  "TeamsAppInstallation.ReadWriteForUser.All"
  "TeamsAppInstallation.ReadWriteForTeam.All"
  "AppCatalog.Read.All"
  "User.Read.All"
  "Group.Read.All"
  "Team.ReadBasic.All"
  "Channel.ReadBasic.All"
  "TeamsActivity.Send"
)

PERM_IDS=()
RESOURCE_ACCESS=""
for value in "${PERM_VALUES[@]}"; do
  id=$(az ad sp show --id "$GRAPH_API_ID" --query "appRoles[?value=='$value'].id | [0]" -o tsv)
  if [[ -n "$id" && "$id" != "None" ]]; then
    PERM_IDS+=("$id")
    RESOURCE_ACCESS+="{\"id\":\"$id\",\"type\":\"Role\"},"
  else
    echo "  WARN: permission $value not found"
  fi
done
RESOURCE_ACCESS="${RESOURCE_ACCESS%,}"

az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$OBJ_ID" \
  --headers "Content-Type=application/json" \
  --body "{\"requiredResourceAccess\":[{\"resourceAppId\":\"$GRAPH_API_ID\",\"resourceAccess\":[$RESOURCE_ACCESS]}]}" -o none
echo "  Declared ${#PERM_IDS[@]} application permissions"

# Grant admin consent (direct app role assignments)
for id in "${PERM_IDS[@]}"; do
  az rest --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/appRoleAssignments" \
    --headers "Content-Type=application/json" \
    --body "{\"principalId\":\"$SP_ID\",\"resourceId\":\"$GRAPH_SP_ID\",\"appRoleId\":\"$id\"}" \
    -o none 2>/dev/null || true
done
echo "  Admin consent granted"

# ---------------------------------------------------------------------------
# 3. Client secret
# ---------------------------------------------------------------------------
echo ""
echo "=== 3. Client secret ==="
EXISTING_SECRET=""
[[ -f "$ENV_FILE" ]] && EXISTING_SECRET=$(grep -E '^NOTIFY_BOT_APP_SECRET=' "$ENV_FILE" | cut -d= -f2- || true)

if [[ "$NEW_SECRET" == "true" || -z "$EXISTING_SECRET" ]]; then
  SECRET=$(az ad app credential reset --id "$OBJ_ID" --display-name "notify-bot-secret" --years 1 --query password -o tsv)
  echo "  New secret created"
else
  SECRET="$EXISTING_SECRET"
  echo "  Reusing existing secret from .env"
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
NOTIFY_SECRET_VAL=$(openssl rand -hex 32)
[[ -f "$ENV_FILE" ]] && NOTIFY_SECRET_VAL=$(grep -E '^NOTIFY_SECRET=' "$ENV_FILE" | cut -d= -f2- || echo "$NOTIFY_SECRET_VAL")

cat > "$ENV_FILE" <<EOF
# Notify Bot Configuration
TENANT_ID=$TENANT_ID
NOTIFY_BOT_APP_ID=$APP_ID
NOTIFY_BOT_APP_SECRET=$SECRET
NOTIFY_SECRET=$NOTIFY_SECRET_VAL
# TEAMS_APP_EXTERNAL_ID is set after the Teams app package is created (manifest id)
TEAMS_APP_EXTERNAL_ID=${TEAMS_APP_EXTERNAL_ID:-}
EOF

echo ""
echo "============================================================"
echo "  ENTRA NOTIFY SETUP COMPLETE"
echo "============================================================"
echo "App ID:     $APP_ID"
echo "Tenant:     $TENANT_ID"
echo "Saved to:   $ENV_FILE"
echo ""
echo "Next: ./deploy-azure-notify.sh"
