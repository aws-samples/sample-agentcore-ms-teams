# AgentCore + MS Teams — On-Behalf-Of (OBO) User Identity Passthrough

**Status: WORKING / fully tested.**

This demo shows an AI agent on **Amazon Bedrock AgentCore Runtime** acting **on
behalf of a specific Microsoft 365 user**. When a user chats with the Teams bot,
the agent reads *that user's* profile, emails, and calendar from Microsoft Graph
**using the user's own delegated permissions** — not a shared service account.

The key idea: the Teams bot performs SSO + an On-Behalf-Of token exchange to get
the **user's Microsoft Graph token**, then passes that token in the request
**payload** to the AgentCore agent. The agent calls Graph directly with it.

---

## 1. Token Flow (end to end)

```
 ┌────────────────────────────────────────────────────────────────────────────┐
 │                              MICROSOFT 365 / ENTRA ID                        │
 │                         tenant 00000000-...-000000000000                     │
 └────────────────────────────────────────────────────────────────────────────┘

  ┌──────────────┐
  │  User in     │   "show me my recent emails"
  │  MS Teams    │
  └──────┬───────┘
         │ 1. message + (teams-ai) silent SSO token request
         │    scope: api://botid-<botAppId>/access_as_user
         ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │  Entra ID (token endpoint)                                        │
  │  - issues USER SSO token (aud = api://botid-<botAppId>)           │
  │    Teams client is PRE-AUTHORIZED -> no consent prompt            │
  └──────┬────────────────────────────────────────────────────────────┘
         │ 2. SSO token delivered to bot via Bot Framework / teams-ai
         ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  TEAMS BOT  (teams-ai Application + TeamsAdapter)                          │
  │  Azure Container App  agentcore-obo-bot  (westus2, port 3979)             │
  │  MicrosoftAppType = "SingleTenant" (validates inbound Bot Connector token)│
  │                                                                           │
  │  3. OBO EXCHANGE (teams-ai, MSAL):                                        │
  │     user SSO token  +  THIS bot app's OWN client secret                   │
  │       -> Microsoft Graph token for the user                              │
  │          (User.Read, Mail.Read, Calendars.Read — delegated)              │
  │     The Graph token lands in state.temp.authTokens["graph"].             │
  │                                                                           │
  │  4. BOT AUTHENTICATES TO AGENTCORE with its OWN app token:               │
  │     ManagedIdentityCredential ── api://AzureADTokenExchange ─┐            │
  │       (federated credential lets the MI assert as the app)  │            │
  │     ClientAssertionCredential(tenant, appId, <MI assertion>)│            │
  │       -> app token  aud = api://botid-<botAppId>/.default ──┘            │
  └──────┬────────────────────────────────────────────────────────────────────┘
         │ 5. POST .../runtimes/<runtimeId>/invocations
         │    Authorization: Bearer <BOT APP TOKEN>          (caller auth)
         │    body: { prompt, user_name, graph_token: <USER GRAPH TOKEN> }
         ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │              AMAZON BEDROCK AGENTCORE RUNTIME  (us-east-1)                 │
  │              oboAgent  (id oboAgent-um0hmwDnaK)                            │
  │                                                                           │
  │  6. INBOUND AUTH = customJWTAuthorizer                                    │
  │     validates the BOT APP TOKEN against Entra discovery URL,              │
  │     allowedAudience = [api://botid-<botAppId>, <botAppId>]                │
  │     (this only authenticates the CALLER, not the end user)               │
  │                                                                           │
  │  7. Agent (Strands + Claude Sonnet 4.6) reads payload.graph_token,        │
  │     stores it in a contextvar, and tools call Graph AS THE USER:          │
  │       GET https://graph.microsoft.com/v1.0/me                            │
  │       GET .../me/messages   GET .../me/calendarView                      │
  │       Authorization: Bearer <USER GRAPH TOKEN>                           │
  └──────┬────────────────────────────────────────────────────────────────────┘
         │ 8. Graph returns the USER's own data (their permissions only)
         ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  Microsoft Graph  →  agent response  →  bot  →  Adaptive Card in Teams    │
  │  "Acting on behalf of <user> (delegated identity)"                        │
  └─────────────────────────────────────────────────────────────────────────┘
```

### Two distinct tokens — do not confuse them
| Token | Audience | Purpose | How obtained |
|-------|----------|---------|--------------|
| **User Graph token** | `https://graph.microsoft.com` | Call Graph *as the user* | teams-ai OBO exchange (user SSO token + bot secret) |
| **Bot app token** | `api://botid-<botAppId>` | Authenticate the *caller* to AgentCore | MI federated credential → ClientAssertionCredential |

AgentCore's inbound authorizer validates **only** the bot app token. The user's
identity rides along in the payload as `graph_token`.

---

## 2. Why payload-passthrough instead of an AgentCore OBO exchange

The first attempt tried to have **AgentCore Identity** do the OBO exchange
(separate `AgentCore-OBO-Downstream` app + an `oauth2-credential-provider` +
`requires_access_token` in the agent). **It does not work for this flow**:

- AgentCore's OBO/token-vault exchange expects to exchange an **incoming user
  token** for a downstream token. But the token AgentCore receives at the
  inbound authorizer is the **bot's app-only token**, not the user's token.
- **You cannot OBO-exchange an app-only token** — there is no user assertion in
  it. The OBO grant (`urn:...:jwt-bearer`) requires a delegated user token as
  the subject. So AgentCore had nothing valid to exchange.

The working design moves the OBO exchange **up into the bot**, where the *user's*
SSO token is actually available (teams-ai already has it). The bot does the
standard MSAL OBO exchange (user token + bot secret → Graph token) and simply
**ships the resulting Graph token to the agent in the payload**. The agent treats
it as an opaque bearer token for Graph.

Consequence: `AgentCore-OBO-Downstream` and the `microsoft-graph-obo` credential
provider are **NOT part of the working architecture**. They are optional/unused
leftovers; `teardown-obo.sh` will remove the downstream app if it still exists.

---

## 3. Components

| Component | Identifier | Notes |
|-----------|-----------|-------|
| Entra tenant | `00000000-0000-0000-0000-000000000000` (example.onmicrosoft.com) | |
| Bot app registration | `AgentCore-Teams-Bot-OBO`, appId `11111111-1111-1111-1111-111111111111` | `signInAudience = AzureADMultipleOrgs`; identifierUri `api://botid-<appId>`; plays 3 roles (Bot identity / SSO resource / OBO client) |
| Exposed SSO scope | `api://botid-<appId>/access_as_user` | Teams + Office clients pre-authorized |
| Delegated Graph perms | `User.Read`, `Mail.Read`, `Calendars.Read` | admin-consented |
| Managed Identity | `agentcore-bot-identity`, clientId `33333333-3333-3333-3333-333333333333`, principalId `44444444-4444-4444-4444-444444444444` | assigned to the Container App |
| Federated credential | subject = MI principalId, issuer = `https://login.microsoftonline.com/<tenant>/v2.0`, audience = `api://AzureADTokenExchange` | on the bot app reg |
| Azure Bot | `agentcore-obo-bot`, type **UserAssignedMSI**, global, RG `agentcore-msteams-rg` | MultiTenant bot creation is deprecated |
| Container App | `agentcore-obo-bot`, env `bot-env-west` (westus2), port 3979 | FQDN `agentcore-obo-bot.YOUR-ENV.REGION.azurecontainerapps.io` |
| ACR | `agentcoredemo2cr` | |
| Bot runtime | teams-ai `Application` + `TeamsAdapter`, Node 20 | `teams-bot-obo/` |
| AgentCore Runtime | `oboAgent` (id `oboAgent-um0hmwDnaK`), us-east-1, account `111122223333`, HTTP | `customJWTAuthorizer`, allowedAudience `[api://botid-<appId>, <appId>]` |
| IAM role | `AgentCoreOBOAgentRole` | bedrock + bedrock-agentcore + `secretsmanager:GetSecretValue` + logs |
| Model | `us.anthropic.claude-sonnet-4-6` | |
| Agent | Strands `Agent`, tools `whoami` / `get_my_emails` / `get_my_calendar` | `agentcore-agent-obo/src/main.py`, NO `requires_access_token` |

---

## 4. Secrets inventory

| Secret | Where it lives | Used for |
|--------|----------------|----------|
| Bot app **client secret** (`OBO_BOT_APP_SECRET`) | Container App env var; `../.env.obo` | (a) Bot Framework SDK identity; (b) the MSAL OBO exchange (user SSO token → Graph token). **This is the only secret in the working flow.** |
| Managed Identity | Azure-managed, no secret material | Mints the bot app token to call AgentCore (via federated credential → ClientAssertionCredential). Removes the need for a secret on the AgentCore call path. |
| AWS credentials | bot host / deploy environment | Sign the SigV4-less HTTPS POST to the runtime invoke endpoint (Bearer = Entra app token; AWS creds used by AgentCore control-plane setup, not the invoke). |

There is **no** downstream app secret and **no** AgentCore Identity token vault in
the working architecture.

`../.env.obo` keys (values are NOT committed):
`TENANT_ID, OBO_BOT_APP_ID, OBO_BOT_APP_SECRET, OBO_BOT_IDENTIFIER_URI,
OBO_BOT_SCOPE_ID, BOT_DOMAIN, MI_CLIENT_ID, MI_PRINCIPAL_ID,
AGENTCORE_RUNTIME_ID, AWS_ACCOUNT_ID, AWS_REGION, SSO_CONNECTION_NAME`.

Container App env vars the bot reads: `OBO_BOT_APP_ID, OBO_BOT_APP_SECRET,
TENANT_ID, MI_CLIENT_ID, BOT_DOMAIN, AGENTCORE_RUNTIME_ID, AWS_ACCOUNT_ID,
AWS_REGION, SSO_CONNECTION_NAME`.

---

## 5. Prerequisites

- Azure CLI (`az`) logged in to the tenant, with rights to create app
  registrations, grant admin consent, and create Container Apps / Bot / MI.
- AWS CLI configured for account `111122223333` (or your own), and the
  `agentcore` CLI installed.
- `jq`, `uuidgen`, `zip`, Node 20+ / `npm`, and `openssl` on the deploy host.
- A Microsoft 365 tenant with a test user that has mail/calendar data.

---

## 6. Deploy order

```bash
cd obo/infra
chmod +x *.sh

./setup-entra-obo.sh                       # bot app reg, scope, pre-auth, perms, secret
./deploy-azure-obo.sh                       # MI, federated cred, bot, container, package
./deploy-aws-obo.sh                         # IAM role, agentcore deploy, RE-APPLY authorizer
# AWS step prints AGENTCORE_RUNTIME_ID/AWS_ACCOUNT_ID into ../.env.obo:
./deploy-azure-obo.sh                       # re-run so the bot gets the runtime env vars
# sideload obo/bot/appPackage.zip into Teams, message the bot: "whoami"
```

Teardown (dry-run by default):

```bash
./teardown-obo.sh            # shows what would be deleted
./teardown-obo.sh --confirm  # deletes OBO-specific resources (keeps shared env/ACR/RG)
```

---

## 7. Lessons learned / gotchas (painful discoveries)

1. **App reg audience must be multi-tenant, but the bot SDK type is single-tenant.**
   The app registration `signInAudience` **must** be `AzureADMultipleOrgs` —
   the Bot Framework OAuth popup / `token.botframework.com` only works against a
   multi-tenant app. Yet the **bot SDK** `MicrosoftAppType` in the teams-ai
   `TeamsAdapter` is `"SingleTenant"` (with `tenantId`) — that setting validates
   *inbound Bot Connector tokens*. And the **Azure Bot resource** is
   `UserAssignedMSI` (MultiTenant bot *creation* is deprecated by Azure). Three
   different "tenancy" settings on three different objects — all intentional.

2. **Two things are required for the secret-free AgentCore call**, not one:
   - the user-assigned MI **assigned to the Container App**, AND
   - a **federated identity credential on the bot app reg** with
     `subject` = MI principalId, `issuer` =
     `https://login.microsoftonline.com/<tenant>/v2.0`,
     `audience` = `api://AzureADTokenExchange`.
   Missing either one breaks `ClientAssertionCredential`.

3. **Redirect URIs:** add SPA redirect `https://<botFqdn>/auth-end.html` (for the
   implicit-flow popup fallback) **and** web redirect
   `https://token.botframework.com/.auth/web/redirect`.

4. **Delegated Graph perms need admin consent.** `User.Read`, `Mail.Read`,
   `Calendars.Read` plus admin consent (oauth2PermissionGrants) — otherwise the
   OBO exchange fails with a consent error.

5. **Pre-authorize the Teams client IDs** (`1fec8e78-bce4-4aaf-ab1b-5451cc387264`,
   `5e3ce6c0-2b1f-4285-8d4b-75ee78787346`) on the exposed scope so SSO is silent
   (no consent prompt inside Teams).

6. **Manifest** needs `webApplicationInfo { id: <appId>, resource:
   api://botid-<appId> }` and `validDomains` must include the bot FQDN.

7. **`agentcore deploy` WIPES the `customJWTAuthorizer` every time.** After every
   deploy you MUST re-run `update-agent-runtime` to re-apply the authorizer.
   `deploy-aws-obo.sh` does deploy FIRST, then re-applies — keep that order. If
   you ever deploy by hand, run `./deploy-aws-obo.sh --skip-deploy` afterward.

8. **IAM role needs `secretsmanager:GetSecretValue`** even though this agent
   reads no secret directly — the AgentCore runtime requires it.

9. **Use the Node 20 base image.** Node 22 had a botframework signing-key fetch
   bug that broke inbound token validation.

10. **teams-ai does NOT replay the original message after sign-in.** On first use
    the user signs in, sees "Signed in!", and must **resend** their message. This
    is expected behavior, not a bug.

11. **`allowedAudience` lists both `api://botid-<appId>` and the bare `<appId>`.**
    The bot requests `api://botid-<appId>/.default`; accepting both audiences
    avoids audience-mismatch 403s if the token form ever varies.
```
