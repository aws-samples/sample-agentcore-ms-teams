# Getting Started — Deploy All 4 Demos from Scratch

This guide takes a brand-new person from zero to all four working demos:

1. **conversational** — Teams bot ⇄ AgentCore agent + notifications (Managed-Identity variant)
2. **obo** — On-Behalf-Of: agent acts as the signed-in user (their email/calendar)
3. **notify** — agent notifies any user or channel
4. **meetings** — in-meeting side panel + transcript summarizer + AgentCore Memory

Every demo is self-contained under its own folder (`conversational/`, `obo/`,
`notify/`, `meetings/`). You can deploy them independently and in any order.

> **Cost note:** everything uses free/consumption tiers (Bot F0, Container Apps
> consumption, AgentCore pay-per-use, Bedrock pay-per-token). Expect a few
> dollars for light testing.

> **Data protection note:** these demos process personal data — Teams messages,
> user email, calendar, and meeting transcripts. Under the AWS shared
> responsibility model, you are responsible for meeting applicable data-protection
> requirements (e.g., GDPR and local privacy laws) before deploying to production.
> See https://aws.amazon.com/compliance/shared-responsibility-model/

---

## Part 0 — Prerequisites

### 0.1 Accounts

| Need | Notes |
|------|-------|
| **Microsoft 365 tenant with Teams** | A Business Basic trial works. **A personal `@outlook.com` tenant will NOT get an M365 Business license** — create the tenant with a work/Gmail email or use an M365 dev tenant. You must be a **tenant admin**. |
| **Azure subscription** | Pay-As-You-Go is fine. Ideally in the **same Entra tenant** as M365 (avoids cross-tenant pain). |
| **AWS account** | With **Amazon Bedrock AgentCore** access and **Claude Sonnet** model access enabled in **us-east-1**. |

### 0.2 Local tools

```bash
# macOS (Homebrew)
brew install azure-cli awscli node python@3.12 jq
brew install --cask ...        # nothing extra needed

# AgentCore starter toolkit (provides the `agentcore` command the deploy scripts use)
pip install bedrock-agentcore-starter-toolkit==0.3.14
# NOTE: the newer npm-based AgentCore CLI (@aws/agentcore) uses different
# commands (no `agentcore configure`) and is NOT compatible with these scripts.
# If both are installed, make sure `which agentcore` resolves to the pip one.

# Verify
az version
aws --version          # v2.x
node --version         # 18 or 20 (20 recommended; Node 22 has a Bot Framework bug)
python3 --version      # 3.10+
agentcore --help
jq --version
```

### 0.3 Enable Teams custom-app upload (one-time, as tenant admin)

1. Go to **https://admin.teams.microsoft.com** → **Teams apps → Setup policies → Global**
2. Turn **"Upload custom apps"** **On** → **Save** (can take a few minutes to propagate)

### 0.4 Log in to both clouds

```bash
# Azure — log in to the tenant where Teams lives
az login --tenant <YOUR_TENANT_ID>
az account show    # confirm the right subscription + tenant

# AWS — configure default region to us-east-1 to avoid region drift
aws configure set region us-east-1
aws sts get-caller-identity    # confirm account
```

> **Region tip:** if your AWS profile default is anything other than `us-east-1`,
> the `agentcore` CLI can deploy to the wrong region. Either set it as above or
> `export AWS_REGION=us-east-1` in your shell before running the scripts.

### 0.5 Enable Bedrock model access (one-time)

In the AWS console → **Bedrock → Model access** (us-east-1), request/enable
**Anthropic Claude Sonnet** (the agents use `us.anthropic.claude-sonnet-4-6`).

### 0.6 Get the code

```bash
cd ~/code   # or wherever
# (clone / copy this repo)
cd agentcore-msteams
```

Each demo writes its live resource IDs + secrets to `<demo>/.env` (gitignored).

### 0.7 Teams app packages & placeholders

This repo ships **no real tenant/account identifiers**. Wherever you see a
placeholder GUID (`00000000-…`, `11111111-…`, `22222222-…`), a placeholder
domain (`YOUR-ENV.REGION.azurecontainerapps.io`), or a placeholder email
(`jane@example.com`), substitute your own value.

How the Teams app package (`<demo>/**/appPackage.zip`) gets its real values:

- **notify, obo, meetings** — the `deploy-azure-*.sh` script **generates
  `manifest.json` and rebuilds `appPackage.zip`** with your freshly-created
  app/bot IDs and Container App FQDN. Nothing to edit by hand; the generated
  `manifest.json` and `appPackage.zip` are gitignored so real IDs never get
  committed.
- **conversational** — `conversational/bot/appPackage/manifest.json` is a
  **static template with placeholders**. After `deploy-azure.sh` prints your
  Bot App ID and Container App FQDN, edit that manifest and replace `id`,
  `botId`, and `validDomains` with your values, then zip the package:
  ```bash
  cd conversational/bot/appPackage
  zip -r ../appPackage.zip manifest.json color.png outline.png
  ```
  Upload the resulting `conversational/bot/appPackage.zip`.

---

## Part 1 — Conversational bot (Managed-Identity variant)

The conversational demo has two infra variants. **This guide uses the
Managed-Identity (v2) one** in `conversational/infra-managed-identity/`, which
avoids storing a client secret for the cross-cloud call.

The Azure script here **creates the Entra apps itself** (no separate setup step).

```bash
cd conversational/infra-managed-identity

# 1. Azure: resource group, Managed Identity, Entra apps (Bot + Outbound),
#    federated credential, Azure Bot (UserAssignedMSI), ACR, Container App,
#    Teams app package.
./deploy-azure.sh --tenant-id <YOUR_TENANT_ID> --region westus2

# 2. AWS: IAM execution role, deploy the agent to AgentCore Runtime,
#    apply the Entra JWT authorizer, create the AgentCore Identity outbound
#    credential provider (for notifications), register its callback URL.
./deploy-aws.sh --region us-east-1
```

Then, in **Microsoft Teams**:
- **Apps → Manage your apps → Upload a custom app** → select
  `conversational/bot/appPackage.zip`
- Open a 1:1 chat with the bot and say `hi` — it should reply via the AgentCore agent.

**Notifications**: the agent can push an Adaptive Card to a channel where the
bot is installed. Add the app to a team, message it once so it records the
conversation, then the agent's notification tool can post there.

<details>
<summary>What got created (Azure + AWS)</summary>

- Entra: `AgentCore-Teams-Bot` (bot identity + federated cred), `AgentCore-Outbound` (Graph)
- Azure: Managed Identity `agentcore-bot-identity`, Bot `agentcore-bot-demo` (UserAssignedMSI), Container App `agentcore-teams-bot`, ACR
- AWS: role `AgentCoreTeamsAgentRole`, runtime `teamsagent_Agent-*`, Identity provider `microsoft-graph` (outbound)
</details>

---

## Part 2 — OBO (act as the signed-in user)

Three steps: Entra app → AWS agent → Azure bot. The bot uses **teams-ai** for
silent SSO and does the OBO exchange to get the user's Microsoft Graph token.

```bash
cd obo/infra

# 1. Entra: bot app (multi-tenant audience, SSO scope, delegated Graph perms:
#    User.Read, Mail.Read, Calendars.Read + admin consent), client secret.
./setup-entra-obo.sh --tenant-id <YOUR_TENANT_ID>

# 2. AWS: role, deploy agent, apply Entra JWT authorizer (accepts the USER token).
./deploy-aws-obo.sh --region us-east-1

# 3. Azure: Managed Identity + federated cred, Azure Bot (UserAssignedMSI),
#    Container App, Teams package. Prints the bot FQDN.
./deploy-azure-obo.sh --region westus2
```

Then in **Teams**:
- **Upload a custom app** → `obo/bot/appPackage.zip`
- Message the bot `whoami`. On first use it does a silent SSO; you may see
  **"Signed in!"** — send `whoami` again and it returns **your** name/email,
  pulled from Graph using your delegated identity. Try `show my emails`.

> **Key facts baked into the scripts:** the bot app is `AzureADMultipleOrgs`
> (required for the Teams OAuth flow), the Azure Bot is `UserAssignedMSI`, and
> the SDK config is `SingleTenant`. These are intentionally different — don't
> "fix" them to match.

---

## Part 3 — Notify any user or channel

The simplest demo to invoke: the agent uses **IAM auth**, so `agentcore invoke`
works directly (no token minting).

```bash
cd notify/infra

# 1. Entra: bot app with APPLICATION Graph perms (install app for users/teams,
#    read users/teams/channels, TeamsActivity.Send) + admin consent + secret +
#    identifier URI.
./setup-entra-notify.sh --tenant-id <YOUR_TENANT_ID>

# 2. Azure: Azure Bot, Container App, Teams package.
./deploy-azure-notify.sh --region westus2

# >>> IMPORTANT MANUAL STEP <<<
#   Upload notify/bot/appPackage.zip to the Teams ADMIN CENTER catalog:
#   admin.teams.microsoft.com → Teams apps → Manage apps → Upload new app.
#   (Proactive install requires the app to be in the org catalog — sideloading
#    to one chat is NOT enough.)

# 3. AWS: role + deploy agent with IAM auth (no JWT authorizer) + env vars.
./deploy-aws-notify.sh --region us-east-1
```

Test (one command — IAM auth):

```bash
cd ../agent    # notify/agent
agentcore invoke '{"prompt": "notify <you>@<tenant>.onmicrosoft.com that the build passed"}'
agentcore invoke '{"prompt": "notify <Team Name> / General that deployment is complete"}'
```

The bot auto-installs itself for the target and delivers an Adaptive Card.

---

## Part 4 — Meetings assistant (side panel + AgentCore Memory)

This demo has **no Azure Bot** — the side panel is a hosted web tab. It also
creates an **AgentCore Memory** resource (the only demo that uses memory).

```bash
cd meetings/infra

# 1. Entra: app with delegated Graph (User.Read, OnlineMeetings.Read,
#    OnlineMeetingTranscript.Read.All), SSO scope, consent, secret.
./setup-entra-meeting.sh --tenant-id <YOUR_TENANT_ID>

# 2. AWS: role, AgentCore MEMORY resource (semantic strategy), deploy agent,
#    apply Entra JWT authorizer + MEMORY_ID env.
./deploy-aws-meeting.sh --region us-east-1

# 3. Azure: Container App (serves the side-panel tab + OBO proxy),
#    SPA redirect URI, Teams package (configurableTabs / meetingSidePanel).
./deploy-azure-meeting.sh --region westus2
```

Then in **Teams**:
- **Upload a custom app** → `meetings/app/appPackage.zip`
- Start/join a meeting → **+ (Add an app)** → add **AgentCore Meeting** → open
  the side panel. It silently signs you in.
- Try: `save this note: we shipped the demo` → then in a later turn
  `what did I save?`. Long-term recall works after semantic extraction
  (a few minutes).
- **Transcripts** require: meeting **transcription was ON**, you are the
  **organizer**, and the meeting has **ended** (~5–10 min for the transcript to
  appear). Then: `summarize this meeting`.

---

## Deployment order cheat-sheet

| Demo | 1 | 2 | 3 | Manual Teams step |
|------|---|---|---|-------------------|
| conversational (MI) | `deploy-azure.sh` (creates Entra too) | `deploy-aws.sh` | — | Upload custom app |
| obo | `setup-entra-obo.sh` | `deploy-aws-obo.sh` | `deploy-azure-obo.sh` | Upload custom app |
| notify | `setup-entra-notify.sh` | `deploy-azure-notify.sh` | `deploy-aws-notify.sh` | **Admin-center** catalog upload |
| meetings | `setup-entra-meeting.sh` | `deploy-aws-meeting.sh` | `deploy-azure-meeting.sh` | Upload custom app + add to meeting |

> obo/notify/meetings: run **Entra first**. Azure vs AWS order differs per demo
> (notify does Azure before AWS so the bot FQDN is known; obo/meetings do AWS
> before Azure so the runtime id is known). Follow each part's order above.

---

## Common gotchas (all pre-handled in the scripts, but good to know)

- **`agentcore deploy` wipes the runtime's JWT authorizer.** The scripts
  re-apply it every time. If you run `agentcore deploy` by hand, re-run the
  demo's `deploy-aws-*.sh` (or the authorizer step) afterward.
- **Region drift.** If `agentcore` deploys to `us-west-2`, your AWS profile
  default region is wrong — `aws configure set region us-east-1` or
  `export AWS_REGION=us-east-1`.
- **Node 20, not 22** — Node 22 had a Bot Framework signing-key fetch bug.
- **Teams caches tab/app content.** After redeploying, remove + re-add the app
  (or the meeting tab) to force a refresh.
- **Semantic memory extraction is async** (minutes) and only extracts from
  **USER**-role turns — the meeting agent writes notes as USER turns for this reason.

---

## Verify what's deployed

```bash
# AWS agents
aws bedrock-agentcore-control list-agent-runtimes --region us-east-1 \
  --query "agentRuntimes[].{name:agentRuntimeName,status:status}" -o table

# Azure resources
az resource list -g agentcore-msteams-rg \
  --query "[?type=='Microsoft.App/containerApps' || type=='Microsoft.BotService/botServices'].{name:name,type:type}" -o table
```

---

## Teardown

```bash
conversational/infra-managed-identity/teardown-azure.sh   # + teardown-aws.sh
obo/infra/teardown-obo.sh
# notify / meetings: delete the Container App, Bot (if any), Entra app,
#   AgentCore runtime + (meetings) Memory resource, and IAM roles.
```

> Teardown scripts are dry-run by default where provided; pass `--confirm` to
> actually delete. Shared resources (resource group, ACR, Container Apps
> environment) are kept unless you explicitly remove them.

---

## Architecture deep-dives

- `conversational/ARCHITECTURE.md`
- `obo/infra/ARCHITECTURE-OBO.md`
- `notify/infra/ARCHITECTURE-NOTIFY.md`
- `meetings/infra/ARCHITECTURE-MEETING.md`
