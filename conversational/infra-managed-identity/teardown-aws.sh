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
# Teardown AWS Resources (v2)
#
# Removes all AWS resources created by deploy-aws.sh
# DRY RUN by default — pass --confirm to actually delete
#
# Usage:
#   ./teardown-aws.sh              # dry run
#   ./teardown-aws.sh --confirm    # actually delete
# =============================================================================

CONFIRM=false
AWS_REGION="${AWS_REGION:-us-east-1}"
AGENT_NAME="${AGENT_NAME:-teamsagent_Agent}"
CREDENTIAL_PROVIDER_NAME="${CREDENTIAL_PROVIDER_NAME:-microsoft-entra-outbound}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM=true; shift;;
    --region) AWS_REGION="$2"; shift 2;;
    *) echo "Unknown: $1"; exit 1;;
  esac
done

export AWS_REGION

if [[ "$CONFIRM" != "true" ]]; then
  echo "DRY RUN — pass --confirm to actually delete"
  echo ""
fi

run() {
  if [[ "$CONFIRM" == "true" ]]; then
    echo "  Deleting: $1"
    eval "$2" 2>/dev/null || echo "  (already gone or failed)"
  else
    echo "  Would delete: $1"
  fi
}

echo "=== Teardown AWS Resources (region: $AWS_REGION) ==="
echo ""

# Auto-detect resources
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
RUNTIME_ID=$(aws bedrock-agentcore-control list-agent-runtimes --region "$AWS_REGION" \
  --query "agentRuntimes[?contains(agentRuntimeName,'$AGENT_NAME')].agentRuntimeId" --output text 2>/dev/null | head -1 || true)
GATEWAY_ID=$(aws bedrock-agentcore-control list-gateways --region "$AWS_REGION" \
  --query "items[0].gatewayId" --output text 2>/dev/null || true)

echo "Detected:"
echo "  Runtime ID: ${RUNTIME_ID:-none}"
echo "  Gateway ID: ${GATEWAY_ID:-none}"
echo ""

# Gateway targets
if [[ -n "$GATEWAY_ID" && "$GATEWAY_ID" != "None" ]]; then
  TARGETS=$(aws bedrock-agentcore-control list-gateway-targets --gateway-identifier "$GATEWAY_ID" \
    --region "$AWS_REGION" --query "targets[].targetId" --output text 2>/dev/null || true)
  for TARGET_ID in $TARGETS; do
    run "Gateway target: $TARGET_ID" \
      "aws bedrock-agentcore-control delete-gateway-target --gateway-identifier $GATEWAY_ID --target-id $TARGET_ID --region $AWS_REGION"
  done

  run "Gateway: $GATEWAY_ID" \
    "aws bedrock-agentcore-control delete-gateway --gateway-identifier $GATEWAY_ID --region $AWS_REGION"
fi

# AgentCore Identity credential provider
run "Credential provider: $CREDENTIAL_PROVIDER_NAME" \
  "aws bedrock-agentcore-control delete-oauth2-credential-provider --name $CREDENTIAL_PROVIDER_NAME --region $AWS_REGION"

# Agent Runtime
if [[ -n "$RUNTIME_ID" && "$RUNTIME_ID" != "None" ]]; then
  run "Agent Runtime: $RUNTIME_ID" \
    "aws bedrock-agentcore-control delete-agent-runtime --agent-runtime-id $RUNTIME_ID --region $AWS_REGION"
fi

# S3 bucket
S3_BUCKET="bedrock-agentcore-codebuild-sources-${AWS_ACCOUNT_ID}-${AWS_REGION}"
run "S3 bucket: $S3_BUCKET" \
  "aws s3 rb s3://$S3_BUCKET --force --region $AWS_REGION"

# IAM roles
for ROLE in AgentCoreTeamsAgentRole AgentCoreGatewayRole; do
  POLICIES=$(aws iam list-role-policies --role-name "$ROLE" --query "PolicyNames[]" --output text 2>/dev/null || true)
  ATTACHED=$(aws iam list-attached-role-policies --role-name "$ROLE" --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null || true)

  if [[ "$CONFIRM" == "true" ]]; then
    for P in $POLICIES; do
      aws iam delete-role-policy --role-name "$ROLE" --policy-name "$P" 2>/dev/null || true
    done
    for P in $ATTACHED; do
      aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$P" 2>/dev/null || true
    done
  fi

  run "IAM Role: $ROLE" \
    "aws iam delete-role --role-name $ROLE"
done

echo ""
if [[ "$CONFIRM" == "true" ]]; then
  echo "Teardown complete."
else
  echo "No changes made. Run with --confirm to delete."
fi
