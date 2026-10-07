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
# Deploy AWS Infrastructure for the OBO Demo  [WORKING ARCHITECTURE]
#
# Creates / updates:
#   1. IAM execution role (AgentCoreOBOAgentRole) with bedrock + bedrock-agentcore
#      + secretsmanager:GetSecretValue + CloudWatch Logs
#   2. agentcore configure + deploy of the OBO agent (HTTP protocol)
#   3. RE-APPLIES the customJWTAuthorizer via update-agent-runtime
#
# >>> CRITICAL ORDERING <<<
#   `agentcore deploy` WIPES the customJWTAuthorizer config every time. So the
#   authorizer MUST be (re)applied with update-agent-runtime AFTER each deploy.
#   This script does deploy FIRST, then re-applies the authorizer. If you ever
#   re-run `agentcore deploy` by hand, you MUST re-run step 3 afterward or
#   inbound auth will be broken / wide open.
#
# The agent does NOT use requires_access_token / AgentCore Identity OBO exchange.
# The bot passes the user's Microsoft Graph token in the request PAYLOAD; the
# agent's tools call Graph directly with it. AgentCore inbound auth only validates
# that the CALLER (the bot) presents a valid Entra app token (customJWTAuthorizer).
#
# allowedAudience accepts BOTH:
#   - api://botid-<botAppId>   (the .default scope token the bot requests)
#   - <botAppId>               (bare appId, belt-and-suspenders)
#
# Prerequisites:
#   - ./setup-entra-obo.sh and ./deploy-azure-obo.sh have run (../.env set)
#   - `agentcore` CLI installed, AWS creds configured
#
# Usage:
#   ./deploy-aws-obo.sh [--region REGION] [--skip-deploy]
#     --skip-deploy : only re-apply the JWT authorizer (use after a manual deploy)
# =============================================================================

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

AWS_REGION="${AWS_REGION:-us-east-1}"
AGENT_NAME="${AGENT_NAME:-oboAgent}"
ROLE_NAME="${ROLE_NAME:-AgentCoreOBOAgentRole}"
SKIP_DEPLOY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) AWS_REGION="$2"; shift 2;;
    --agent-name) AGENT_NAME="$2"; shift 2;;
    --skip-deploy) SKIP_DEPLOY=true; shift;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

: "${TENANT_ID:?TENANT_ID required (run setup-entra-obo.sh)}"
: "${OBO_BOT_APP_ID:?OBO_BOT_APP_ID required (run setup-entra-obo.sh)}"

export AWS_REGION
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $AWS_ACCOUNT_ID | Region: $AWS_REGION"
echo "Agent:   $AGENT_NAME"
echo ""

# =============================================================================
# 1. IAM Role
# =============================================================================
echo "=== 1. IAM Role ==="
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Principal\": {\"Service\": \"bedrock-agentcore.amazonaws.com\"},
      \"Action\": \"sts:AssumeRole\",
      \"Condition\": {\"StringEquals\": {\"aws:SourceAccount\": \"${AWS_ACCOUNT_ID}\"}}
    }]
  }" 2>/dev/null || true

# Least-privilege inline policy. secretsmanager:GetSecretValue is required by the
# AgentCore runtime even though THIS agent doesn't read a secret itself.
# AgentCore actions are the specific runtime execution (workload-identity token)
# actions per the AgentCore runtime-permissions docs, scoped to the
# workload-identity directory — not the bedrock-agentcore:* wildcard.
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "OBOAgentAccess" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {\"Sid\":\"AgentCoreWorkloadIdentity\",\"Effect\":\"Allow\",\"Action\":[\"bedrock-agentcore:GetWorkloadAccessToken\",\"bedrock-agentcore:GetWorkloadAccessTokenForJWT\",\"bedrock-agentcore:GetWorkloadAccessTokenForUserId\"],\"Resource\":[\"arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:workload-identity-directory/default\",\"arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:workload-identity-directory/default/workload-identity/*\"]},
      {\"Sid\":\"InvokeModels\",\"Effect\":\"Allow\",\"Action\":[\"bedrock:InvokeModel\",\"bedrock:InvokeModelWithResponseStream\"],\"Resource\":[\"arn:aws:bedrock:${AWS_REGION}::foundation-model/anthropic.claude-sonnet-4*\",\"arn:aws:bedrock:${AWS_REGION}::foundation-model/us.anthropic.claude-sonnet-4*\"]},
      {\"Sid\":\"ReadSecrets\",\"Effect\":\"Allow\",\"Action\":[\"secretsmanager:GetSecretValue\"],\"Resource\":\"arn:aws:secretsmanager:${AWS_REGION}:${AWS_ACCOUNT_ID}:secret:bedrock-agentcore*\"},
      {\"Sid\":\"LogsGroup\",\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\"],\"Resource\":\"arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/bedrock-agentcore/runtimes/*\"},
      {\"Sid\":\"LogsStream\",\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*\"}
    ]
  }" 2>/dev/null || true

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/$ROLE_NAME"
echo "  Role: $ROLE_ARN"
sleep 8   # let IAM propagate before the runtime assumes it

# =============================================================================
# 2. Configure + Deploy Agent
# =============================================================================
AGENT_DIR="$(cd "$(dirname "$0")/../agent" && pwd)"

if [[ "$SKIP_DEPLOY" != "true" ]]; then
  echo ""
  echo "=== 2. Configure + Deploy Agent ==="
  ( cd "$AGENT_DIR"
    agentcore configure \
      --name "$AGENT_NAME" \
      --entrypoint "$AGENT_DIR/src/main.py" \
      --execution-role "$ROLE_ARN" \
      --protocol "HTTP" \
      --deployment-type "direct_code_deploy" \
      --region "$AWS_REGION" \
      --disable-memory \
      --runtime "PYTHON_3_12" \
      --non-interactive 2>&1 | grep -E "(✓|Configuration|Configured)" || true

    # NOTE: this deploy WIPES the customJWTAuthorizer — step 3 re-applies it.
    agentcore deploy 2>&1 | grep -E "(✅|❌|Agent|deployed|Deploy)" || true
  )
else
  echo ""
  echo "=== 2. Skipped deploy (--skip-deploy) ==="
fi

# Resolve runtime ID
RUNTIME_ID=$(aws bedrock-agentcore-control list-agent-runtimes --region "$AWS_REGION" \
  --query "agentRuntimes[?contains(agentRuntimeName,'$AGENT_NAME')].agentRuntimeId" \
  --output text | head -1)
echo "  Runtime ID: $RUNTIME_ID"
[[ -z "$RUNTIME_ID" || "$RUNTIME_ID" == "None" ]] && { echo "ERROR: runtime not found"; exit 1; }

# =============================================================================
# 3. RE-APPLY customJWTAuthorizer  (MUST run after every `agentcore deploy`)
# =============================================================================
echo ""
echo "=== 3. Re-apply customJWTAuthorizer (REQUIRED after every deploy) ==="
aws bedrock-agentcore-control update-agent-runtime \
  --agent-runtime-id "$RUNTIME_ID" \
  --role-arn "$ROLE_ARN" \
  --network-configuration '{"networkMode": "PUBLIC"}' \
  --protocol-configuration '{"serverProtocol": "HTTP"}' \
  --authorizer-configuration "{
    \"customJWTAuthorizer\": {
      \"discoveryUrl\": \"https://login.microsoftonline.com/$TENANT_ID/v2.0/.well-known/openid-configuration\",
      \"allowedAudience\": [\"api://botid-$OBO_BOT_APP_ID\", \"$OBO_BOT_APP_ID\"]
    }
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
echo "  Authorizer: Entra JWT"
echo "  discoveryUrl:    https://login.microsoftonline.com/$TENANT_ID/v2.0/.well-known/openid-configuration"
echo "  allowedAudience: [api://botid-$OBO_BOT_APP_ID, $OBO_BOT_APP_ID]"

# =============================================================================
# 4. Persist + Output
# =============================================================================
grep -v -E '^(AWS_REGION|AWS_ACCOUNT_ID|AGENTCORE_RUNTIME_ID)=' "$ENV_FILE" > "$ENV_FILE.tmp" 2>/dev/null || true
[[ -f "$ENV_FILE.tmp" ]] && mv "$ENV_FILE.tmp" "$ENV_FILE"
cat >> "$ENV_FILE" <<EOF
AWS_REGION=$AWS_REGION
AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID
AGENTCORE_RUNTIME_ID=$RUNTIME_ID
EOF

echo ""
echo "============================================================"
echo "  AWS OBO DEPLOYMENT COMPLETE"
echo "============================================================"
echo ""
echo "Runtime ID:   $RUNTIME_ID"
echo "Runtime ARN:  arn:aws:bedrock-agentcore:$AWS_REGION:$AWS_ACCOUNT_ID:runtime/$RUNTIME_ID"
echo "Invoke URL:   https://bedrock-agentcore.$AWS_REGION.amazonaws.com/runtimes/$RUNTIME_ID/invocations?accountId=$AWS_ACCOUNT_ID"
echo ""
echo "Updated: $ENV_FILE"
echo ""
echo "REMINDER: the Container App needs AGENTCORE_RUNTIME_ID=$RUNTIME_ID and"
echo "AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID. Re-run deploy-azure-obo.sh (or a"
echo "containerapp update) so the bot can reach the runtime."
