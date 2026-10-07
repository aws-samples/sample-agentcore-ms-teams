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
# Deploy AWS infra for the Notify Agent
#   1. IAM role (bedrock + bedrock-agentcore + logs)
#   2. agentcore configure + deploy
#   3. RE-APPLY customJWTAuthorizer (deploy WIPES it - see OBO notes)
#   4. Set NOTIFY_BOT_URL + NOTIFY_SECRET env vars on the runtime
#
# The agent authenticates inbound with the NOTIFY bot's app token (or any caller
# we trust). For the demo we accept the notify bot app id audience. The agent's
# only outbound call is to the notify bot's /api/notify (HTTP, NOTIFY_SECRET).
#
# Prereq: setup-entra-notify.sh + deploy-azure-notify.sh (../.env set,
#         NOTIFY_BOT_FQDN populated)
# Usage:  ./deploy-aws-notify.sh [--region REGION] [--skip-deploy]
# =============================================================================

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

AWS_REGION="${AWS_REGION:-us-east-1}"
AGENT_NAME="${AGENT_NAME:-notifyAgent}"
ROLE_NAME="${ROLE_NAME:-AgentCoreNotifyAgentRole}"
SKIP_DEPLOY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) AWS_REGION="$2"; shift 2;;
    --skip-deploy) SKIP_DEPLOY=true; shift;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

: "${TENANT_ID:?}"; : "${NOTIFY_BOT_APP_ID:?}"
: "${NOTIFY_BOT_FQDN:?NOTIFY_BOT_FQDN required (run deploy-azure-notify.sh first)}"

export AWS_REGION
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
NOTIFY_BOT_URL="https://$NOTIFY_BOT_FQDN/api/notify"
echo "Account: $AWS_ACCOUNT_ID | Region: $AWS_REGION | Agent: $AGENT_NAME"
echo "Notify URL: $NOTIFY_BOT_URL"
echo ""

# 1. IAM role
echo "=== 1. IAM Role ==="
aws iam create-role --role-name "$ROLE_NAME" \
  --assume-role-policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"bedrock-agentcore.amazonaws.com\"},\"Action\":\"sts:AssumeRole\",\"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"${AWS_ACCOUNT_ID}\"}}}]}" \
  2>/dev/null || true
# Least-privilege inline policy. AgentCore actions are the specific runtime
# execution (workload-identity token) actions this agent needs per the AgentCore
# runtime-permissions docs, scoped to the workload-identity directory — not the
# bedrock-agentcore:* wildcard.
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "NotifyAgentAccess" \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[
      {\"Sid\":\"AgentCoreWorkloadIdentity\",\"Effect\":\"Allow\",\"Action\":[\"bedrock-agentcore:GetWorkloadAccessToken\",\"bedrock-agentcore:GetWorkloadAccessTokenForJWT\",\"bedrock-agentcore:GetWorkloadAccessTokenForUserId\"],\"Resource\":[\"arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:workload-identity-directory/default\",\"arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:workload-identity-directory/default/workload-identity/*\"]},
      {\"Sid\":\"InvokeModels\",\"Effect\":\"Allow\",\"Action\":[\"bedrock:InvokeModel\",\"bedrock:InvokeModelWithResponseStream\"],\"Resource\":[\"arn:aws:bedrock:${AWS_REGION}::foundation-model/anthropic.claude-sonnet-4*\",\"arn:aws:bedrock:${AWS_REGION}::foundation-model/us.anthropic.claude-sonnet-4*\"]},
      {\"Sid\":\"ReadSecrets\",\"Effect\":\"Allow\",\"Action\":[\"secretsmanager:GetSecretValue\"],\"Resource\":\"arn:aws:secretsmanager:${AWS_REGION}:${AWS_ACCOUNT_ID}:secret:bedrock-agentcore*\"},
      {\"Sid\":\"LogsGroup\",\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\"],\"Resource\":\"arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/bedrock-agentcore/runtimes/*\"},
      {\"Sid\":\"LogsStream\",\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*\"}
    ]
  }" \
  2>/dev/null || true
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/$ROLE_NAME"
echo "  $ROLE_ARN"
sleep 8

# 2. Configure + deploy
AGENT_DIR="$(cd "$(dirname "$0")/../agent" && pwd)"
if [[ "$SKIP_DEPLOY" != "true" ]]; then
  echo ""
  echo "=== 2. Configure + Deploy Agent ==="
  # export AWS_REGION so agentcore can't fall back to the machine's profile
  # default region (this is how the agent once drifted to us-west-2).
  ( cd "$AGENT_DIR"
    export AWS_REGION="$AWS_REGION" AWS_DEFAULT_REGION="$AWS_REGION"
    agentcore configure --name "$AGENT_NAME" --entrypoint "$AGENT_DIR/src/main.py" \
      --execution-role "$ROLE_ARN" --protocol "HTTP" --deployment-type "direct_code_deploy" \
      --region "$AWS_REGION" --disable-memory --runtime "PYTHON_3_12" --non-interactive \
      2>&1 | grep -E "(✓|Configuration|Region)" || true
    agentcore deploy 2>&1 | grep -E "(✅|❌|Agent|deployed)" || true
  )
fi

RUNTIME_ID=$(aws bedrock-agentcore-control list-agent-runtimes --region "$AWS_REGION" \
  --query "agentRuntimes[?contains(agentRuntimeName,'$AGENT_NAME')].agentRuntimeId" --output text | head -1)
echo "  Runtime ID: $RUNTIME_ID"
[[ -z "$RUNTIME_ID" || "$RUNTIME_ID" == "None" ]] && { echo "ERROR: runtime not found"; exit 1; }

# 3. Re-apply env vars (deploy wipes them).
# NOTE: This agent uses DEFAULT IAM (SigV4) auth — NO customJWTAuthorizer.
# The notify agent does not use the caller's user identity (the bot sends
# notifications with its own app token), so IAM auth is the right fit AND lets
# you demo with a simple `agentcore invoke '{...}'` (no Entra token minting).
# If you ever DO want JWT auth, add --authorizer-configuration with
# customJWTAuthorizer (discoveryUrl + allowedAudience [api://botid-<appId>, <appId>]).
echo ""
echo "=== 3. Re-apply env vars (REQUIRED after every deploy; IAM auth, no authorizer) ==="
aws bedrock-agentcore-control update-agent-runtime \
  --agent-runtime-id "$RUNTIME_ID" --role-arn "$ROLE_ARN" \
  --network-configuration '{"networkMode": "PUBLIC"}' \
  --protocol-configuration '{"serverProtocol": "HTTP"}' \
  --environment-variables "{\"NOTIFY_BOT_URL\":\"$NOTIFY_BOT_URL\",\"NOTIFY_SECRET\":\"${NOTIFY_SECRET:-}\"}" \
  --agent-runtime-artifact "{\"codeConfiguration\":{\"code\":{\"s3\":{\"bucket\":\"bedrock-agentcore-codebuild-sources-${AWS_ACCOUNT_ID}-${AWS_REGION}\",\"prefix\":\"${AGENT_NAME}/deployment.zip\"}},\"runtime\":\"PYTHON_3_12\",\"entryPoint\":[\"src/main.py\"]}}" \
  --region "$AWS_REGION" --query "{status:status}" --output table
echo "  Env vars applied (IAM auth)"

# Persist
grep -v -E '^(AWS_REGION|AWS_ACCOUNT_ID|NOTIFY_AGENT_RUNTIME_ID|NOTIFY_BOT_URL)=' "$ENV_FILE" > "$ENV_FILE.tmp" 2>/dev/null && mv "$ENV_FILE.tmp" "$ENV_FILE" || true
cat >> "$ENV_FILE" <<EOF
AWS_REGION=$AWS_REGION
AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID
NOTIFY_AGENT_RUNTIME_ID=$RUNTIME_ID
NOTIFY_BOT_URL=$NOTIFY_BOT_URL
EOF

echo ""
echo "============================================================"
echo "  AWS NOTIFY DEPLOYMENT COMPLETE"
echo "============================================================"
echo "Runtime ID:  $RUNTIME_ID"
echo "Test:        agentcore invoke '{\"prompt\": \"notify jane@example.com that the build passed\"}'"
