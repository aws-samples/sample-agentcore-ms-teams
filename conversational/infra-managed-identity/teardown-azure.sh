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
# Teardown Azure Resources (v2)
#
# Removes all Azure resources created by deploy-azure.sh
# DRY RUN by default — pass --confirm to actually delete
#
# Usage:
#   ./teardown-azure.sh              # dry run
#   ./teardown-azure.sh --confirm    # actually delete
# =============================================================================

CONFIRM=false
RESOURCE_GROUP="${RESOURCE_GROUP:-agentcore-msteams-rg}"
BOT_NAME="${BOT_NAME:-agentcore-bot-demo}"
ACR_NAME="${ACR_NAME:-agentcoredemo2cr}"
MI_NAME="${MI_NAME:-agentcore-bot-identity}"
APP_NAME="${APP_NAME:-agentcore-teams-bot}"
ENV_NAME="${ENV_NAME:-bot-env-west}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM=true; shift;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2;;
    *) echo "Unknown: $1"; exit 1;;
  esac
done

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

echo "=== Teardown Azure Resources ==="
echo ""

# App Registrations
BOT_APP_ID=$(az ad app list --display-name "AgentCore-Teams-Bot" --query "[0].appId" -o tsv 2>/dev/null || true)
OUTBOUND_APP_ID=$(az ad app list --display-name "AgentCore-Outbound" --query "[0].appId" -o tsv 2>/dev/null || true)

if [[ -n "$BOT_APP_ID" ]]; then
  run "App Registration: AgentCore-Teams-Bot ($BOT_APP_ID)" \
    "az ad app delete --id $BOT_APP_ID"
fi

if [[ -n "$OUTBOUND_APP_ID" ]]; then
  run "App Registration: AgentCore-Outbound ($OUTBOUND_APP_ID)" \
    "az ad app delete --id $OUTBOUND_APP_ID"
fi

# Azure Bot
run "Azure Bot: $BOT_NAME" \
  "az bot delete --resource-group $RESOURCE_GROUP --name $BOT_NAME"

# Container App
run "Container App: $APP_NAME" \
  "az containerapp delete --name $APP_NAME --resource-group $RESOURCE_GROUP --yes"

# Container Apps Environment
run "Container Apps Env: $ENV_NAME" \
  "az containerapp env delete --name $ENV_NAME --resource-group $RESOURCE_GROUP --yes"

# Container Registry
run "Container Registry: $ACR_NAME" \
  "az acr delete --name $ACR_NAME --resource-group $RESOURCE_GROUP --yes"

# Managed Identity
run "Managed Identity: $MI_NAME" \
  "az identity delete --name $MI_NAME --resource-group $RESOURCE_GROUP"

# Resource Group (last)
run "Resource Group: $RESOURCE_GROUP" \
  "az group delete --name $RESOURCE_GROUP --yes --no-wait"

echo ""
if [[ "$CONFIRM" == "true" ]]; then
  echo "Teardown complete. Resource group deletion runs in background."
else
  echo "No changes made. Run with --confirm to delete."
fi
