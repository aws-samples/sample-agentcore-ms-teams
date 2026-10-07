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
# Teardown Azure Resources for AgentCore + Microsoft Teams Integration
#
# Removes:
#   - Container App and Environment
#   - Azure Container Registry
#   - Azure Bot resource
#   - Entra ID App Registrations (AgentCore-Teams-Bot, AgentCore-Outbound)
#   - Resource Group (all remaining resources)
#
# Usage:
#   ./teardown-azure.sh [--resource-group RG] [--confirm]
#
# Without --confirm, runs in dry-run mode showing what would be deleted.
# =============================================================================

# ---------- Defaults ----------
RESOURCE_GROUP="${RESOURCE_GROUP:-agentcore-msteams-rg}"
ACR_NAME="${ACR_NAME:-agentcoredemo2cr}"
BOT_NAME="${BOT_NAME:-agentcore-bot-demo}"
CONTAINER_APP_NAME="${CONTAINER_APP_NAME:-agentcore-teams-bot}"
CONTAINER_APP_ENV="${CONTAINER_APP_ENV:-agentcore-teams-env}"
CONFIRM=false

# ---------- Parse CLI Args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group) RESOURCE_GROUP="$2"; shift 2;;
    --acr-name) ACR_NAME="$2"; shift 2;;
    --bot-name) BOT_NAME="$2"; shift 2;;
    --confirm) CONFIRM=true; shift;;
    --help) echo "Usage: $0 [--resource-group RG] [--confirm]"; exit 0;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

echo "============================================================"
echo " AgentCore + Teams - Azure Teardown"
echo "============================================================"
echo ""
echo " Resource Group:    $RESOURCE_GROUP"
echo " ACR:               $ACR_NAME"
echo " Bot:               $BOT_NAME"
echo " Container App:     $CONTAINER_APP_NAME"
echo ""

if [[ "$CONFIRM" != "true" ]]; then
  echo " *** DRY RUN MODE ***"
  echo " Add --confirm to actually delete resources."
  echo ""
fi

# =============================================================================
# Step 1: Delete Container App
# =============================================================================
echo "--- Step 1: Container App ---"
if az containerapp show --resource-group "$RESOURCE_GROUP" --name "$CONTAINER_APP_NAME" &>/dev/null; then
  echo "  Found: $CONTAINER_APP_NAME"
  if [[ "$CONFIRM" == "true" ]]; then
    az containerapp delete --resource-group "$RESOURCE_GROUP" --name "$CONTAINER_APP_NAME" --yes -o none
    echo "  DELETED: $CONTAINER_APP_NAME"
  else
    echo "  Would delete: $CONTAINER_APP_NAME"
  fi
else
  echo "  Not found: $CONTAINER_APP_NAME (skipping)"
fi

# =============================================================================
# Step 2: Delete Container Apps Environment
# =============================================================================
echo ""
echo "--- Step 2: Container Apps Environment ---"
if az containerapp env show --resource-group "$RESOURCE_GROUP" --name "$CONTAINER_APP_ENV" &>/dev/null; then
  echo "  Found: $CONTAINER_APP_ENV"
  if [[ "$CONFIRM" == "true" ]]; then
    az containerapp env delete --resource-group "$RESOURCE_GROUP" --name "$CONTAINER_APP_ENV" --yes -o none
    echo "  DELETED: $CONTAINER_APP_ENV"
  else
    echo "  Would delete: $CONTAINER_APP_ENV"
  fi
else
  echo "  Not found: $CONTAINER_APP_ENV (skipping)"
fi

# =============================================================================
# Step 3: Delete Azure Container Registry
# =============================================================================
echo ""
echo "--- Step 3: Azure Container Registry ---"
if az acr show --name "$ACR_NAME" &>/dev/null; then
  echo "  Found: $ACR_NAME"
  if [[ "$CONFIRM" == "true" ]]; then
    az acr delete --name "$ACR_NAME" --yes -o none
    echo "  DELETED: $ACR_NAME"
  else
    echo "  Would delete: $ACR_NAME"
  fi
else
  echo "  Not found: $ACR_NAME (skipping)"
fi

# =============================================================================
# Step 4: Delete Azure Bot
# =============================================================================
echo ""
echo "--- Step 4: Azure Bot ---"
if az bot show --resource-group "$RESOURCE_GROUP" --name "$BOT_NAME" &>/dev/null; then
  echo "  Found: $BOT_NAME"
  if [[ "$CONFIRM" == "true" ]]; then
    az bot delete --resource-group "$RESOURCE_GROUP" --name "$BOT_NAME" --yes -o none 2>/dev/null || \
      az resource delete --resource-group "$RESOURCE_GROUP" --name "$BOT_NAME" --resource-type "Microsoft.BotService/botServices" -o none
    echo "  DELETED: $BOT_NAME"
  else
    echo "  Would delete: $BOT_NAME"
  fi
else
  echo "  Not found: $BOT_NAME (skipping)"
fi

# =============================================================================
# Step 5: Delete Entra ID App Registrations
# =============================================================================
echo ""
echo "--- Step 5: Entra ID App Registrations ---"

# Find and delete AgentCore-Teams-Bot
BOT_APP_OBJECT_ID=$(az ad app list --display-name "AgentCore-Teams-Bot" --query "[0].id" -o tsv 2>/dev/null || echo "")
if [[ -n "$BOT_APP_OBJECT_ID" ]]; then
  BOT_APP_CLIENT_ID=$(az ad app list --display-name "AgentCore-Teams-Bot" --query "[0].appId" -o tsv 2>/dev/null)
  echo "  Found: AgentCore-Teams-Bot (appId: $BOT_APP_CLIENT_ID)"
  if [[ "$CONFIRM" == "true" ]]; then
    # Delete service principal first
    az ad sp delete --id "$BOT_APP_CLIENT_ID" 2>/dev/null || true
    # Delete app registration
    az ad app delete --id "$BOT_APP_OBJECT_ID"
    echo "  DELETED: AgentCore-Teams-Bot"
  else
    echo "  Would delete: AgentCore-Teams-Bot ($BOT_APP_CLIENT_ID)"
  fi
else
  echo "  Not found: AgentCore-Teams-Bot (skipping)"
fi

# Find and delete AgentCore-Outbound
OUTBOUND_APP_OBJECT_ID=$(az ad app list --display-name "AgentCore-Outbound" --query "[0].id" -o tsv 2>/dev/null || echo "")
if [[ -n "$OUTBOUND_APP_OBJECT_ID" ]]; then
  OUTBOUND_APP_CLIENT_ID=$(az ad app list --display-name "AgentCore-Outbound" --query "[0].appId" -o tsv 2>/dev/null)
  echo "  Found: AgentCore-Outbound (appId: $OUTBOUND_APP_CLIENT_ID)"
  if [[ "$CONFIRM" == "true" ]]; then
    az ad sp delete --id "$OUTBOUND_APP_CLIENT_ID" 2>/dev/null || true
    az ad app delete --id "$OUTBOUND_APP_OBJECT_ID"
    echo "  DELETED: AgentCore-Outbound"
  else
    echo "  Would delete: AgentCore-Outbound ($OUTBOUND_APP_CLIENT_ID)"
  fi
else
  echo "  Not found: AgentCore-Outbound (skipping)"
fi

# =============================================================================
# Step 6: Delete Resource Group (all remaining resources)
# =============================================================================
echo ""
echo "--- Step 6: Resource Group ---"
if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
  echo "  Found: $RESOURCE_GROUP"
  RESOURCE_COUNT=$(az resource list --resource-group "$RESOURCE_GROUP" --query "length(@)" -o tsv 2>/dev/null || echo "0")
  echo "  Remaining resources in group: $RESOURCE_COUNT"
  if [[ "$CONFIRM" == "true" ]]; then
    echo "  Deleting resource group (this may take a few minutes)..."
    az group delete --name "$RESOURCE_GROUP" --yes --no-wait -o none
    echo "  DELETED: $RESOURCE_GROUP (deletion in progress)"
  else
    echo "  Would delete: $RESOURCE_GROUP (and $RESOURCE_COUNT remaining resources)"
  fi
else
  echo "  Not found: $RESOURCE_GROUP (skipping)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================================"
if [[ "$CONFIRM" == "true" ]]; then
  echo " TEARDOWN COMPLETE"
  echo ""
  echo " All Azure resources have been deleted or are being deleted."
  echo " Note: Resource group deletion is async and may take minutes."
  echo ""
  echo " Remember to also run teardown-aws.sh for AWS resources."
else
  echo " DRY RUN COMPLETE"
  echo ""
  echo " No resources were deleted."
  echo " Run with --confirm to perform the actual teardown:"
  echo "   ./teardown-azure.sh --confirm"
fi
echo "============================================================"
