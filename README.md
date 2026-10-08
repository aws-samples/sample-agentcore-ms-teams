# Amazon Bedrock AgentCore × Microsoft Teams

A set of demos integrating **Amazon Bedrock AgentCore** agents with **Microsoft
Teams** via **Microsoft Entra ID**, on a Azure subscription + M365
tenant. Each demo is self-contained in its own top-level folder.

## Production Readiness Disclaimer

> **This sample is provided for demonstration and educational purposes only and is not intended for production use without additional security review and testing.**

## Prerequisites

- Azure CLI (`az login`), AWS CLI v2, Node 18+/20, Python 3.10+, AgentCore starter toolkit (`pip install bedrock-agentcore-starter-toolkit==0.3.14`, provides the `agentcore` CLI the scripts use)
- M365 tenant with Teams; Bedrock model access (Claude Sonnet) in `us-east-1`

## Demos

| Folder | What it shows | Auth model | Status |
|--------|---------------|-----------|--------|
| [`conversational/`](conversational/) | Teams bot → AgentCore agent (chat) + proactive notifications. Two infra variants: `infra/` (client-secret) and `infra-managed-identity/` (no secret for the cross-cloud call). | Bot app token → AgentCore (JWT) | Working |
| [`obo/`](obo/) | **On-Behalf-Of** user identity passthrough. Teams SSO → bot gets the user's Graph token → agent calls Graph **as the user** (reads their email/calendar). | teams-ai SSO + delegated Graph | Working |
| [`notify/`](notify/) | Agent that sends a proactive Adaptive Card to **any user or channel** (auto-installs the bot via Graph). | **IAM/SigV4** (simplest demo) | Working |
| [`meetings/`](meetings/) | In-meeting **side-panel** assistant + post-meeting transcript summarizer. First demo to use **AgentCore Memory** (save + semantic recall). | Tab SSO → OBO → delegated Graph | Working |

## Per-demo layout

```
<demo>/
├── agent/    Python AgentCore agent (Strands + Bedrock)   [conversational uses agent/teamsagent/]
├── bot/      TypeScript Teams bot (Bot Framework)          [meetings uses app/ — a side-panel tab]
├── infra/    deploy scripts + ARCHITECTURE-*.md
└── .env      live resource IDs + secrets (gitignored)
```

## Architecture docs

- `conversational/ARCHITECTURE.md`
- `obo/infra/ARCHITECTURE-OBO.md`
- `notify/infra/ARCHITECTURE-NOTIFY.md`
- `meetings/infra/ARCHITECTURE-MEETING.md`

## Common patterns / lessons (apply across demos)

- **Cross-cloud auth**: the Teams bot mints an Entra token; AgentCore Runtime
  validates it with a `customJWTAuthorizer` (Entra discovery URL + audience).
  No AWS credentials live in Azure.
- **User identity passthrough**: the user's Graph token is passed in the agent
  **payload** (`graph_token`); the agent calls Graph as the user. (AgentCore's
  built-in OBO exchange can't exchange an app-only token, so this pattern wins.)
- **`agentcore deploy` wipes the runtime authorizer** — re-apply it with
  `update-agent-runtime` after every deploy (the infra scripts do this).
- **Region**: agents run in `us-east-1` (notify uses IAM auth there too). Pin
  `AWS_REGION` to avoid drift to the machine's default profile region.
- **Managed Identity** (conversational `infra-managed-identity/`): the bot
  authenticates to AgentCore via a federated credential — no client secret for
  the cross-cloud call.



