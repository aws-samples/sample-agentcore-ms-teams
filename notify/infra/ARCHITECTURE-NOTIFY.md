# AgentCore → MS Teams: Notify-Anyone Agent

**Status: WORKING / tested.**

An Amazon Bedrock AgentCore agent that sends a proactive Adaptive Card
notification to **any user or any channel** in the Microsoft 365 tenant — even
with no prior interaction. The bot installs itself for the target on demand
(via Microsoft Graph) and delivers the card through Bot Framework proactive
messaging.

---

## 1. Token / Message Flow

```
 ┌──────────────────────────────────────────────────────────────────────────┐
 │                         MICROSOFT 365 / ENTRA ID                          │
 │                    tenant 00000000-...-000000000000                       │
 └──────────────────────────────────────────────────────────────────────────┘

  Caller (you / a system)
        │  1. mint Entra app token
        │     scope: api://botid-<notifyBotAppId>/.default
        ▼
  ┌───────────────────────────────────────────────────────────────────────┐
  │            AMAZON BEDROCK AGENTCORE RUNTIME  (us-east-1)               │
  │            notifyAgent  (id notifyAgent-OY23Mq9glI)                    │
  │                                                                       │
  │  2. INBOUND AUTH = IAM / SigV4 (default; NO customJWTAuthorizer)       │
  │     The notify agent does not use the caller's user identity, so IAM  │
  │     auth is the right fit and enables one-command `agentcore invoke`.  │
  │                                                                       │
  │  3. Agent (Strands + Claude Sonnet 4.6) decides target/title/message  │
  │     and calls the send_notification tool                              │
  │        → POST <NOTIFY_BOT_URL>/api/notify                             │
  │          Authorization: Bearer <NOTIFY_SECRET>                        │
  │          { target, title, message }                                   │
  └──────────────────────────────┬────────────────────────────────────────┘
                                 │ 4. HTTPS (shared secret)
                                 ▼
  ┌───────────────────────────────────────────────────────────────────────┐
  │            TEAMS NOTIFY BOT  (Azure Container App, westus2)            │
  │            agentcore-notify-bot   port 3980                            │
  │                                                                       │
  │  5. Resolve target via Microsoft Graph (app-only token):              │
  │     • user (email/UPN):                                               │
  │         GET /users/{upn}                                              │
  │         ensure install: POST /users/{id}/teamwork/installedApps       │
  │         GET  /users/{id}/teamwork/installedApps/{id}/chat → chatId    │
  │     • channel ("Team / Channel"):                                     │
  │         resolve team via /groups, ensure /teams/{id}/installedApps,   │
  │         resolve channel via /teams/{id}/channels                      │
  │                                                                       │
  │  6. Build a Bot Framework ConversationReference and                   │
  │     adapter.continueConversationAsync(...) → Adaptive Card            │
  └──────────────────────────────┬────────────────────────────────────────┘
                                 │ 7. Bot Framework proactive message
                                 ▼
  ┌───────────────────────────────────────────────────────────────────────┐
  │  Microsoft Teams  →  Adaptive Card appears in the user's 1:1 chat     │
  │  or the target channel ("AgentCore Notification")                     │
  └───────────────────────────────────────────────────────────────────────┘
```

---

## 2. Why Bot Framework (not Graph) sends the message

Microsoft Graph **application permissions cannot post new chat/channel
messages** (only migration/import). Only a Bot Framework bot can send arbitrary
proactive messages. So Graph is used **only** to resolve the target and ensure
the bot is installed (which creates the conversation), and Bot Framework's
`continueConversationAsync` does the actual delivery.

---

## 3. Components

| Component | Detail |
|-----------|--------|
| **Entra app** `AgentCore-Notify-Bot` | App id `563e5c85-3d96-42b0-aef6-9488fad5e427`. Application Graph permissions (admin-consented): `TeamsAppInstallation.ReadWriteForUser.All`, `TeamsAppInstallation.ReadWriteForTeam.All`, `AppCatalog.Read.All`, `User.Read.All`, `Group.Read.All`, `Team.ReadBasic.All`, `Channel.ReadBasic.All`, `TeamsActivity.Send`. Exposes `api://botid-<appId>` so a client-credentials token can target the runtime authorizer. |
| **Azure Bot** `agentcore-notify-bot` | SingleTenant, F0, Teams channel enabled, `isNotificationOnly: true`. |
| **Container App** `agentcore-notify-bot` | Node 20, westus2, port 3980. Endpoints: `/api/messages` (Bot Framework), `/api/notify` (target-aware, secret-protected), `/health`. |
| **AgentCore agent** `notifyAgent` | us-west-2, HTTP protocol, customJWTAuthorizer (Entra). Tool: `send_notification(target, title, message)`. |
| **Teams app package** | Manifest id (externalId) `d8dd97be-aba4-437c-bd80-1e92a0aa882c`. **Must be uploaded to the Teams admin app catalog** so the bot can proactively install it for users/teams. |

---

## 4. Auth model

| Hop | Auth |
|-----|------|
| **Caller → AgentCore runtime** | **IAM / SigV4** (default). `agentcore invoke '{...}'` works directly — no Entra token needed. (Contrast: OBO + meeting agents use JWT because they need the *user's* identity; notify does not.) |
| **Agent → notify bot `/api/notify`** | Shared `NOTIFY_SECRET` (Bearer) |
| **Bot → Microsoft Graph** | App-only token (client_credentials, scope `https://graph.microsoft.com/.default`) to resolve target + install the bot |

> The bot app still exposes `api://botid-<appId>`; if you ever want JWT auth on
> the runtime instead of IAM, add a `customJWTAuthorizer` (discoveryUrl +
> allowedAudience `[api://botid-<appId>, <appId>]`) and mint a client-credentials
> token for that audience.

---

## 5. Deploy

```bash
cd notify/infra
./setup-entra-notify.sh                 # Entra app + permissions + consent + secret
./deploy-azure-notify.sh                # Bot + container + Teams package
# >>> Upload notify/bot/appPackage.zip to Teams Admin Center catalog <<<
./deploy-aws-notify.sh --region us-east-1   # IAM role + agent (IAM auth) + env
```

### Test — one command (IAM auth)
```bash
cd agentcore-agent-notify
agentcore invoke '{"prompt": "notify jane@example.com that the build passed"}'
# channel:
agentcore invoke '{"prompt": "notify JP / General that deployment is complete"}'
```
No token minting needed — IAM/SigV4 auth means the CLI works directly. This is
the quick-demo path.

---

## 6. Prerequisites & gotchas

- **App must be in the Teams admin app catalog** (not just sideloaded to one chat) for proactive install to work.
- `User.Read.All` is required to resolve users by UPN/email (not just `Group.Read.All`).
- The bot app needs an exposed `identifierUri` (`api://botid-<appId>`) so a client-credentials token can be minted with an audience the runtime authorizer accepts.
- After every `agentcore deploy`, re-apply the `customJWTAuthorizer` (deploy wipes it).
- Node 20 base image (Node 22 had a Bot Framework signing-key fetch bug).

---

## 7. Security notes

- `/api/notify` is gated by `NOTIFY_SECRET`; the runtime is gated by Entra JWT.
- The Graph app token has tenant-wide install/read permissions — scope the bot's
  Entra app tightly and treat `NOTIFY_BOT_APP_SECRET` / `NOTIFY_SECRET` as secrets.
- For production, replace the `NOTIFY_SECRET` shared secret with an Entra token
  the agent obtains via AgentCore Identity, and validate it at `/api/notify`.
