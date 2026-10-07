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
# Deploy AWS infra for the Meeting Assistant
#   1. IAM role (bedrock + bedrock-agentcore + memory + logs)
#   2. AgentCore MEMORY resource (semantic strategy, /users/{actorId}/facts/)
#   3. agentcore configure + deploy
#   4. RE-APPLY customJWTAuthorizer + env (MEMORY_ID, AWS_REGION) - deploy wipes it
#
# This is the FIRST demo to use AgentCore Memory.
#
# Prereq: setup-entra-meeting.sh (../.env set)
# Usage:  ./deploy-aws-meeting.sh [--region REGION] [--skip-deploy]
# =============================================================================

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

AWS_REGION="${AWS_REGION:-us-east-1}"
AGENT_NAME="${AGENT_NAME:-meetingAgent}"
ROLE_NAME="${ROLE_NAME:-AgentCoreMeetingAgentRole}"
MEMORY_NAME="${MEMORY_NAME:-meetingAssistantMemory}"
SKIP_DEPLOY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) AWS_REGION="$2"; shift 2;;
    --skip-deploy) SKIP_DEPLOY=true; shift;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

: "${TENANT_ID:?}"; : "${MEETING_APP_ID:?}"
export AWS_REGION
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $AWS_ACCOUNT_ID | Region: $AWS_REGION | Agent: $AGENT_NAME"
echo ""

# 1. IAM role
echo "=== 1. IAM Role ==="
aws iam create-role --role-name "$ROLE_NAME" \
  --assume-role-policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"bedrock-agentcore.amazonaws.com\"},\"Action\":\"sts:AssumeRole\",\"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"${AWS_ACCOUNT_ID}\"}}}]}" \
  2>/dev/null || true
# Least-privilege inline policy. AgentCore actions are the specific runtime
# execution + Memory data-plane actions this agent needs (per the AgentCore
# runtime-permissions docs), scoped to the workload-identity directory and this
# account/region's Memory resources — not the bedrock-agentcore:* wildcard.
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "MeetingAgentAccess" \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[
      {\"Sid\":\"AgentCoreWorkloadIdentity\",\"Effect\":\"Allow\",\"Action\":[\"bedrock-agentcore:GetWorkloadAccessToken\",\"bedrock-agentcore:GetWorkloadAccessTokenForJWT\",\"bedrock-agentcore:GetWorkloadAccessTokenForUserId\"],\"Resource\":[\"arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:workload-identity-directory/default\",\"arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:workload-identity-directory/default/workload-identity/*\"]},
      {\"Sid\":\"AgentCoreMemory\",\"Effect\":\"Allow\",\"Action\":[\"bedrock-agentcore:CreateEvent\",\"bedrock-agentcore:ListEvents\",\"bedrock-agentcore:GetEvent\",\"bedrock-agentcore:ListActors\",\"bedrock-agentcore:ListSessions\",\"bedrock-agentcore:RetrieveMemoryRecords\",\"bedrock-agentcore:ListMemoryRecords\",\"bedrock-agentcore:GetMemoryRecord\"],\"Resource\":\"arn:aws:bedrock-agentcore:${AWS_REGION}:${AWS_ACCOUNT_ID}:memory/${MEMORY_NAME}-*\"},
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

# 2. AgentCore Memory resource
echo ""
echo "=== 2. AgentCore Memory ==="
MEMORY_ID="${MEMORY_ID:-}"
if [[ -z "$MEMORY_ID" ]]; then
  # Check if one already exists by name
  MEMORY_ID=$(aws bedrock-agentcore-control list-memories --region "$AWS_REGION" \
    --query "memories[?name=='$MEMORY_NAME'].id | [0]" --output text 2>/dev/null || true)
fi
if [[ -z "$MEMORY_ID" || "$MEMORY_ID" == "None" ]]; then
  echo "  Creating memory '$MEMORY_NAME' (semantic strategy)..."
  # eventExpiryDuration is a NUMBER of days; strategy uses semanticMemoryStrategy + namespaces.
  MEMORY_ID=$(aws bedrock-agentcore-control create-memory \
    --name "$MEMORY_NAME" \
    --event-expiry-duration 90 \
    --memory-strategies '[{"semanticMemoryStrategy":{"name":"meetingFacts","namespaces":["/users/{actorId}/facts/"]}}]' \
    --region "$AWS_REGION" \
    --query "memory.id" --output text 2>&1) || {
      echo "  create-memory with strategy failed; retrying without strategy..."
      MEMORY_ID=$(aws bedrock-agentcore-control create-memory \
        --name "$MEMORY_NAME" \
        --event-expiry-duration 90 \
        --region "$AWS_REGION" \
        --query "memory.id" --output text)
    }
  echo "  Memory created: $MEMORY_ID"
  echo "  Waiting for ACTIVE..."
  for i in $(seq 1 30); do
    ST=$(aws bedrock-agentcore-control get-memory --memory-id "$MEMORY_ID" --region "$AWS_REGION" --query "memory.status" --output text 2>/dev/null || echo "")
    [[ "$ST" == "ACTIVE" ]] && break
    sleep 10
  done
  echo "  Memory status: $ST"
else
  echo "  Reusing memory: $MEMORY_ID"
fi

# 3. Configure + deploy
AGENT_DIR="$(cd "$(dirname "$0")/../agent" && pwd)"
if [[ "$SKIP_DEPLOY" != "true" ]]; then
  echo ""
  echo "=== 3. Configure + Deploy Agent ==="
  ( cd "$AGENT_DIR"
    agentcore configure --name "$AGENT_NAME" --entrypoint "$AGENT_DIR/src/main.py" \
      --execution-role "$ROLE_ARN" --protocol "HTTP" --deployment-type "direct_code_deploy" \
      --region "$AWS_REGION" --disable-memory --runtime "PYTHON_3_12" --non-interactive \
      2>&1 | grep -E "(✓|Configuration)" || true
    agentcore deploy 2>&1 | grep -E "(✅|❌|Agent|deployed)" || true
  )
fi

RUNTIME_ID=$(aws bedrock-agentcore-control list-agent-runtimes --region "$AWS_REGION" \
  --query "agentRuntimes[?contains(agentRuntimeName,'$AGENT_NAME')].agentRuntimeId" --output text | head -1)
echo "  Runtime ID: $RUNTIME_ID"
[[ -z "$RUNTIME_ID" || "$RUNTIME_ID" == "None" ]] && { echo "ERROR: runtime not found"; exit 1; }

# 4. Re-apply authorizer + env (MEMORY_ID, AWS_REGION)
echo ""
echo "=== 4. Re-apply authorizer + env (REQUIRED after every deploy) ==="
aws bedrock-agentcore-control update-agent-runtime \
  --agent-runtime-id "$RUNTIME_ID" --role-arn "$ROLE_ARN" \
  --network-configuration '{"networkMode": "PUBLIC"}' \
  --protocol-configuration '{"serverProtocol": "HTTP"}' \
  --authorizer-configuration "{\"customJWTAuthorizer\":{\"discoveryUrl\":\"https://login.microsoftonline.com/$TENANT_ID/v2.0/.well-known/openid-configuration\",\"allowedAudience\":[\"api://botid-$MEETING_APP_ID\",\"$MEETING_APP_ID\"]}}" \
  --environment-variables "{\"MEMORY_ID\":\"$MEMORY_ID\",\"AWS_REGION\":\"$AWS_REGION\"}" \
  --agent-runtime-artifact "{\"codeConfiguration\":{\"code\":{\"s3\":{\"bucket\":\"bedrock-agentcore-codebuild-sources-${AWS_ACCOUNT_ID}-${AWS_REGION}\",\"prefix\":\"${AGENT_NAME}/deployment.zip\"}},\"runtime\":\"PYTHON_3_12\",\"entryPoint\":[\"src/main.py\"]}}" \
  --region "$AWS_REGION" --query "{status:status}" --output table
echo "  Authorizer + MEMORY_ID=$MEMORY_ID applied"

# Persist
grep -v -E '^(AWS_REGION|AWS_ACCOUNT_ID|MEETING_AGENT_RUNTIME_ID|MEMORY_ID)=' "$ENV_FILE" > "$ENV_FILE.tmp" 2>/dev/null && mv "$ENV_FILE.tmp" "$ENV_FILE" || true
cat >> "$ENV_FILE" <<EOF
AWS_REGION=$AWS_REGION
AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID
MEETING_AGENT_RUNTIME_ID=$RUNTIME_ID
MEMORY_ID=$MEMORY_ID
EOF

echo ""
echo "============================================================"
echo "  AWS MEETING DEPLOYMENT COMPLETE"
echo "============================================================"
echo "Runtime ID: $RUNTIME_ID"
echo "Memory ID:  $MEMORY_ID"
echo "Next: ./deploy-azure-meeting.sh"
