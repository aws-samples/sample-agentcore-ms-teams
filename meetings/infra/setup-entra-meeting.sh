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
# Setup Entra App Registration for the Meeting Assistant
#
# One app (AgentCore-Meeting-App) that:
#   - exposes api://botid-<appId>/access_as_user for Teams SSO (side panel)
#   - is the OBO confidential client (server exchanges SSO token -> Graph token)
#   - is the audience the AgentCore runtime authorizer accepts
#
# Delegated Graph permissions: User.Read, OnlineMeetings.Read,
#   OnlineMeetingTranscript.Read.All  (+ admin consent)
#
# Usage: ./setup-entra-meeting.sh [--tenant-id ID] [--app-fqdn FQDN] [--new-secret]
# =============================================================================

APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-AgentCore-Meeting-App}"
TENANT_ID="${TENANT_ID:-}"
APP_FQDN="${APP_FQDN:-}"
NEW_SECRET=false
GRAPH_API_ID="00000003-0000-0000-c000-000000000000"
TEAMS_DESKTOP="1fec8e78-bce4-4aaf-ab1b-5451cc387264"
TEAMS_WEB="5e3ce6c0-2b1f-4285-8d4b-75ee78787346"
OFFICE_1="d3590ed6-52b3-4102-aeff-aad2292ab01c"
OFFICE_2="4765445b-32c6-49b0-83e6-1d93765276ca"
OFFICE_3="0ec893e0-5785-4de6-99da-4ed124e5296c"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant-id) TENANT_ID="$2"; shift 2;;
    --app-fqdn) APP_FQDN="$2"; shift 2;;
    --new-secret) NEW_SECRET=true; shift;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

TENANT_ID="${TENANT_ID:-$(az account show --query tenantId -o tsv)}"
ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
echo "Tenant: $TENANT_ID | App: $APP_DISPLAY_NAME"
echo ""

# 1. Create/reuse app
echo "=== 1. App Registration ==="
EXISTING=$(az ad app list --display-name "$APP_DISPLAY_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)
if [[ -n "$EXISTING" && "$EXISTING" != "None" ]]; then
  APP_ID="$EXISTING"
  echo "  Reusing app: $APP_ID"
else
  APP_ID=$(az ad app create --display-name "$APP_DISPLAY_NAME" --sign-in-audience "AzureADMyOrg" --query "appId" -o tsv)
  echo "  Created app: $APP_ID"
fi
OBJ_ID=$(az ad app show --id "$APP_ID" --query "id" -o tsv)
az ad sp create --id "$APP_ID" -o none 2>/dev/null || true
SP_ID=$(az ad sp show --id "$APP_ID" --query "id" -o tsv)
GRAPH_SP_ID=$(az ad sp show --id "$GRAPH_API_ID" --query "id" -o tsv)

# 2. Expose SSO scope (access_as_user) + identifier URI + v2 tokens
echo ""
echo "=== 2. Expose SSO scope ==="
SCOPE_ID=$(az ad app show --id "$APP_ID" --query "api.oauth2PermissionScopes[?value=='access_as_user'].id | [0]" -o tsv 2>/dev/null || true)
[[ -z "$SCOPE_ID" || "$SCOPE_ID" == "None" ]] && SCOPE_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')

az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$OBJ_ID" \
  --headers "Content-Type=application/json" \
  --body "{
    \"identifierUris\": [\"api://botid-$APP_ID\"],
    \"api\": {
      \"requestedAccessTokenVersion\": 2,
      \"oauth2PermissionScopes\": [{
        \"id\": \"$SCOPE_ID\",
        \"adminConsentDisplayName\": \"Access as user\",
        \"adminConsentDescription\": \"Access the meeting assistant as the signed-in user\",
        \"userConsentDisplayName\": \"Access as you\",
        \"userConsentDescription\": \"Allow the meeting assistant to act on your behalf\",
        \"isEnabled\": true, \"type\": \"User\", \"value\": \"access_as_user\"
      }]
    }
  }" -o none
echo "  Scope: api://botid-$APP_ID/access_as_user"

# 3. Pre-authorize Teams/Office clients (silent SSO)
echo ""
echo "=== 3. Pre-authorize Teams/Office ==="
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$OBJ_ID" \
  --headers "Content-Type=application/json" \
  --body "{\"api\":{\"preAuthorizedApplications\":[
    {\"appId\":\"$TEAMS_DESKTOP\",\"delegatedPermissionIds\":[\"$SCOPE_ID\"]},
    {\"appId\":\"$TEAMS_WEB\",\"delegatedPermissionIds\":[\"$SCOPE_ID\"]},
    {\"appId\":\"$OFFICE_1\",\"delegatedPermissionIds\":[\"$SCOPE_ID\"]},
    {\"appId\":\"$OFFICE_2\",\"delegatedPermissionIds\":[\"$SCOPE_ID\"]},
    {\"appId\":\"$OFFICE_3\",\"delegatedPermissionIds\":[\"$SCOPE_ID\"]}
  ]}}" -o none
echo "  Pre-authorized Teams desktop/web + Office"

# 4. Delegated Graph permissions + admin consent
echo ""
echo "=== 4. Delegated Graph permissions ==="
USER_READ=$(az ad sp show --id "$GRAPH_API_ID" --query "oauth2PermissionScopes[?value=='User.Read'].id | [0]" -o tsv)
OM_READ=$(az ad sp show --id "$GRAPH_API_ID" --query "oauth2PermissionScopes[?value=='OnlineMeetings.Read'].id | [0]" -o tsv)
OMT_READ=$(az ad sp show --id "$GRAPH_API_ID" --query "oauth2PermissionScopes[?value=='OnlineMeetingTranscript.Read.All'].id | [0]" -o tsv)

az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$OBJ_ID" \
  --headers "Content-Type=application/json" \
  --body "{\"requiredResourceAccess\":[{\"resourceAppId\":\"$GRAPH_API_ID\",\"resourceAccess\":[
    {\"id\":\"$USER_READ\",\"type\":\"Scope\"},
    {\"id\":\"$OM_READ\",\"type\":\"Scope\"},
    {\"id\":\"$OMT_READ\",\"type\":\"Scope\"}
  ]}]}" -o none

# Admin consent for delegated scopes
az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" \
  --headers "Content-Type=application/json" \
  --body "{\"clientId\":\"$SP_ID\",\"consentType\":\"AllPrincipals\",\"resourceId\":\"$GRAPH_SP_ID\",\"scope\":\"User.Read OnlineMeetings.Read OnlineMeetingTranscript.Read.All openid profile offline_access\"}" \
  -o none 2>/dev/null || echo "  (consent grant may already exist)"
echo "  Delegated: User.Read, OnlineMeetings.Read, OnlineMeetingTranscript.Read.All + consent"

# 5. SPA redirect for auth-end (if FQDN known)
if [[ -n "$APP_FQDN" ]]; then
  az rest --method PATCH \
    --uri "https://graph.microsoft.com/v1.0/applications/$OBJ_ID" \
    --headers "Content-Type=application/json" \
    --body "{\"spa\":{\"redirectUris\":[\"https://$APP_FQDN/auth-end.html\"]}}" -o none
  echo "  SPA redirect: https://$APP_FQDN/auth-end.html"
fi

# 6. Secret
echo ""
echo "=== 5. Client secret ==="
EXISTING_SECRET=""
[[ -f "$ENV_FILE" ]] && EXISTING_SECRET=$(grep -E '^MEETING_APP_SECRET=' "$ENV_FILE" | cut -d= -f2- || true)
if [[ "$NEW_SECRET" == "true" || -z "$EXISTING_SECRET" ]]; then
  SECRET=$(az ad app credential reset --id "$OBJ_ID" --display-name "meeting-app-secret" --years 1 --query password -o tsv)
  echo "  New secret created"
else
  SECRET="$EXISTING_SECRET"
  echo "  Reusing existing secret"
fi

cat > "$ENV_FILE" <<EOF
# Meeting Assistant Configuration
TENANT_ID=$TENANT_ID
MEETING_APP_ID=$APP_ID
MEETING_APP_SECRET=$SECRET
MEETING_APP_FQDN=${APP_FQDN:-}
EOF

echo ""
echo "============================================================"
echo "  ENTRA MEETING SETUP COMPLETE"
echo "============================================================"
echo "App ID:   $APP_ID"
echo "Saved to: $ENV_FILE"
echo "Next: ./deploy-aws-meeting.sh then ./deploy-azure-meeting.sh"
