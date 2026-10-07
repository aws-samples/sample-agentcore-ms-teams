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
# Teardown OBO Demo Resources  (Azure + AWS)
#
# DRY RUN by default — pass --confirm to actually delete.
#
# Removes:
#   AWS    : AgentCore Runtime (oboAgent), IAM role (AgentCoreOBOAgentRole)
#   Azure  : Container App, Azure Bot, Managed Identity, app registration(s)
#
# By default the shared Container Apps Environment, ACR, and Resource Group are
# LEFT ALONE (they may be shared with the non-OBO demo). Pass --all to also
# delete the env / ACR, and --delete-rg to delete the resource group.
#
# Usage:
#   ./teardown-obo.sh                 # dry run, shows what WOULD be deleted
#   ./teardown-obo.sh --confirm       # delete OBO-specific resources
#   ./teardown-obo.sh --confirm --all # also delete env + ACR
#   ./teardown-obo.sh --confirm --aws-only | --azure-only
# =============================================================================

CONFIRM=false
SCOPE="both"          # both | aws-only | azure-only
DELETE_ALL=false      # also delete container env + ACR
DELETE_RG=false

# ---------- Defaults (match the deploy scripts) ----------
RESOURCE_GROUP="${RESOURCE_GROUP:-agentcore-msteams-rg}"
BOT_NAME="${BOT_NAME:-agentcore-obo-bot}"
APP_NAME="${APP_NAME:-agentcore-obo-bot}"
ACR_NAME="${ACR_NAME:-agentcoredemo2cr}"
MI_NAME="${MI_NAME:-agentcore-bot-identity}"
ENV_NAME="${ENV_NAME:-bot-env-west}"
BOT_APP_DISPLAY_NAME="${BOT_APP_DISPLAY_NAME:-AgentCore-Teams-Bot-OBO}"
DOWNSTREAM_APP_DISPLAY_NAME="${DOWNSTREAM_APP_DISPLAY_NAME:-AgentCore-OBO-Downstream}"

AWS_REGION="${AWS_REGION:-us-east-1}"
AGENT_NAME="${AGENT_NAME:-oboAgent}"
ROLE_NAME="${ROLE_NAME:-AgentCoreOBOAgentRole}"

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM=true; shift;;
    --all) DELETE_ALL=true; shift;;
    --delete-rg) DELETE_RG=true; shift;;
    --aws-only) SCOPE="aws-only"; shift;;
    --azure-only) SCOPE="azure-only"; shift;;
    --region) AWS_REGION="$2"; shift 2;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

export AWS_REGION

if [[ "$CONFIRM" != "true" ]]; then
  echo "DRY RUN — pass --confirm to actually delete."
  echo ""
fi

run() {  # run "<label>" "<command>"
  if [[ "$CONFIRM" == "true" ]]; then
    echo "  Deleting: $1"
    eval "$2" 2>/dev/null || echo "    (already gone or failed)"
  else
    echo "  Would delete: $1"
  fi
}

# =============================================================================
# AWS
# =============================================================================
if [[ "$SCOPE" == "both" || "$SCOPE" == "aws-only" ]]; then
  echo "=== AWS (region: $AWS_REGION) ==="
  RUNTIME_ID=$(aws bedrock-agentcore-control list-agent-runtimes --region "$AWS_REGION" \
    --query "agentRuntimes[?contains(agentRuntimeName,'$AGENT_NAME')].agentRuntimeId" \
    --output text 2>/dev/null | head -1 || true)
  echo "  Detected runtime: ${RUNTIME_ID:-none}"

  if [[ -n "$RUNTIME_ID" && "$RUNTIME_ID" != "None" ]]; then
    run "AgentCore Runtime: $RUNTIME_ID" \
      "aws bedrock-agentcore-control delete-agent-runtime --agent-runtime-id $RUNTIME_ID --region $AWS_REGION"
  fi

  # IAM role: drop inline policies first, then delete the role.
  if [[ "$CONFIRM" == "true" ]]; then
    for P in $(aws iam list-role-policies --role-name "$ROLE_NAME" --query "PolicyNames[]" --output text 2>/dev/null || true); do
      aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$P" 2>/dev/null || true
    done
    for P in $(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null || true); do
      aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$P" 2>/dev/null || true
    done
  fi
  run "IAM Role: $ROLE_NAME" \
    "aws iam delete-role --role-name $ROLE_NAME"
  echo ""
fi

# =============================================================================
# Azure
# =============================================================================
if [[ "$SCOPE" == "both" || "$SCOPE" == "azure-only" ]]; then
  echo "=== Azure (RG: $RESOURCE_GROUP) ==="

  run "Container App: $APP_NAME" \
    "az containerapp delete --name $APP_NAME --resource-group $RESOURCE_GROUP --yes"

  run "Azure Bot: $BOT_NAME" \
    "az bot delete --resource-group $RESOURCE_GROUP --name $BOT_NAME"

  run "Managed Identity: $MI_NAME" \
    "az identity delete --name $MI_NAME --resource-group $RESOURCE_GROUP"

  # App registration(s) — look up by display name AND by saved appId.
  BOT_APP_ID="${OBO_BOT_APP_ID:-$(az ad app list --display-name "$BOT_APP_DISPLAY_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)}"
  if [[ -n "$BOT_APP_ID" && "$BOT_APP_ID" != "None" ]]; then
    run "App Registration: $BOT_APP_DISPLAY_NAME ($BOT_APP_ID)" \
      "az ad app delete --id $BOT_APP_ID"
  fi

  # Legacy/unused downstream app (only present from the failed exchange approach).
  DOWNSTREAM_APP_ID="${OBO_DOWNSTREAM_APP_ID:-$(az ad app list --display-name "$DOWNSTREAM_APP_DISPLAY_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)}"
  if [[ -n "$DOWNSTREAM_APP_ID" && "$DOWNSTREAM_APP_ID" != "None" ]]; then
    run "App Registration (legacy/unused): $DOWNSTREAM_APP_DISPLAY_NAME ($DOWNSTREAM_APP_ID)" \
      "az ad app delete --id $DOWNSTREAM_APP_ID"
  fi

  if [[ "$DELETE_ALL" == "true" ]]; then
    run "Container Apps Env: $ENV_NAME" \
      "az containerapp env delete --name $ENV_NAME --resource-group $RESOURCE_GROUP --yes"
    run "Container Registry: $ACR_NAME" \
      "az acr delete --name $ACR_NAME --resource-group $RESOURCE_GROUP --yes"
  else
    echo "  Keeping (shared): Container Apps Env ($ENV_NAME), ACR ($ACR_NAME). Use --all to delete."
  fi

  if [[ "$DELETE_RG" == "true" ]]; then
    run "Resource Group: $RESOURCE_GROUP" \
      "az group delete --name $RESOURCE_GROUP --yes --no-wait"
  else
    echo "  Keeping: Resource Group ($RESOURCE_GROUP). Use --delete-rg to delete."
  fi
  echo ""
fi

echo ""
if [[ "$CONFIRM" == "true" ]]; then
  echo "Teardown complete."
  echo "NOTE: federated credentials are deleted along with the app registration."
else
  echo "No changes made. Run with --confirm to delete."
fi
