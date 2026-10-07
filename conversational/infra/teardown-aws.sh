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
# Teardown AWS Resources for AgentCore + Microsoft Teams Integration
#
# Removes:
#   - AgentCore Gateway and targets
#   - AgentCore Runtime agent
#   - IAM Roles and inline policies
#
# Usage:
#   ./teardown-aws.sh [--region REGION] [--confirm]
#
# Without --confirm, runs in dry-run mode showing what would be deleted.
# =============================================================================

# ---------- Defaults ----------
AWS_REGION="${AWS_REGION:-us-east-1}"
AGENT_NAME="${AGENT_NAME:-teamsagent_Agent}"
AGENT_ROLE_NAME="${AGENT_ROLE_NAME:-AgentCoreTeamsAgentRole}"
GATEWAY_ROLE_NAME="${GATEWAY_ROLE_NAME:-AgentCoreGatewayRole}"
CONFIRM=false

# ---------- Parse CLI Args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) AWS_REGION="$2"; shift 2;;
    --agent-name) AGENT_NAME="$2"; shift 2;;
    --confirm) CONFIRM=true; shift;;
    --help) echo "Usage: $0 [--region REGION] [--agent-name NAME] [--confirm]"; exit 0;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

# ---------- Load from .env if available ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE" 2>/dev/null || true
  set +a
fi

AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")}"
RUNTIME_ID="${AGENTCORE_RUNTIME_ID:-}"
GATEWAY_ID="${AGENTCORE_GATEWAY_ID:-}"

echo "============================================================"
echo " AgentCore + Teams - AWS Teardown"
echo "============================================================"
echo ""
echo " AWS Account:       $AWS_ACCOUNT_ID"
echo " Region:            $AWS_REGION"
echo " Agent Name:        $AGENT_NAME"
echo " Runtime ID:        ${RUNTIME_ID:-auto-detect}"
echo " Gateway ID:        ${GATEWAY_ID:-auto-detect}"
echo " Agent Role:        $AGENT_ROLE_NAME"
echo " Gateway Role:      $GATEWAY_ROLE_NAME"
echo ""

if [[ "$CONFIRM" != "true" ]]; then
  echo " *** DRY RUN MODE ***"
  echo " Add --confirm to actually delete resources."
  echo ""
fi

# =============================================================================
# Step 1: Auto-detect Resource IDs if not provided
# =============================================================================
echo "--- Step 1: Resource Discovery ---"

# Try to find Runtime ID from config file
if [[ -z "$RUNTIME_ID" ]]; then
  AGENT_CONFIG="$PROJECT_ROOT/agent/teamsagent/.bedrock_agentcore.yaml"
  if [[ -f "$AGENT_CONFIG" ]]; then
    RUNTIME_ID=$(grep "agent_id:" "$AGENT_CONFIG" | head -1 | awk '{print $2}')
    echo "  Found Runtime ID from config: $RUNTIME_ID"
  fi
fi

# Try to find Gateway ID via API
if [[ -z "$GATEWAY_ID" ]]; then
  GATEWAY_NAME="${AGENT_NAME}gateway"
  GATEWAY_ID=$(aws bedrock-agentcore list-gateways \
    --region "$AWS_REGION" \
    --output json 2>/dev/null | jq -r ".gateways[] | select(.name==\"$GATEWAY_NAME\") | .gatewayId // .id" 2>/dev/null || echo "")
  if [[ -n "$GATEWAY_ID" ]]; then
    echo "  Found Gateway ID via API: $GATEWAY_ID"
  else
    echo "  Could not auto-detect Gateway ID"
  fi
fi

# =============================================================================
# Step 2: Delete MCP Gateway
# =============================================================================
echo ""
echo "--- Step 2: AgentCore Gateway ---"

if [[ -n "$GATEWAY_ID" ]]; then
  echo "  Found gateway: $GATEWAY_ID"

  # List and delete gateway targets first
  TARGETS=$(aws bedrock-agentcore list-gateway-targets \
    --region "$AWS_REGION" \
    --gateway-id "$GATEWAY_ID" \
    --output json 2>/dev/null | jq -r '.targets[].targetId // .targets[].name' 2>/dev/null || echo "")

  if [[ -n "$TARGETS" ]]; then
    echo "  Gateway targets found:"
    for TARGET_ID in $TARGETS; do
      echo "    - $TARGET_ID"
      if [[ "$CONFIRM" == "true" ]]; then
        aws bedrock-agentcore delete-gateway-target \
          --region "$AWS_REGION" \
          --gateway-id "$GATEWAY_ID" \
          --target-id "$TARGET_ID" \
          --output text 2>/dev/null || true
        echo "      DELETED"
      fi
    done
  fi

  if [[ "$CONFIRM" == "true" ]]; then
    aws bedrock-agentcore delete-gateway \
      --region "$AWS_REGION" \
      --gateway-id "$GATEWAY_ID" \
      --output text 2>/dev/null && echo "  DELETED: Gateway $GATEWAY_ID" || \
      echo "  WARNING: Could not delete gateway (may already be deleted or in use)"
  else
    echo "  Would delete: Gateway $GATEWAY_ID"
  fi
else
  echo "  No gateway found (skipping)"
fi

# =============================================================================
# Step 3: Delete AgentCore Runtime Agent
# =============================================================================
echo ""
echo "--- Step 3: AgentCore Runtime Agent ---"

if [[ -n "$RUNTIME_ID" ]]; then
  echo "  Found runtime: $RUNTIME_ID"
  if [[ "$CONFIRM" == "true" ]]; then
    aws bedrock-agentcore delete-agent-runtime \
      --region "$AWS_REGION" \
      --agent-runtime-id "$RUNTIME_ID" \
      --output text 2>/dev/null && echo "  DELETED: Runtime $RUNTIME_ID" || \
      echo "  WARNING: Could not delete runtime (may already be deleted)"
  else
    echo "  Would delete: Runtime $RUNTIME_ID"
  fi
else
  echo "  No runtime ID found (skipping)"
  echo "  Hint: Set AGENTCORE_RUNTIME_ID in .env or check .bedrock_agentcore.yaml"
fi

# =============================================================================
# Step 4: Delete IAM Roles
# =============================================================================
echo ""
echo "--- Step 4: IAM Roles ---"

delete_role() {
  local ROLE_NAME="$1"

  if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
    echo "  Found role: $ROLE_NAME"

    # List and delete inline policies
    POLICIES=$(aws iam list-role-policies --role-name "$ROLE_NAME" --query "PolicyNames[]" -o json 2>/dev/null | jq -r '.[]' || echo "")
    for POLICY_NAME in $POLICIES; do
      echo "    Inline policy: $POLICY_NAME"
      if [[ "$CONFIRM" == "true" ]]; then
        aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$POLICY_NAME"
        echo "      DELETED"
      fi
    done

    # List and detach managed policies
    ATTACHED=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query "AttachedPolicies[].PolicyArn" -o json 2>/dev/null | jq -r '.[]' || echo "")
    for POLICY_ARN in $ATTACHED; do
      echo "    Attached policy: $POLICY_ARN"
      if [[ "$CONFIRM" == "true" ]]; then
        aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"
        echo "      DETACHED"
      fi
    done

    # Delete the role
    if [[ "$CONFIRM" == "true" ]]; then
      aws iam delete-role --role-name "$ROLE_NAME"
      echo "  DELETED: $ROLE_NAME"
    else
      echo "  Would delete: $ROLE_NAME"
    fi
  else
    echo "  Not found: $ROLE_NAME (skipping)"
  fi
}

delete_role "$AGENT_ROLE_NAME"
delete_role "$GATEWAY_ROLE_NAME"

# =============================================================================
# Step 5: Clean up local config
# =============================================================================
echo ""
echo "--- Step 5: Local Config ---"

AGENT_CONFIG="$PROJECT_ROOT/agent/teamsagent/.bedrock_agentcore.yaml"
if [[ -f "$AGENT_CONFIG" && "$CONFIRM" == "true" ]]; then
  echo "  Note: Local agent config preserved at: $AGENT_CONFIG"
  echo "  Delete manually if re-deploying from scratch:"
  echo "    rm $AGENT_CONFIG"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================================"
if [[ "$CONFIRM" == "true" ]]; then
  echo " AWS TEARDOWN COMPLETE"
  echo ""
  echo " Deleted resources:"
  [[ -n "$GATEWAY_ID" ]] && echo "   - Gateway: $GATEWAY_ID"
  [[ -n "$RUNTIME_ID" ]] && echo "   - Runtime: $RUNTIME_ID"
  echo "   - IAM Role: $AGENT_ROLE_NAME"
  echo "   - IAM Role: $GATEWAY_ROLE_NAME"
  echo ""
  echo " Remember to also run teardown-azure.sh for Azure resources."
else
  echo " DRY RUN COMPLETE"
  echo ""
  echo " No resources were deleted."
  echo " Run with --confirm to perform the actual teardown:"
  echo "   ./teardown-aws.sh --confirm"
fi
echo "============================================================"
