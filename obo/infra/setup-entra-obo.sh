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
# Setup Entra App Registration for the OBO (On-Behalf-Of) Flow  [WORKING ARCH]
#
# Creates / updates the ONE app registration the working demo needs:
#
#   AgentCore-Teams-Bot-OBO  — the Teams bot app. It plays THREE roles:
#     1. Bot Framework identity (validates inbound Bot Connector tokens)
#     2. SSO resource for Teams (exposes api://botid-<appId>/access_as_user)
#     3. OBO confidential client — teams-ai exchanges the user's SSO token for a
#        Microsoft Graph token USING THIS APP'S OWN CLIENT SECRET. There is no
#        separate downstream app in the working flow.
#
# What this script configures on that app:
#   - signInAudience = AzureADMultipleOrgs  (REQUIRED: the Bot Framework OAuth
#     popup / token.botframework.com only works against a multi-tenant app)
#   - identifierUri  = api://botid-<appId>, v2 access tokens
#   - exposed scope  = access_as_user
#   - pre-authorized Teams + Office client IDs (silent SSO, no consent prompt)
#   - delegated Microsoft Graph perms: User.Read, Mail.Read, Calendars.Read
#     + admin consent
#     DATA PROTECTION NOTE: Mail.Read and Calendars.Read grant access to personal
#     email and calendar data (regulated under GDPR and similar frameworks). Under
#     the AWS shared responsibility model, customers deploying this sample are
#     responsible for meeting applicable data-protection requirements before
#     production use. https://aws.amazon.com/compliance/shared-responsibility-model/
#   - a client secret (used by the bot SDK AND by teams-ai for the OBO exchange)
#   - SPA redirect  https://<botFqdn>/auth-end.html  (implicit-flow popup fallback)
#   - web redirect  https://token.botframework.com/.auth/web/redirect
#
# The Managed Identity federated credential is added in deploy-azure-obo.sh
# (it needs the MI principalId, which is created there). You can also add it
# here later by re-running with --bot-fqdn / federated args already known.
#
# NOTE on the legacy "AgentCore-OBO-Downstream" app:
#   The FAILED "AgentCore OBO exchange" approach used a separate downstream app
#   + an AgentCore Identity credential provider. The WORKING approach does NOT
#   use it. This script no longer creates it. See ARCHITECTURE-OBO.md.
#
# Idempotent: re-running reuses the existing app if one with the same name
# already exists (it will NOT mint a new secret unless --new-secret is passed).
#
# Usage:
#   ./setup-entra-obo.sh [--tenant-id ID] [--bot-fqdn FQDN] [--new-secret]
# =============================================================================

# ---------- Defaults ----------
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-AgentCore-Teams-Bot-OBO}"
TENANT_ID="${TENANT_ID:-}"
BOT_FQDN="${BOT_FQDN:-}"          # e.g. agentcore-obo-bot.<env>.westus2.azurecontainerapps.io
NEW_SECRET=false

# Teams / Office first-party client IDs that get pre-authorized for silent SSO
TEAMS_DESKTOP="1fec8e78-bce4-4aaf-ab1b-5451cc387264"
TEAMS_WEB="5e3ce6c0-2b1f-4285-8d4b-75ee78787346"
OFFICE_1="d3590ed6-52b3-4102-aeff-aad2292ab01c"
OFFICE_2="4765445b-32c6-49b0-83e6-1d93765276ca"
OFFICE_3="0ec893e0-5785-4de6-99da-4ed124e5296c"

GRAPH_API_ID="00000003-0000-0000-c000-000000000000"
BOT_FRAMEWORK_REDIRECT="https://token.botframework.com/.auth/web/redirect"

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant-id) TENANT_ID="$2"; shift 2;;
    --bot-fqdn) BOT_FQDN="$2"; shift 2;;
    --new-secret) NEW_SECRET=true; shift;;
    --name) APP_DISPLAY_NAME="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

TENANT_ID="${TENANT_ID:-$(az account show --query tenantId -o tsv)}"
echo "Tenant: $TENANT_ID"
echo "App:    $APP_DISPLAY_NAME"
echo ""

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"

# =============================================================================
# 1. Create or reuse the bot app registration (MULTI-TENANT audience)
# =============================================================================
echo "=== 1. App Registration: $APP_DISPLAY_NAME ==="

EXISTING_APP_ID=$(az ad app list --display-name "$APP_DISPLAY_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING_APP_ID" && "$EXISTING_APP_ID" != "None" ]]; then
  BOT_APP_ID="$EXISTING_APP_ID"
  BOT_OBJECT_ID=$(az ad app show --id "$BOT_APP_ID" --query "id" -o tsv)
  echo "  Reusing existing app: $BOT_APP_ID"
  # Ensure audience is multi-tenant (CRITICAL — see header).
  az ad app update --id "$BOT_APP_ID" --sign-in-audience "AzureADMultipleOrgs" -o none
else
  BOT_APP=$(az ad app create \
    --display-name "$APP_DISPLAY_NAME" \
    --sign-in-audience "AzureADMultipleOrgs" \
    --query "{appId:appId, id:id}" \
    -o json)
  BOT_APP_ID=$(echo "$BOT_APP" | jq -r '.appId')
  BOT_OBJECT_ID=$(echo "$BOT_APP" | jq -r '.id')
  echo "  Created app: $BOT_APP_ID"
fi
echo "  signInAudience: AzureADMultipleOrgs (multi-tenant — required for Bot OAuth popup)"

# =============================================================================
# 2. Identifier URI, v2 tokens, expose access_as_user scope
# =============================================================================
echo ""
echo "=== 2. Expose API scope ==="

# Reuse existing scope id if present so pre-auth / consent stays stable.
SCOPE_ID=$(az ad app show --id "$BOT_APP_ID" \
  --query "api.oauth2PermissionScopes[?value=='access_as_user'].id | [0]" -o tsv 2>/dev/null || true)
[[ -z "$SCOPE_ID" || "$SCOPE_ID" == "None" ]] && SCOPE_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')

az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$BOT_OBJECT_ID" \
  --headers "Content-Type=application/json" \
  --body "{
    \"identifierUris\": [\"api://botid-$BOT_APP_ID\"],
    \"api\": {
      \"requestedAccessTokenVersion\": 2,
      \"oauth2PermissionScopes\": [{
        \"id\": \"$SCOPE_ID\",
        \"adminConsentDisplayName\": \"Access as user\",
        \"adminConsentDescription\": \"Access the AgentCore agent as the signed-in user\",
        \"userConsentDisplayName\": \"Access as you\",
        \"userConsentDescription\": \"Allow the app to access the AgentCore agent on your behalf\",
        \"isEnabled\": true,
        \"type\": \"User\",
        \"value\": \"access_as_user\"
      }]
    }
  }" -o none
echo "  identifierUri:  api://botid-$BOT_APP_ID"
echo "  exposed scope:  api://botid-$BOT_APP_ID/access_as_user"

# =============================================================================
# 3. Pre-authorize Teams + Office clients (silent SSO, no consent prompt)
# =============================================================================
echo ""
echo "=== 3. Pre-authorize Teams / Office clients ==="
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$BOT_OBJECT_ID" \
  --headers "Content-Type=application/json" \
  --body "{
    \"api\": {
      \"preAuthorizedApplications\": [
        {\"appId\": \"$TEAMS_DESKTOP\", \"delegatedPermissionIds\": [\"$SCOPE_ID\"]},
        {\"appId\": \"$TEAMS_WEB\",     \"delegatedPermissionIds\": [\"$SCOPE_ID\"]},
        {\"appId\": \"$OFFICE_1\",      \"delegatedPermissionIds\": [\"$SCOPE_ID\"]},
        {\"appId\": \"$OFFICE_2\",      \"delegatedPermissionIds\": [\"$SCOPE_ID\"]},
        {\"appId\": \"$OFFICE_3\",      \"delegatedPermissionIds\": [\"$SCOPE_ID\"]}
      ]
    }
  }" -o none
echo "  Pre-authorized: Teams desktop ($TEAMS_DESKTOP), Teams web ($TEAMS_WEB), Office clients"

# =============================================================================
# 4. Delegated Microsoft Graph permissions + admin consent
# =============================================================================
echo ""
echo "=== 4. Delegated Graph permissions ==="
USER_READ=$(az ad sp show --id "$GRAPH_API_ID" --query "oauth2PermissionScopes[?value=='User.Read'].id" -o tsv)
MAIL_READ=$(az ad sp show --id "$GRAPH_API_ID" --query "oauth2PermissionScopes[?value=='Mail.Read'].id" -o tsv)
CALENDARS_READ=$(az ad sp show --id "$GRAPH_API_ID" --query "oauth2PermissionScopes[?value=='Calendars.Read'].id" -o tsv)

az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$BOT_OBJECT_ID" \
  --headers "Content-Type=application/json" \
  --body "{
    \"requiredResourceAccess\": [{
      \"resourceAppId\": \"$GRAPH_API_ID\",
      \"resourceAccess\": [
        {\"id\": \"$USER_READ\",      \"type\": \"Scope\"},
        {\"id\": \"$MAIL_READ\",      \"type\": \"Scope\"},
        {\"id\": \"$CALENDARS_READ\", \"type\": \"Scope\"}
      ]
    }]
  }" -o none
echo "  Delegated: User.Read, Mail.Read, Calendars.Read"

# Service principal (required before admin consent / oauth2PermissionGrants)
az ad sp create --id "$BOT_APP_ID" -o none 2>/dev/null || true

# Admin consent (creates the oauth2PermissionGrants so the OBO exchange succeeds
# without a per-user consent prompt).
az ad app permission admin-consent --id "$BOT_APP_ID" 2>/dev/null \
  || echo "  NOTE: admin consent failed via CLI — grant it in the portal:"
echo "  Admin consent: requested for delegated Graph scopes"

# =============================================================================
# 5. Redirect URIs (SPA popup fallback + Bot Framework web redirect)
# =============================================================================
echo ""
echo "=== 5. Redirect URIs ==="
WEB_REDIRECTS_JSON="[\"$BOT_FRAMEWORK_REDIRECT\"]"
SPA_REDIRECTS_JSON="[]"
if [[ -n "$BOT_FQDN" ]]; then
  SPA_REDIRECTS_JSON="[\"https://$BOT_FQDN/auth-end.html\"]"
  echo "  SPA redirect:  https://$BOT_FQDN/auth-end.html"
else
  echo "  SPA redirect:  (skipped — pass --bot-fqdn or re-run after deploy-azure-obo.sh)"
fi
echo "  Web redirect:  $BOT_FRAMEWORK_REDIRECT"

az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$BOT_OBJECT_ID" \
  --headers "Content-Type=application/json" \
  --body "{
    \"web\": {\"redirectUris\": $WEB_REDIRECTS_JSON},
    \"spa\": {\"redirectUris\": $SPA_REDIRECTS_JSON}
  }" -o none

# =============================================================================
# 6. Client secret
# =============================================================================
echo ""
echo "=== 6. Client secret ==="
# Reuse the existing secret from .env unless --new-secret or none exists.
BOT_SECRET=""
if [[ -f "$ENV_FILE" ]]; then
  BOT_SECRET=$(grep -E '^OBO_BOT_APP_SECRET=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)
fi
if [[ "$NEW_SECRET" == "true" || -z "$BOT_SECRET" ]]; then
  BOT_SECRET=$(az ad app credential reset --id "$BOT_OBJECT_ID" \
    --display-name "bot-obo-secret" --years 1 --query password -o tsv)
  echo "  New client secret minted"
else
  echo "  Reusing existing client secret from .env (pass --new-secret to rotate)"
fi

# =============================================================================
# 7. Save to ../.env
# =============================================================================
echo ""
echo "=== 7. Save .env ==="
# Preserve any AWS / deploy values already present; rewrite the Entra block.
TMP=$(mktemp)
{
  echo "# OBO Demo Configuration (working architecture)"
  echo "TENANT_ID=$TENANT_ID"
  echo "OBO_BOT_APP_ID=$BOT_APP_ID"
  echo "OBO_BOT_APP_SECRET=$BOT_SECRET"
  echo "OBO_BOT_IDENTIFIER_URI=api://botid-$BOT_APP_ID"
  echo "OBO_BOT_SCOPE_ID=$SCOPE_ID"
  [[ -n "$BOT_FQDN" ]] && echo "BOT_DOMAIN=$BOT_FQDN"
  # Carry over previously-saved deploy values if present.
  if [[ -f "$ENV_FILE" ]]; then
    grep -E '^(BOT_DOMAIN|MI_CLIENT_ID|MI_PRINCIPAL_ID|AWS_REGION|AWS_ACCOUNT_ID|AGENTCORE_RUNTIME_ID)=' "$ENV_FILE" \
      | grep -v -E '^BOT_DOMAIN=' 2>/dev/null || true
    # keep BOT_DOMAIN only if we didn't just set it
    if [[ -z "$BOT_FQDN" ]]; then
      grep -E '^BOT_DOMAIN=' "$ENV_FILE" 2>/dev/null || true
    fi
  fi
} > "$TMP"
mv "$TMP" "$ENV_FILE"
echo "  Saved: $ENV_FILE"

# =============================================================================
# Output
# =============================================================================
echo ""
echo "============================================================"
echo "  ENTRA OBO SETUP COMPLETE"
echo "============================================================"
echo ""
echo "Tenant ID:       $TENANT_ID"
echo "Bot App ID:      $BOT_APP_ID"
echo "Identifier URI:  api://botid-$BOT_APP_ID"
echo "Scope:           access_as_user (id $SCOPE_ID)"
echo ""
echo "Next:"
echo "  1. ./deploy-azure-obo.sh   (MI, federated credential, bot, container, package)"
echo "  2. ./deploy-aws-obo.sh     (IAM role, agentcore deploy, JWT authorizer)"
echo ""
echo "If you skipped --bot-fqdn, re-run after deploy-azure-obo.sh prints the FQDN,"
echo "or deploy-azure-obo.sh will add the SPA redirect for you."
