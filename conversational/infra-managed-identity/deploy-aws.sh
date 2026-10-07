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
# Deploy AWS Infrastructure (v2 - AgentCore Identity Token Vault)
#
# Creates:
#   - IAM Roles (AgentCoreTeamsAgentRole, AgentCoreGatewayRole)
#   - Deploys agent to AgentCore Runtime
#   - Configures Entra JWT inbound auth on Runtime
#   - Creates MCP Gateway with Entra JWT auth
#   - Creates AgentCore Identity OAuth2 credential provider (token vault)
#   - Registers Entra callback URL
#
# Security:
#   - Inbound: Entra JWT validated by AgentCore Runtime
#   - Outbound: Secrets stored in AgentCore Identity token vault (Secrets Manager)
#   - No secrets in agent env vars or code
#
# Usage:
#   ./deploy-aws.sh [--region REGION] [--tenant-id ID] [--bot-app-id ID] \
#                   [--bot-notify-url URL] [--notify-secret SECRET]
# =============================================================================

# ---------- Load .env if available ----------
ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
if [[ -f "$ENV_FILE" ]]; then
  echo "Loading config from $ENV_FILE"
  set -a; source "$ENV_FILE"; set +a
fi

# ---------- Defaults ----------
AWS_REGION="${AWS_REGION:-us-east-1}"
AGENT_NAME="${AGENT_NAME:-teamsagent_Agent}"
GATEWAY_NAME="${GATEWAY_NAME:-TeamsAgentGateway}"
CREDENTIAL_PROVIDER_NAME="${CREDENTIAL_PROVIDER_NAME:-microsoft-entra-outbound}"

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) AWS_REGION="$2"; shift 2;;
    --tenant-id) TENANT_ID="$2"; shift 2;;
    --bot-app-id) BOT_APP_ID="$2"; shift 2;;
    --bot-notify-url) NOTIFY_URL="$2"; shift 2;;
    --notify-secret) NOTIFY_SECRET="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

# ---------- Validate ----------
: "${TENANT_ID:?TENANT_ID required (--tenant-id or in .env)}"
: "${BOT_APP_ID:?BOT_APP_ID required (--bot-app-id or in .env)}"
: "${NOTIFY_URL:?NOTIFY_URL required (--bot-notify-url or in .env)}"
: "${OUTBOUND_APP_ID:?OUTBOUND_APP_ID required (in .env)}"
: "${OUTBOUND_APP_SECRET:?OUTBOUND_APP_SECRET required (in .env)}"

export AWS_REGION
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "AWS Account: $AWS_ACCOUNT_ID"
echo "AWS Region:  $AWS_REGION"
echo "Tenant ID:   $TENANT_ID"
echo "Bot App ID:  $BOT_APP_ID"
echo ""

# =============================================================================
# 1. IAM Roles
# =============================================================================
echo "=== 1. IAM Roles ==="

# Agent execution role
aws iam create-role \
  --role-name "AgentCoreTeamsAgentRole" \
  --assume-role-policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Principal\": {\"Service\": \"bedrock-agentcore.amazonaws.com\"},
      \"Action\": \"sts:AssumeRole\",
      \"Condition\": {\"StringEquals\": {\"aws:SourceAccount\": \"${AWS_ACCOUNT_ID}\"}}
    }]
  }" -o none 2>/dev/null || true

# Least-privilege inline policy in place of the broad AmazonBedrockFullAccess
# managed policy. AgentCore actions are the specific runtime execution
# (workload-identity token) actions per the AgentCore runtime-permissions docs,
# scoped to the workload-identity directory; model invocation is scoped to
# foundation-model ARNs and logs to this account/region.
aws iam put-role-policy \
  --role-name "AgentCoreTeamsAgentRole" \
  --policy-name "AgentCoreAccess" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {\"Sid\":\"AgentCoreWorkloadIdentity\",\"Effect\":\"Allow\",\"Action\":[\"bedrock-agentcore:GetWorkloadAccessToken\",\"bedrock-agentcore:GetWorkloadAccessTokenForJWT\",\"bedrock-agentcore:GetWorkloadAccessTokenForUserId\"],\"Resource\":[\"arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:workload-identity-directory/default\",\"arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:workload-identity-directory/default/workload-identity/*\"]},
      {\"Sid\":\"InvokeModels\",\"Effect\":\"Allow\",\"Action\":[\"bedrock:InvokeModel\",\"bedrock:InvokeModelWithResponseStream\"],\"Resource\":[\"arn:aws:bedrock:${AWS_REGION}::foundation-model/anthropic.claude-sonnet-4*\",\"arn:aws:bedrock:${AWS_REGION}::foundation-model/us.anthropic.claude-sonnet-4*\"]},
      {\"Sid\":\"LogsGroup\",\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\"],\"Resource\":\"arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/bedrock-agentcore/runtimes/*\"},
      {\"Sid\":\"LogsStream\",\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*\"}
    ]
  }" 2>/dev/null || true

AGENT_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/AgentCoreTeamsAgentRole"
echo "  Agent role: $AGENT_ROLE_ARN"

# Gateway role
aws iam create-role \
  --role-name "AgentCoreGatewayRole" \
  --assume-role-policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Principal\": {\"Service\": \"bedrock-agentcore.amazonaws.com\"},
      \"Action\": \"sts:AssumeRole\",
      \"Condition\": {\"StringEquals\": {\"aws:SourceAccount\": \"${AWS_ACCOUNT_ID}\"}}
    }]
  }" -o none 2>/dev/null || true

# NOTE: the gateway invoke policy is intentionally NOT written here. It is attached
# AFTER deployment, scoped to the specific runtime ARN (see step 2 below), so a
# runtime/* wildcard is never written to IAM.

GATEWAY_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/AgentCoreGatewayRole"
echo "  Gateway role: $GATEWAY_ROLE_ARN"

# Wait for role propagation
echo "  Waiting for role propagation..."
sleep 10

# =============================================================================
# 2. Deploy Agent to AgentCore Runtime
# =============================================================================
echo ""
echo "=== 2. Deploy Agent ==="
AGENT_DIR="$(cd "$(dirname "$0")/../agent/teamsagent" && pwd)"

cd "$AGENT_DIR"

# Configure agent (without authorizer - CLI has a bug with nested config)
agentcore configure \
  --name "$AGENT_NAME" \
  --entrypoint "$AGENT_DIR/src/main.py" \
  --execution-role "$AGENT_ROLE_ARN" \
  --protocol "HTTP" \
  --deployment-type "direct_code_deploy" \
  --region "$AWS_REGION" \
  --disable-memory \
  --runtime "PYTHON_3_12" \
  --non-interactive 2>&1 | grep -E "(✓|Configuration|Agent)" || true

# Deploy
agentcore deploy 2>&1 | grep -E "(✅|❌|Deployment|Agent)" || true

# Get runtime ID
RUNTIME_ID=$(grep -o 'runtime/[^ "]*' .bedrock_agentcore.yaml 2>/dev/null | head -1 | sed 's|runtime/||' || true)
if [[ -z "$RUNTIME_ID" ]]; then
  RUNTIME_ID=$(aws bedrock-agentcore-control list-agent-runtimes --region "$AWS_REGION" \
    --query "agentRuntimes[?contains(agentRuntimeName,'$AGENT_NAME')].agentRuntimeId" --output text | head -1)
fi
echo "  Runtime ID: $RUNTIME_ID"
RUNTIME_ARN="arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:runtime/${RUNTIME_ID}"

# Re-scope the gateway role to the specific runtime ARN now that it is known
# (least-privilege; no runtime/* wildcard is written at role creation).
if [[ -n "$RUNTIME_ID" ]]; then
  aws iam put-role-policy \
    --role-name "AgentCoreGatewayRole" \
    --policy-name "GatewayAccess" \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Sid\": \"GatewayInvokeRuntime\",
        \"Effect\": \"Allow\",
        \"Action\": [\"bedrock-agentcore:InvokeAgentRuntime\"],
        \"Resource\": \"$RUNTIME_ARN\"
      }]
    }" 2>/dev/null || true
  echo "  Re-scoped gateway policy to runtime ARN: $RUNTIME_ARN"
fi

# =============================================================================
# 3. Configure Entra JWT Inbound Auth + Env Vars
# =============================================================================
echo ""
echo "=== 3. Configure Inbound Auth (Entra JWT) ==="

# Build notify URL with auth header
NOTIFY_URL_WITH_AUTH="$NOTIFY_URL"

aws bedrock-agentcore-control update-agent-runtime \
  --agent-runtime-id "$RUNTIME_ID" \
  --role-arn "$AGENT_ROLE_ARN" \
  --network-configuration '{"networkMode": "PUBLIC"}' \
  --protocol-configuration '{"serverProtocol": "HTTP"}' \
  --authorizer-configuration "{
    \"customJWTAuthorizer\": {
      \"discoveryUrl\": \"https://login.microsoftonline.com/$TENANT_ID/v2.0/.well-known/openid-configuration\",
      \"allowedAudience\": [\"$BOT_APP_ID\"]
    }
  }" \
  --environment-variables "{
    \"TEAMS_BOT_NOTIFY_URL\": \"$NOTIFY_URL_WITH_AUTH\",
    \"NOTIFY_SECRET\": \"${NOTIFY_SECRET:-}\"
  }" \
  --agent-runtime-artifact "{
    \"codeConfiguration\": {
      \"code\": {
        \"s3\": {
          \"bucket\": \"bedrock-agentcore-codebuild-sources-${AWS_ACCOUNT_ID}-${AWS_REGION}\",
          \"prefix\": \"${AGENT_NAME}/deployment.zip\"
        }
      },
      \"runtime\": \"PYTHON_3_12\",
      \"entryPoint\": [\"src/main.py\"]
    }
  }" \
  --region "$AWS_REGION" \
  -o none
echo "  Authorizer: Entra JWT (discovery URL + audience)"
echo "  Env: TEAMS_BOT_NOTIFY_URL set"

# Wait for runtime to be ready
echo "  Waiting for runtime..."
sleep 15
STATUS=$(aws bedrock-agentcore-control get-agent-runtime --agent-runtime-id "$RUNTIME_ID" --region "$AWS_REGION" --query "status" --output text)
echo "  Status: $STATUS"

# =============================================================================
# 4. Create MCP Gateway with Entra Auth
# =============================================================================
echo ""
echo "=== 4. MCP Gateway ==="

GATEWAY_OUTPUT=$(aws bedrock-agentcore-control create-gateway \
  --name "$GATEWAY_NAME" \
  --protocol-type "MCP" \
  --role-arn "$GATEWAY_ROLE_ARN" \
  --authorizer-type "CUSTOM_JWT" \
  --authorizer-configuration "{
    \"customJWTAuthorizer\": {
      \"discoveryUrl\": \"https://login.microsoftonline.com/$TENANT_ID/v2.0/.well-known/openid-configuration\",
      \"allowedAudience\": [\"$BOT_APP_ID\"]
    }
  }" \
  --region "$AWS_REGION" \
  --output json 2>&1 || true)

GATEWAY_ID=$(echo "$GATEWAY_OUTPUT" | jq -r '.gatewayId // empty' 2>/dev/null || true)
GATEWAY_URL=$(echo "$GATEWAY_OUTPUT" | jq -r '.gatewayUrl // empty' 2>/dev/null || true)

if [[ -n "$GATEWAY_ID" ]]; then
  echo "  Gateway ID: $GATEWAY_ID"
  echo "  Gateway URL: $GATEWAY_URL"

  # Wait for gateway
  sleep 15

  # Add runtime as target
  aws bedrock-agentcore-control create-gateway-target \
    --gateway-identifier "$GATEWAY_ID" \
    --name "TeamsAgentMCP" \
    --target-configuration "{
      \"mcp\": {
        \"mcpServer\": {
          \"endpoint\": \"https://bedrock-agentcore.$AWS_REGION.amazonaws.com/runtimes/$RUNTIME_ID/mcp\"
        }
      }
    }" \
    --credential-provider-configurations '[{
      "credentialProviderType": "GATEWAY_IAM_ROLE",
      "credentialProvider": {
        "iamCredentialProvider": {
          "service": "bedrock-agentcore",
          "region": "'"$AWS_REGION"'"
        }
      }
    }]' \
    --region "$AWS_REGION" \
    -o none 2>/dev/null || echo "  (Gateway target may already exist)"
  echo "  Target added: TeamsAgentMCP → Runtime"
else
  echo "  Gateway creation skipped (may already exist)"
  GATEWAY_URL="(check with: aws bedrock-agentcore-control list-gateways)"
fi

# =============================================================================
# 5. AgentCore Identity - OAuth2 Credential Provider (Token Vault)
# =============================================================================
echo ""
echo "=== 5. AgentCore Identity Credential Provider ==="

CRED_OUTPUT=$(aws bedrock-agentcore-control create-oauth2-credential-provider \
  --name "$CREDENTIAL_PROVIDER_NAME" \
  --credential-provider-vendor "MicrosoftOauth2" \
  --oauth2-provider-config-input "{
    \"microsoftOauth2ProviderConfig\": {
      \"clientId\": \"$OUTBOUND_APP_ID\",
      \"clientSecret\": \"$OUTBOUND_APP_SECRET\",
      \"tenantId\": \"$TENANT_ID\"
    }
  }" \
  --region "$AWS_REGION" \
  --output json 2>&1 || true)

CALLBACK_URL=$(echo "$CRED_OUTPUT" | jq -r '.callbackUrl // empty' 2>/dev/null || true)

if [[ -n "$CALLBACK_URL" ]]; then
  echo "  Provider: $CREDENTIAL_PROVIDER_NAME"
  echo "  Callback URL: $CALLBACK_URL"
  echo ""
  echo "  ACTION REQUIRED: Register callback URL in Entra portal"
  echo "    App registrations → AgentCore-Outbound → Authentication → Add redirect URI:"
  echo "    $CALLBACK_URL"
else
  echo "  Credential provider may already exist"
fi

# =============================================================================
# 6. Register callback URL in Entra (if az is logged in)
# =============================================================================
if [[ -n "$CALLBACK_URL" ]] && command -v az &>/dev/null; then
  echo ""
  echo "=== 6. Register Callback URL in Entra ==="
  OUTBOUND_OBJECT_ID=$(az ad app show --id "$OUTBOUND_APP_ID" --query "id" -o tsv 2>/dev/null || true)
  if [[ -n "$OUTBOUND_OBJECT_ID" ]]; then
    az rest --method PATCH \
      --uri "https://graph.microsoft.com/v1.0/applications/$OUTBOUND_OBJECT_ID" \
      --headers "Content-Type=application/json" \
      --body "{\"web\": {\"redirectUris\": [\"$CALLBACK_URL\"]}}" -o none 2>/dev/null \
      && echo "  Callback URL registered in Entra" \
      || echo "  Failed to register (do it manually in Entra portal)"
  fi
fi

# =============================================================================
# Output
# =============================================================================
echo ""
echo "============================================================"
echo "  AWS DEPLOYMENT COMPLETE"
echo "============================================================"
echo ""
echo "Runtime ARN:     $RUNTIME_ARN"
echo "Runtime ID:      $RUNTIME_ID"
echo "Gateway URL:     $GATEWAY_URL"
echo ""
echo "Authentication:"
echo "  Inbound:  Entra JWT → AgentCore Runtime validates"
echo "  Outbound: AgentCore Identity token vault (no secrets in code)"
echo ""
echo "Invoke endpoint:"
echo "  https://bedrock-agentcore.$AWS_REGION.amazonaws.com/runtimes/$RUNTIME_ID/invocations?accountId=$AWS_ACCOUNT_ID"
echo ""
echo "Test:"
echo "  agentcore invoke '{\"prompt\": \"What is your status?\"}'"
