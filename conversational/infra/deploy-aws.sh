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
# Deploy AWS Infrastructure for AgentCore + Microsoft Teams Integration
#
# Creates:
#   - IAM Roles (AgentCoreTeamsAgentRole, AgentCoreGatewayRole)
#   - Deploys agent to AgentCore Runtime
#   - Configures Entra JWT inbound auth on the Runtime
#   - Creates MCP Gateway with Entra JWT auth
#   - Sets TEAMS_BOT_NOTIFY_URL environment variable on the agent
#
# Prerequisites:
#   - AWS CLI v2 installed and configured
#   - bedrock-agentcore CLI installed (pip install bedrock-agentcore==1.0.3)
#   - Azure deployment completed (need BOT_APP_ID, TENANT_ID, BOT_NOTIFY_URL)
#   - Appropriate AWS permissions (IAM, Bedrock AgentCore)
#
# Usage:
#   ./deploy-aws.sh [--region REGION] [--tenant-id TENANT_ID] \
#                   [--bot-app-id BOT_APP_ID] [--bot-notify-url URL]
#
# =============================================================================

# ---------- Defaults ----------
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
AGENT_NAME="${AGENT_NAME:-teamsagent_Agent}"

# ---------- Parse CLI Args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) AWS_REGION="$2"; shift 2;;
    --tenant-id) TENANT_ID="$2"; shift 2;;
    --bot-app-id) BOT_APP_ID="$2"; shift 2;;
    --bot-notify-url) BOT_NOTIFY_URL="$2"; shift 2;;
    --agent-name) AGENT_NAME="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

# ---------- Load from .env if not provided ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

if [[ -f "$ENV_FILE" ]]; then
  echo "Loading defaults from .env..."
  set -a
  source "$ENV_FILE"
  set +a
fi

# ---------- Validate Required Params ----------
TENANT_ID="${TENANT_ID:?ERROR: TENANT_ID is required (--tenant-id or .env)}"
BOT_APP_ID="${BOT_APP_ID:?ERROR: BOT_APP_ID is required (--bot-app-id or .env)}"
BOT_NOTIFY_URL="${TEAMS_BOT_NOTIFY_URL:-${BOT_NOTIFY_URL:-}}"
BOT_NOTIFY_URL="${BOT_NOTIFY_URL:?ERROR: BOT_NOTIFY_URL is required (--bot-notify-url or TEAMS_BOT_NOTIFY_URL in .env)}"

DISCOVERY_URL="https://login.microsoftonline.com/$TENANT_ID/v2.0/.well-known/openid-configuration"
AUDIENCE="api://$BOT_APP_ID"

echo "============================================================"
echo " AgentCore + Teams - AWS Deployment"
echo "============================================================"
echo ""
echo "  AWS Account:      $AWS_ACCOUNT_ID"
echo "  Region:           $AWS_REGION"
echo "  Agent Name:       $AGENT_NAME"
echo "  Tenant ID:        $TENANT_ID"
echo "  Bot App ID:       $BOT_APP_ID"
echo "  Bot Notify URL:   $BOT_NOTIFY_URL"
echo "  Discovery URL:    $DISCOVERY_URL"
echo "  JWT Audience:     $AUDIENCE"
echo ""

# =============================================================================
# Step 1: Create IAM Roles
# =============================================================================
echo "--- Step 1: IAM Roles ---"

# --- AgentCoreTeamsAgentRole ---
AGENT_ROLE_NAME="AgentCoreTeamsAgentRole"
AGENT_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${AGENT_ROLE_NAME}"

AGENT_TRUST_POLICY=$(cat <<'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "bedrock-agentcore.amazonaws.com"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:SourceAccount": "AWS_ACCOUNT_ID_PLACEHOLDER"
        }
      }
    }
  ]
}
POLICY
)
AGENT_TRUST_POLICY="${AGENT_TRUST_POLICY//AWS_ACCOUNT_ID_PLACEHOLDER/$AWS_ACCOUNT_ID}"

if aws iam get-role --role-name "$AGENT_ROLE_NAME" &>/dev/null; then
  echo "  Role $AGENT_ROLE_NAME already exists"
else
  aws iam create-role \
    --role-name "$AGENT_ROLE_NAME" \
    --assume-role-policy-document "$AGENT_TRUST_POLICY" \
    --description "Execution role for AgentCore Teams agent" \
    --output text --query 'Role.Arn'
  echo "  Created: $AGENT_ROLE_NAME"
fi

# Attach Bedrock model access policy
AGENT_POLICY=$(cat <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BedrockModelAccess",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": [
        "arn:aws:bedrock:${AWS_REGION}::foundation-model/anthropic.claude-sonnet-4*",
        "arn:aws:bedrock:${AWS_REGION}::foundation-model/us.anthropic.claude-sonnet-4*"
      ]
    },
    {
      "Sid": "CloudWatchLogsGroup",
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup"],
      "Resource": "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/bedrock-agentcore/runtimes/*"
    },
    {
      "Sid": "CloudWatchLogsStream",
      "Effect": "Allow",
      "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*"
    }
  ]
}
POLICY
)

aws iam put-role-policy \
  --role-name "$AGENT_ROLE_NAME" \
  --policy-name "AgentCoreTeamsAgentPolicy" \
  --policy-document "$AGENT_POLICY" \
  --output text 2>/dev/null || true
echo "  Attached policy to $AGENT_ROLE_NAME"

# --- AgentCoreGatewayRole ---
GATEWAY_ROLE_NAME="AgentCoreGatewayRole"
GATEWAY_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${GATEWAY_ROLE_NAME}"

GATEWAY_TRUST_POLICY=$(cat <<'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "bedrock-agentcore.amazonaws.com"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:SourceAccount": "AWS_ACCOUNT_ID_PLACEHOLDER"
        }
      }
    }
  ]
}
POLICY
)
GATEWAY_TRUST_POLICY="${GATEWAY_TRUST_POLICY//AWS_ACCOUNT_ID_PLACEHOLDER/$AWS_ACCOUNT_ID}"

if aws iam get-role --role-name "$GATEWAY_ROLE_NAME" &>/dev/null; then
  echo "  Role $GATEWAY_ROLE_NAME already exists"
else
  aws iam create-role \
    --role-name "$GATEWAY_ROLE_NAME" \
    --assume-role-policy-document "$GATEWAY_TRUST_POLICY" \
    --description "Role for AgentCore MCP Gateway" \
    --output text --query 'Role.Arn'
  echo "  Created: $GATEWAY_ROLE_NAME"
fi

# NOTE: the gateway invoke policy is intentionally NOT written here. We attach it
# AFTER deployment, scoped to the specific runtime ARN (see Step 2), so a
# runtime/* wildcard is never written to IAM.

# Wait for IAM propagation
echo "  Waiting for IAM role propagation (10s)..."
sleep 10

# =============================================================================
# Step 2: Deploy Agent to AgentCore Runtime
# =============================================================================
echo ""
echo "--- Step 2: Deploy Agent to AgentCore Runtime ---"

AGENT_DIR="$PROJECT_ROOT/agent/teamsagent"

echo "  Deploying agent from: $AGENT_DIR"
echo "  Using bedrock-agentcore CLI..."

(cd "$AGENT_DIR" && bedrock-agentcore deploy \
  --agent-name "$AGENT_NAME" \
  --region "$AWS_REGION" \
  --execution-role "$AGENT_ROLE_ARN" \
  --env "TENANT_ID=$TENANT_ID" \
  --env "TEAMS_BOT_NOTIFY_URL=$BOT_NOTIFY_URL" \
  --env "OUTBOUND_APP_ID=${OUTBOUND_APP_ID:-}" \
  --env "OUTBOUND_APP_SECRET=${OUTBOUND_APP_SECRET:-}" \
  2>&1) || {
    echo "  WARNING: bedrock-agentcore deploy failed. You may need to deploy manually."
    echo "  Alternative: cd $AGENT_DIR && bedrock-agentcore deploy"
}

# Get agent ID (from .bedrock_agentcore.yaml or CLI output)
AGENT_CONFIG="$AGENT_DIR/.bedrock_agentcore.yaml"
if [[ -f "$AGENT_CONFIG" ]]; then
  RUNTIME_ID=$(grep "agent_id:" "$AGENT_CONFIG" | head -1 | awk '{print $2}')
  AGENT_ARN=$(grep "agent_arn:" "$AGENT_CONFIG" | head -1 | awk '{print $2}')
  echo "  Agent ID: $RUNTIME_ID"
  echo "  Agent ARN: $AGENT_ARN"

  # Attach the gateway invoke policy scoped to the specific runtime ARN (least
  # privilege). Fail fast if this cannot be applied, so the role is never left
  # without a scoped policy (and no wildcard was ever written).
  if [[ -n "$AGENT_ARN" ]]; then
    aws iam put-role-policy \
      --role-name "$GATEWAY_ROLE_NAME" \
      --policy-name "AgentCoreGatewayPolicy" \
      --policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [{
          \"Sid\": \"InvokeRuntime\",
          \"Effect\": \"Allow\",
          \"Action\": [\"bedrock-agentcore:InvokeAgentRuntime\"],
          \"Resource\": \"$AGENT_ARN\"
        }]
      }" --output text || {
        echo "  ERROR: failed to attach scoped gateway policy — aborting."; exit 1;
      }
    echo "  Attached gateway policy scoped to runtime ARN: $AGENT_ARN"
  else
    echo "  WARNING: runtime ARN unknown; gateway invoke policy NOT attached (no wildcard written)."
  fi
else
  echo "  WARNING: Could not find agent config. Set RUNTIME_ID manually."
  RUNTIME_ID=""
  AGENT_ARN=""
fi

# =============================================================================
# Step 3: Configure Entra JWT Inbound Auth on Runtime
# =============================================================================
echo ""
echo "--- Step 3: Configure JWT Inbound Auth ---"

if [[ -n "$RUNTIME_ID" ]]; then
  # Configure custom JWT authorizer using the AgentCore API
  echo "  Configuring customJWTAuthorizer on runtime: $RUNTIME_ID"

  aws bedrock-agentcore update-agent-runtime \
    --region "$AWS_REGION" \
    --agent-runtime-id "$RUNTIME_ID" \
    --authorizer-configuration '{
      "customJWTAuthorizer": {
        "discoveryUrl": "'"$DISCOVERY_URL"'",
        "allowedAudiences": ["'"$AUDIENCE"'"]
      }
    }' \
    --output text 2>/dev/null && echo "  JWT auth configured" || {
      echo "  WARNING: Could not configure JWT auth via CLI."
      echo "  Configure manually in the AgentCore console:"
      echo "    Discovery URL: $DISCOVERY_URL"
      echo "    Audience: $AUDIENCE"
    }
else
  echo "  SKIPPED: No RUNTIME_ID available. Configure JWT auth manually."
  echo "    Discovery URL: $DISCOVERY_URL"
  echo "    Audience: $AUDIENCE"
fi

# =============================================================================
# Step 4: Create MCP Gateway with Entra JWT Auth
# =============================================================================
echo ""
echo "--- Step 4: Create MCP Gateway ---"

GATEWAY_NAME="${AGENT_NAME}gateway"

GATEWAY_RESULT=$(aws bedrock-agentcore create-gateway \
  --region "$AWS_REGION" \
  --name "$GATEWAY_NAME" \
  --role-arn "$GATEWAY_ROLE_ARN" \
  --protocol-configuration '{
    "mcp": {}
  }' \
  --authorizer-configuration '{
    "customJWTAuthorizer": {
      "discoveryUrl": "'"$DISCOVERY_URL"'",
      "allowedAudiences": ["'"$AUDIENCE"'"]
    }
  }' \
  --output json 2>/dev/null) && {
    GATEWAY_ID=$(echo "$GATEWAY_RESULT" | jq -r '.gatewayId // .id // empty')
    echo "  Created Gateway: $GATEWAY_ID"
} || {
    echo "  Gateway may already exist or creation failed."
    echo "  Attempting to find existing gateway..."
    GATEWAY_ID=$(aws bedrock-agentcore list-gateways \
      --region "$AWS_REGION" \
      --output json 2>/dev/null | jq -r ".gateways[] | select(.name==\"$GATEWAY_NAME\") | .gatewayId // .id" 2>/dev/null || echo "")

    if [[ -n "$GATEWAY_ID" ]]; then
      echo "  Found existing Gateway: $GATEWAY_ID"
    else
      echo "  WARNING: Could not create or find gateway. Create manually."
    fi
}

if [[ -n "${GATEWAY_ID:-}" ]]; then
  GATEWAY_URL="https://${GATEWAY_ID}.gateway.bedrock-agentcore.${AWS_REGION}.amazonaws.com/mcp"
  echo "  Gateway URL: $GATEWAY_URL"

  # Add agent target to gateway
  aws bedrock-agentcore create-gateway-target \
    --region "$AWS_REGION" \
    --gateway-id "$GATEWAY_ID" \
    --name "$AGENT_NAME" \
    --target-configuration "{
      \"agentRuntime\": {
        \"agentRuntimeId\": \"$RUNTIME_ID\"
      }
    }" \
    --output text 2>/dev/null && echo "  Added agent target to gateway" || \
    echo "  Gateway target may already exist"
else
  GATEWAY_URL=""
fi

# =============================================================================
# Step 5: Set Environment Variables on Runtime
# =============================================================================
echo ""
echo "--- Step 5: Update Agent Environment Variables ---"

if [[ -n "$RUNTIME_ID" ]]; then
  aws bedrock-agentcore update-agent-runtime \
    --region "$AWS_REGION" \
    --agent-runtime-id "$RUNTIME_ID" \
    --environment-variables "{
      \"TENANT_ID\": \"$TENANT_ID\",
      \"TEAMS_BOT_NOTIFY_URL\": \"$BOT_NOTIFY_URL\",
      \"OUTBOUND_APP_ID\": \"${OUTBOUND_APP_ID:-}\",
      \"OUTBOUND_APP_SECRET\": \"${OUTBOUND_APP_SECRET:-}\"
    }" \
    --output text 2>/dev/null && echo "  Environment variables updated" || \
    echo "  WARNING: Could not update env vars via CLI. Set them in AgentCore console."
fi

# =============================================================================
# Output Summary
# =============================================================================
echo ""
echo "============================================================"
echo " AWS DEPLOYMENT COMPLETE"
echo "============================================================"
echo ""
echo " AWS Account:        $AWS_ACCOUNT_ID"
echo " Region:             $AWS_REGION"
echo ""
echo " --- IAM Roles ---"
echo " Agent Role:         $AGENT_ROLE_ARN"
echo " Gateway Role:       $GATEWAY_ROLE_ARN"
echo ""
echo " --- AgentCore Runtime ---"
echo " Agent Name:         $AGENT_NAME"
echo " Runtime ID:         ${RUNTIME_ID:-NOT_SET}"
echo " Agent ARN:          ${AGENT_ARN:-NOT_SET}"
echo " Inbound Auth:       Entra JWT"
echo " Discovery URL:      $DISCOVERY_URL"
echo " Audience:           $AUDIENCE"
echo ""
echo " --- AgentCore Gateway ---"
echo " Gateway ID:         ${GATEWAY_ID:-NOT_SET}"
echo " Gateway URL:        ${GATEWAY_URL:-NOT_SET}"
echo ""
echo " --- Agent Environment ---"
echo " TEAMS_BOT_NOTIFY_URL=$BOT_NOTIFY_URL"
echo " TENANT_ID=$TENANT_ID"
echo ""
echo " --- Runtime Invocation URL ---"
echo " https://bedrock-agentcore.${AWS_REGION}.amazonaws.com/runtimes/${RUNTIME_ID:-RUNTIME_ID}/invocations?accountId=${AWS_ACCOUNT_ID}"
echo ""

# Append to .env
if [[ -f "$ENV_FILE" ]]; then
  cat >> "$ENV_FILE" <<EOF

# AWS Resources - Generated by deploy-aws.sh
AWS_REGION=$AWS_REGION
AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID
AGENTCORE_RUNTIME_ID=${RUNTIME_ID:-}
AGENTCORE_AGENT_ARN=${AGENT_ARN:-}
AGENTCORE_GATEWAY_ID=${GATEWAY_ID:-}
AGENTCORE_GATEWAY_URL=${GATEWAY_URL:-}
EOF
  echo "  Appended AWS values to: $ENV_FILE"
fi

echo ""
echo " Next steps:"
echo "   1. Verify agent is running: bedrock-agentcore status --agent-name $AGENT_NAME"
echo "   2. Test invocation from Teams"
echo "   3. Test MCP gateway with Claude Code / Cursor"
echo "   4. For MCP client config, use:"
echo "      Gateway URL: ${GATEWAY_URL:-<gateway-url>}"
echo "      Auth: Entra JWT Bearer token (scope: $AUDIENCE/.default)"
