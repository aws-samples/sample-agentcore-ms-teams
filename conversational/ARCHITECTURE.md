# Architecture: Amazon Bedrock AgentCore + Microsoft Teams Integration

## Overview

This project connects a Microsoft Teams bot to an AI agent running on Amazon Bedrock AgentCore. The integration enables two primary workflows:

1. **Conversational AI** - Users message the bot in Teams, which invokes the AgentCore agent and returns AI responses.
2. **Proactive Notifications** - The AgentCore agent pushes Adaptive Card notifications to Teams channels.

Authentication between Azure and AWS uses Microsoft Entra ID JWT tokens exclusively -- no AWS credentials are stored in Azure.

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              MICROSOFT AZURE (westus2)                               │
│                                                                                     │
│  ┌─────────────────────┐         ┌─────────────────────────────────────────────┐    │
│  │   Microsoft Entra   │         │        Azure Container Apps                  │    │
│  │   (Tenant: agentc-  │  Token  │  ┌───────────────────────────────────────┐  │    │
│  │    oredemo.onmicro-  │◄────────│  │         Teams Bot (Node.js)           │  │    │
│  │    soft.com)         │         │  │                                       │  │    │
│  │                      │         │  │  POST /api/messages ← Bot Framework   │  │    │
│  │  App Registrations:  │         │  │  POST /api/notify  ← AgentCore Agent  │  │    │
│  │  ┌────────────────┐  │         │  │  GET  /api/conversations              │  │    │
│  │  │AgentCore-Teams-│  │         │  └──────────────┬────────────────────────┘  │    │
│  │  │Bot (inbound)   │  │         └─────────────────┼───────────────────────────┘    │
│  │  └────────────────┘  │                           │                                │
│  │  ┌────────────────┐  │                           │ Entra JWT Bearer Token         │
│  │  │AgentCore-      │  │                           │ (scope: api://BOT_APP_ID/      │
│  │  │Outbound (Graph)│  │                           │         .default)              │
│  │  └────────────────┘  │                           │                                │
│  └─────────────────────┘                           │                                │
│                                                     │                                │
│  ┌─────────────────────┐                           │                                │
│  │    Azure Bot Svc    │                            │                                │
│  │  (agentcore-bot-    │                            │                                │
│  │   demo, F0 tier)    │                            │                                │
│  │   Teams Channel     │                            │                                │
│  └─────────────────────┘                            │                                │
└─────────────────────────────────────────────────────┼────────────────────────────────┘
                                                      │
                                                      │ HTTPS (JWT in Authorization header)
                                                      │
┌─────────────────────────────────────────────────────┼────────────────────────────────┐
│                               AWS (us-east-1)       │                                │
│                                                     ▼                                │
│  ┌───────────────────────────────────────────────────────────────────────────────┐   │
│  │                     Amazon Bedrock AgentCore Runtime                           │   │
│  │                                                                               │   │
│  │  Agent: teamsagent_Agent-kTEzgu4Vzf                                          │   │
│  │  Protocol: HTTP | Auth: customJWTAuthorizer (Entra discovery URL)            │   │
│  │                                                                               │   │
│  │  ┌─────────────────────────────────────────────────────────────────────────┐  │   │
│  │  │  Python Agent (Strands SDK + Bedrock)                                   │  │   │
│  │  │                                                                         │  │   │
│  │  │  Model: Claude Sonnet 4.6 (us.anthropic.claude-sonnet-4-6)             │  │   │
│  │  │                                                                         │  │   │
│  │  │  Tools:                                                                 │  │   │
│  │  │    - send_teams_notification(title, message) → POST /api/notify         │  │   │
│  │  │    - get_agent_status() → returns agent metadata                        │  │   │
│  │  └─────────────────────────────────────────────────────────────────────────┘  │   │
│  └───────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                      │
│  ┌───────────────────────────────────────────────────────────────────────────────┐   │
│  │                     AgentCore MCP Gateway                                     │   │
│  │                                                                               │   │
│  │  Gateway: teamsagentgateway-pki6mbrtk3                                       │   │
│  │  URL: https://teamsagentgateway-pki6mbrtk3.gateway.bedrock-agentcore.        │   │
│  │       us-east-1.amazonaws.com/mcp                                            │   │
│  │  Auth: Entra JWT (same discovery URL + audience)                             │   │
│  │  Protocol: MCP (Model Context Protocol)                                      │   │
│  │                                                                               │   │
│  │  Used by: Cursor, Claude Code, other MCP clients                             │   │
│  └───────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                      │
│  ┌───────────────────────┐  ┌────────────────────────────────────────────────────┐   │
│  │  IAM Roles            │  │  Amazon Bedrock (Foundation Models)                 │   │
│  │                       │  │                                                    │   │
│  │  AgentCoreTeamsAgent- │  │  anthropic.claude-sonnet-4-6                       │   │
│  │  Role (execution)     │  │  (InvokeModel / InvokeModelWithResponseStream)     │   │
│  │                       │  │                                                    │   │
│  │  AgentCoreGatewayRole │  └────────────────────────────────────────────────────┘   │
│  │  (gateway invoke)     │                                                           │
│  └───────────────────────┘                                                           │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Component Details

| Component | Location | Technology | Purpose |
|-----------|----------|------------|---------|
| Teams Bot | Azure Container Apps (westus2) | TypeScript, Node.js, Bot Framework SDK | Receives Teams messages, invokes AgentCore, sends proactive notifications |
| Azure Bot Service | Azure (agentcore-bot-demo) | Bot Framework, F0 tier, SingleTenant | Routes Teams channel messages to the bot container |
| AgentCore-Teams-Bot App | Entra ID | App Registration | Bot identity + JWT issuer for AgentCore inbound auth |
| AgentCore-Outbound App | Entra ID | App Registration | Graph API permissions for outbound notifications |
| AgentCore Runtime | AWS us-east-1 | Bedrock AgentCore, Python | Hosts the AI agent, validates inbound JWT, streams responses |
| AgentCore Agent | AgentCore Runtime | Python, Strands SDK | AI logic: processes messages, invokes tools, calls Bedrock models |
| AgentCore MCP Gateway | AWS us-east-1 | Bedrock AgentCore Gateway | Exposes agent via MCP protocol for IDE clients (Cursor, Claude Code) |
| Azure Container Registry | Azure (agentcoredemo2cr) | ACR | Stores the Teams bot Docker image |

---

## Authentication Flows

### Inbound: Teams to AgentCore (User Chat)

```
Teams User ─── message ───► Azure Bot Service
                                    │
                                    ▼
                            Teams Bot Container
                                    │
                            ┌───────┴───────┐
                            │ MSAL Client   │
                            │ Credentials   │
                            │               │
                            │ client_id:    │
                            │  BOT_APP_ID   │
                            │ client_secret:│
                            │  BOT_APP_SEC  │
                            │ scope:        │
                            │  api://BOT_   │
                            │  APP_ID/      │
                            │  .default     │
                            └───────┬───────┘
                                    │
                            Entra v2.0 token endpoint
                                    │
                                    ▼
                            JWT Access Token
                                    │
                            Authorization: Bearer <token>
                                    │
                                    ▼
                    AgentCore Runtime (customJWTAuthorizer)
                                    │
                            ┌───────┴───────┐
                            │ Validates:    │
                            │  - Signature  │
                            │    (via JWKS) │
                            │  - Issuer     │
                            │  - Audience   │
                            │  - Expiry     │
                            └───────┬───────┘
                                    │
                                    ▼
                            Agent processes message
                            Returns streamed response
```

**Key points:**
- Bot acquires token using client credentials grant (no user interaction)
- Token audience is `api://BOT_APP_ID` -- the exposed API on the bot app registration
- AgentCore validates the token using the Entra OpenID Connect discovery URL
- No AWS credentials leave the AWS boundary

### Outbound: AgentCore to Teams (Proactive Notifications)

```
Agent (in AgentCore Runtime)
        │
        │ send_teams_notification tool
        │
        ▼
POST https://<bot-fqdn>/api/notify
     Body: { "title": "...", "message": "..." }
        │
        ▼
Teams Bot /api/notify handler
        │
        │ adapter.continueConversationAsync()
        │ (uses stored ConversationReference)
        │
        ▼
Bot Framework ──► Teams Channel
                  (Adaptive Card)
```

**Key points:**
- Agent calls the bot's `/api/notify` endpoint directly via HTTP
- Bot uses proactive messaging (Bot Framework `continueConversationAsync`)
- Conversation references are stored in-memory when users first interact with the bot
- Notifications are rendered as Adaptive Cards with branding

---

## Data Flows

### Demo 1: Conversational AI (User-Initiated)

1. User sends `@AgentCore Bot <message>` in a Teams channel or DM
2. Azure Bot Service routes the activity to the container's `/api/messages` endpoint
3. `AgentCoreBot.onMessage` handler extracts the text
4. `AgentCoreClient.invokeAgent()` acquires an Entra JWT and calls the AgentCore Runtime invocation endpoint
5. AgentCore Runtime validates the JWT, then invokes the agent
6. The Strands Agent processes the message using Claude Sonnet 4.6 via Bedrock
7. Response streams back as SSE events
8. Bot assembles the response into an Adaptive Card and sends it to the Teams conversation

### Demo 2: Proactive Notifications (Agent-Initiated)

1. External trigger or agent tool call decides to notify Teams
2. Agent's `send_teams_notification` tool sends HTTP POST to the bot's `/api/notify`
3. Bot looks up a stored `ConversationReference` (channel preferred)
4. Bot calls `continueConversationAsync` with an Adaptive Card payload
5. Teams renders the notification card in the target channel

### Demo 3: MCP Client Access (Developer Tools)

1. Developer configures MCP client (Cursor, Claude Code) with the Gateway URL
2. Client acquires an Entra JWT (same audience/scope as the bot)
3. Client sends MCP protocol requests to the Gateway
4. Gateway validates JWT, routes to the agent runtime
5. Agent processes and returns results via MCP protocol

---

## Directory Structure

```
agentcore-msteams/
├── .env                          # Environment variables (gitignored)
├── .gitignore
├── ARCHITECTURE.md               # This file
├── infra/
│   ├── setup-entra-apps.sh       # Creates Entra app registrations only
│   ├── deploy-azure.sh           # Full Azure deployment (RG, Bot, ACR, Container Apps)
│   ├── deploy-aws.sh             # Full AWS deployment (IAM, AgentCore, Gateway)
│   ├── teardown-azure.sh         # Removes all Azure resources
│   └── teardown-aws.sh           # Removes all AWS resources
├── teams-bot/                    # TypeScript Teams bot
│   ├── src/
│   │   ├── index.ts              # Server setup, /api/messages + /api/notify endpoints
│   │   ├── bot.ts                # Bot logic, conversation reference tracking
│   │   └── agentcoreClient.ts    # MSAL token acquisition + AgentCore invocation
│   ├── appPackage/
│   │   └── manifest.json         # Teams app manifest
│   ├── Dockerfile
│   ├── package.json
│   └── tsconfig.json
└── agentcore-agent/              # Python AgentCore agent
    ├── teamsagent/
    │   ├── src/main.py           # BedrockAgentCoreApp entrypoint with tools
    │   ├── .bedrock_agentcore.yaml  # Agent deployment config
    │   ├── pyproject.toml
    │   └── cdk/                  # CDK infrastructure (optional)
    ├── src/
    │   ├── agent.py              # Strands agent with tools (alternate structure)
    │   ├── main.py               # RuntimeApp handler (alternate structure)
    │   └── teams_notify.py       # Graph API notification sender
    ├── Dockerfile
    └── requirements.txt
```

---

## Prerequisites

### Tools Required

| Tool | Version | Purpose |
|------|---------|---------|
| Azure CLI (`az`) | >= 2.50 | Azure resource provisioning |
| AWS CLI (`aws`) | >= 2.15 | AWS resource provisioning |
| `agentcore` CLI (`bedrock-agentcore-starter-toolkit`) | 0.3.14 | AgentCore agent deployment |
| Node.js | >= 20.x | Teams bot build |
| Python | >= 3.12 | AgentCore agent |
| Docker | >= 24.x | Container image build |
| `jq` | any | JSON parsing in scripts |

### Accounts and Access

- **Microsoft 365 tenant** with Teams enabled (developer or production)
- **Azure subscription** with permissions to create:
  - Resource Groups, Container Apps, ACR, Bot Service
  - Entra ID App Registrations (requires Application Administrator role)
  - Admin consent for Graph API permissions (requires Global Administrator)
- **AWS account** with permissions to:
  - Create IAM roles and policies
  - Use Amazon Bedrock AgentCore (create runtimes, gateways)
  - Invoke Bedrock foundation models (Claude)

### Model Access

- Amazon Bedrock model access must be enabled for `anthropic.claude-sonnet-4-6` in the target region (us-east-1)

---

## Security Considerations

### Cross-Cloud Authentication

- **No AWS credentials in Azure**: The only credential crossing the cloud boundary is a short-lived Entra JWT token (from Azure to AWS). AWS never stores Azure secrets.
- **No Azure secrets hardcoded**: Bot App Secret and Outbound App Secret are passed as environment variables to the container, never committed to source.
- **Token validation**: AgentCore Runtime validates JWTs using Entra's OIDC discovery endpoint (fetches signing keys dynamically).

### Token Security

- **Token version**: v2.0 (set via `requestedAccessTokenVersion: 2` on the app registration)
- **Audience restriction**: Tokens are scoped to `api://BOT_APP_ID` -- only the specific app can be the intended audience
- **Tenant restriction**: App registrations are single-tenant (`AzureADMyOrg`), preventing tokens from other tenants
- **Short-lived**: MSAL client credential tokens default to 1-hour expiry

### Network Security

- **Container Apps ingress**: External (required for Bot Framework callback), but only `/api/messages` is used by Bot Framework and `/api/notify` by the agent
- **AgentCore Runtime**: Protected by JWT authorizer; unauthenticated requests are rejected
- **Gateway**: Same JWT protection; only authenticated MCP clients can reach the agent

### Secret Management

- `.env` file is gitignored and contains all secrets
- In production, consider:
  - Azure Key Vault for bot secrets
  - AWS Secrets Manager / AgentCore Identity for agent-side secrets
  - Managed identities instead of client secrets where possible

### Least Privilege

- **AgentCoreTeamsAgentRole**: Only allows `bedrock:InvokeModel` on Anthropic models and CloudWatch Logs
- **AgentCoreGatewayRole**: Only allows `bedrock-agentcore:InvokeAgentRuntime`
- **AgentCore-Outbound**: Only has `ChannelMessage.Send`, `Chat.Create`, `TeamsActivity.Send` Graph permissions (application-level, admin consented)

---

## Environment Variables

| Variable | Used By | Description |
|----------|---------|-------------|
| `TENANT_ID` | Bot + Agent | Entra tenant ID |
| `BOT_APP_ID` | Bot | Bot app registration client ID |
| `BOT_APP_SECRET` | Bot | Bot app registration client secret |
| `BOT_API_SCOPE` | Reference | `api://BOT_APP_ID/Agent.Invoke` |
| `OUTBOUND_APP_ID` | Agent | Outbound app registration client ID |
| `OUTBOUND_APP_SECRET` | Agent | Outbound app registration client secret |
| `TEAMS_BOT_NOTIFY_URL` | Agent | Bot's `/api/notify` endpoint URL |
| `TEAMS_TEAM_ID` | Agent (optional) | Target team ID for Graph API notifications |
| `TEAMS_CHANNEL_ID` | Agent (optional) | Target channel ID for Graph API notifications |
| `DISCOVERY_URL` | Reference | Entra OIDC discovery URL for JWT validation |
| `AWS_REGION` | Reference | AWS region (us-east-1) |

---

## Deployment Order

1. **Azure: Entra ID** -- Create app registrations (or run `setup-entra-apps.sh`)
2. **Azure: Infrastructure** -- Resource group, ACR, Container Apps, Bot (`deploy-azure.sh`)
3. **AWS: Infrastructure** -- IAM roles, AgentCore Runtime, Gateway (`deploy-aws.sh`)
4. **Teams: App Package** -- Upload `appPackage.zip` to Teams Admin Center
5. **Test: Conversational** -- Message the bot in Teams
6. **Test: Notifications** -- Trigger agent notification tool
7. **Test: MCP** -- Connect Claude Code or Cursor to the Gateway URL
