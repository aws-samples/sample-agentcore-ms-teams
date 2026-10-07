# Architecture v2: AgentCore + Teams (Managed Identity)

## Overview

Amazon Bedrock AgentCore agent integrated with Microsoft Teams using **zero cross-cloud secrets**:
- Azure → AWS: Managed Identity + Federated Credential → Entra JWT (no client secrets for outbound calls)
- AWS → Azure: AgentCore Identity token vault (secrets in Secrets Manager, not in code)

---

## Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                           MICROSOFT AZURE                                         │
│                                                                                  │
│  ┌────────────────────────────────────────────────────────────────────────────┐  │
│  │                        Microsoft Entra ID                                  │  │
│  │                    (example.onmicrosoft.com)                         │  │
│  │                                                                            │  │
│  │  ┌─────────────────────────┐    ┌──────────────────────────────────────┐  │  │
│  │  │ AgentCore-Teams-Bot     │    │ AgentCore-Outbound                   │  │  │
│  │  │                         │    │                                      │  │  │
│  │  │ • v2.0 tokens           │    │ • Graph API permissions             │  │  │
│  │  │ • API scope exposed     │    │ • Client secret in AgentCore        │  │  │
│  │  │ • Federated Credential: │    │   Identity token vault              │  │  │
│  │  │   MI → App assertion    │    │ • Callback URL registered           │  │  │
│  │  └────────────┬────────────┘    └──────────────────────────────────────┘  │  │
│  └───────────────┼───────────────────────────────────────────────────────────┘  │
│                  │                                                                │
│                  │ Federated Identity Credential                                  │
│                  │ (MI gets token as the app, no secret needed)                   │
│                  │                                                                │
│  ┌───────────────┼───────────────────────────────────────────────────────────┐   │
│  │               ▼                                                            │   │
│  │  ┌──────────────────────────────────────────────────────────────────┐     │   │
│  │  │ User-Assigned Managed Identity (agentcore-bot-identity)          │     │   │
│  │  │ Client ID: 5f44a2fe-...                                          │     │   │
│  │  └──────────────────────┬───────────────────────────────────────────┘     │   │
│  │                         │                                                  │   │
│  │  ┌──────────────────────┼──────────────────────────────────────────────┐  │   │
│  │  │  Azure Container App │ (agentcore-teams-bot)                        │  │   │
│  │  │                      ▼                                              │  │   │
│  │  │  ┌──────────────────────────────────────────────────────────────┐  │  │   │
│  │  │  │  Teams Bot (Node.js / TypeScript)                            │  │  │   │
│  │  │  │                                                              │  │  │   │
│  │  │  │  POST /api/messages  ← Bot Framework (uses BOT_APP_SECRET)  │  │  │   │
│  │  │  │  POST /api/notify   ← AgentCore agent (NOTIFY_SECRET auth)  │  │  │   │
│  │  │  │                                                              │  │  │   │
│  │  │  │  Outbound to AgentCore:                                      │  │  │   │
│  │  │  │    ManagedIdentityCredential(MI_CLIENT_ID)                   │  │  │   │
│  │  │  │    → ClientAssertionCredential (federated exchange)          │  │  │   │
│  │  │  │    → Entra JWT for api://BOT_APP_ID/.default                 │  │  │   │
│  │  │  │    → Bearer token to AgentCore Runtime                       │  │  │   │
│  │  │  └──────────────────────────────────────────────────────────────┘  │  │   │
│  │  └────────────────────────────────────────────────────────────────────┘  │   │
│  │                                                                           │   │
│  │  Azure Container Apps Environment (westus2)                               │   │
│  └───────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
│  ┌────────────────────┐  ┌─────────────────────────────┐                        │
│  │ Azure Bot Service  │  │ Azure Container Registry    │                        │
│  │ (F0, SingleTenant) │  │ (agentcoredemo2cr)          │                        │
│  │ Teams channel on   │  │ teams-bot:latest            │                        │
│  └────────────────────┘  └─────────────────────────────┘                        │
└──────────────────────────────────────────────────────────────────────────────────┘
                          │
                          │ HTTPS + Bearer token (Entra JWT)
                          │ No AWS credentials anywhere in Azure
                          │
┌─────────────────────────┼────────────────────────────────────────────────────────┐
│                         ▼              AWS (us-east-1)                            │
│                                                                                  │
│  ┌───────────────────────────────────────────────────────────────────────────┐   │
│  │                  Amazon Bedrock AgentCore Runtime                          │   │
│  │                                                                           │   │
│  │  Agent: teamsagent_Agent-kTEzgu4Vzf                                      │   │
│  │  Protocol: HTTP                                                           │   │
│  │  Auth: customJWTAuthorizer                                                │   │
│  │    • discoveryUrl: login.microsoftonline.com/{tenant}/v2.0/...           │   │
│  │    • allowedAudience: [BOT_APP_ID]                                       │   │
│  │                                                                           │   │
│  │  ┌─────────────────────────────────────────────────────────────────────┐  │   │
│  │  │  Python Agent (Strands SDK)                                         │  │   │
│  │  │  Model: Claude Sonnet 4.6                                           │  │   │
│  │  │                                                                     │  │   │
│  │  │  Tools:                                                             │  │   │
│  │  │    send_teams_notification(title, msg) → POST bot /api/notify       │  │   │
│  │  │    get_agent_status() → agent metadata                              │  │   │
│  │  │                                                                     │  │   │
│  │  │  Env vars (no secrets):                                             │  │   │
│  │  │    TEAMS_BOT_NOTIFY_URL, NOTIFY_SECRET                              │  │   │
│  │  └─────────────────────────────────────────────────────────────────────┘  │   │
│  └───────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
│  ┌───────────────────────────────────────────────────────────────────────────┐   │
│  │  AgentCore Identity (Token Vault)                                         │   │
│  │                                                                           │   │
│  │  Credential Provider: microsoft-entra-outbound (MicrosoftOauth2)         │   │
│  │  • Client secret stored in AWS Secrets Manager                            │   │
│  │  • Callback URL registered in Entra                                       │   │
│  │  • Agent gets tokens at runtime via GetWorkloadAccessToken                │   │
│  └───────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
│  ┌───────────────────────────────────────────────────────────────────────────┐   │
│  │  AgentCore MCP Gateway                                                    │   │
│  │  Auth: Same Entra JWT (for MCP clients like Cursor / Claude Code)         │   │
│  └───────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
│  ┌────────────────────────┐  ┌────────────────────────────────────────────┐      │
│  │  IAM Roles             │  │  Amazon Bedrock (Claude Sonnet 4.6)        │      │
│  │  • AgentCoreTeams...   │  │  us.anthropic.claude-sonnet-4-6            │      │
│  │  • AgentCoreGateway... │  └────────────────────────────────────────────┘      │
│  └────────────────────────┘                                                      │
└──────────────────────────────────────────────────────────────────────────────────┘
```

---

## Authentication Flows

### Flow 1: Teams User → AgentCore (Conversational)

```
User sends message in Teams
  → Bot Framework delivers to /api/messages (validated via BOT_APP_SECRET)
  → Bot acquires Entra JWT:
      ManagedIdentityCredential(MI_CLIENT_ID)
        → gets MI token for audience "api://AzureADTokenExchange"
      ClientAssertionCredential(tenant, BOT_APP_ID, assertion=MI_token)
        → exchanges MI token for app token scoped to api://BOT_APP_ID/.default
  → Bot calls AgentCore Runtime with Bearer token:
      POST https://bedrock-agentcore.us-east-1.amazonaws.com/runtimes/{id}/invocations
      Authorization: Bearer <entra-jwt>
  → AgentCore validates JWT (issuer, signature, audience, expiry)
  → Agent processes with Claude → streams response
  → Bot returns Adaptive Card to Teams
```

### Flow 2: AgentCore Agent → Teams (Notifications)

```
Agent decides to send notification
  → Agent calls send_teams_notification tool
  → Tool POSTs to bot's /api/notify:
      POST https://{bot-fqdn}/api/notify
      Authorization: Bearer <NOTIFY_SECRET>
      Body: {"title": "...", "message": "..."}
  → Bot validates NOTIFY_SECRET
  → Bot uses continueConversationAsync (Bot Framework proactive messaging)
  → Adaptive Card appears in Teams channel
```

### Flow 3: MCP Clients → AgentCore (via Gateway)

```
MCP client (Cursor, Claude Code) connects to Gateway URL
  → Client acquires Entra token (interactive or device code flow)
  → Client sends MCP requests with Bearer token
  → Gateway validates JWT (same Entra config)
  → Gateway forwards to Runtime agent
```

---

## Secrets Inventory

| Secret | Location | Purpose | Eliminable? |
|--------|----------|---------|-------------|
| `BOT_APP_SECRET` | Container App env var | Bot Framework SDK v4 inbound token validation | No (SDK limitation, fixed in v5) |
| `NOTIFY_SECRET` | Container App env var + Agent env var | Protect /api/notify from unauthorized calls | Could use Entra token instead |
| Outbound client secret | AgentCore Identity token vault (Secrets Manager) | Agent gets Graph API tokens | Managed by AWS, not in code |

### What's NOT a secret anymore

| Was | Now |
|-----|-----|
| Client secret for Bot → AgentCore calls | Managed Identity + Federated Credential |
| OUTBOUND_APP_SECRET in agent env vars | AgentCore Identity token vault |

---

## Deployment

```bash
# 1. Deploy Azure (creates MI, apps, bot, container)
./deploy-azure.sh --tenant-id <TENANT_ID> --region westus2

# 2. Deploy AWS (creates roles, runtime, gateway, identity provider)
./deploy-aws.sh --region us-east-1

# 3. Sideload Teams app
# Upload teams-bot/appPackage.zip in Teams

# Teardown (dry run first)
./teardown-azure.sh
./teardown-aws.sh
./teardown-azure.sh --confirm
./teardown-aws.sh --confirm
```

---

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Azure CLI | 2.50+ | Azure resource management |
| AWS CLI | 2.x | AWS resource management |
| Node.js | 20+ | Teams bot runtime |
| Python | 3.12+ | AgentCore agent |
| agentcore CLI | latest | Agent deployment |
| jq | any | JSON parsing in scripts |

| Service | Requirement |
|---------|-------------|
| Azure subscription | Pay-As-You-Go or free trial |
| M365 license | Business Basic+ (with Teams service plan) |
| AWS account | Bedrock AgentCore access enabled |
| Bedrock model | Claude Sonnet 4.6 enabled in us-east-1 |
