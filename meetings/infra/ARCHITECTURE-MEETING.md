# AgentCore Meeting Assistant (Teams side panel + AgentCore Memory)

**Status: WORKING / tested** — in-meeting SSO, conversation with history,
memory save, and long-term recall all confirmed.

A Teams in-meeting **side panel** app + a memory-enabled AgentCore agent. During
a meeting the signed-in user chats with an AI assistant that can summarize the
meeting transcript (acting as the user via delegated identity), save decisions /
action items to **AgentCore Memory**, and recall context from past meetings.

This is the first demo to use **AgentCore Memory** (short-term events +
semantic long-term facts).

---

## 1. Token / Data Flow

```
 ┌──────────────────────────────────────────────────────────────────────────┐
 │                        MICROSOFT 365 / ENTRA ID                          │
 └──────────────────────────────────────────────────────────────────────────┘

  User in a Teams meeting → opens the "AgentCore Assistant" side panel
        │ 1. Teams JS SDK getAuthToken()  (silent SSO)
        │    token aud = api://<appFQDN>/<appId>   (TAB resource format)
        ▼
  ┌───────────────────────────────────────────────────────────────────────┐
  │            MEETING APP  (Azure Container App, westus2)                │
  │            agentcore-meeting-app   port 3981                          │
  │            serves: sidepanel.html / config.html / auth-*.html         │
  │                    + POST /api/agent  (proxy)                         │
  │                                                                       │
  │  2. /api/agent receives { ssoToken, prompt, userId, meetingId,        │
  │     history }                                                         │
  │  3. OBO exchange (MSAL acquireTokenOnBehalfOf):                       │
  │       ssoToken + app secret → USER's Microsoft Graph token            │
  │       (User.Read, OnlineMeetings.Read, OnlineMeetingTranscript.Read)  │
  │  4. mint the app token (client_credentials) for the runtime authorizer│
  └──────────────────────────────┬────────────────────────────────────────┘
                                 │ 5. POST runtimes/<id>/invocations
                                 │    Authorization: Bearer <APP TOKEN>   (caller auth)
                                 │    body: { prompt, graph_token, user_id, meeting_id, history }
                                 ▼
  ┌───────────────────────────────────────────────────────────────────────┐
  │           AMAZON BEDROCK AGENTCORE RUNTIME  (us-east-1)               │
  │           meetingAgent  (id meetingAgent-Bux0CJ57Ew)                  │
  │                                                                       │
  │  6. INBOUND AUTH = customJWTAuthorizer (validates the APP token)      │
  │  7. Agent seeds conversation from `history`, sanitizes user_id/       │
  │     meeting_id → actor_id/session_id, stores graph_token in a contextvar│
  │                                                                       │
  │  Tools:                                                               │
  │   • summarize_meeting_transcript(joinUrl)                             │
  │       Graph (as the user): resolve onlineMeeting → list transcripts → │
  │       GET .../transcripts/{id}/content?$format=text/vtt               │
  │   • save_meeting_note(note)                                           │
  │       create_event(messages=[(USER note),(ASSISTANT ack)])  *** USER  │
  │       role is REQUIRED for semantic extraction ***                    │
  │   • recall_context(query)                                             │
  │       retrieve_memories(namespace=/users/{actorId}/facts/)            │
  └──────────────┬──────────────────────────────────┬─────────────────────┘
                 │                                  │
                 ▼ Graph (as user)                  ▼ AgentCore Memory
  ┌───────────────────────────┐      ┌────────────────────────────────────────┐
  │ Microsoft Graph           │      │ AgentCore Memory                       │
  │ /me, /me/onlineMeetings,  │      │ meetingAssistantMemory-4DrhcBHjBm      │
  │ transcripts (VTT)         │      │ short-term events  →  SEMANTIC strategy│
  └───────────────────────────┘      │ extracts long-term facts into          │
                                     │ /users/{actorId}/facts/ (async, ~min)  │
                                     └────────────────────────────────────────┘
```

---

## 2. Two identities in play

| Identity | Token | Used for |
|----------|-------|----------|
| **The user (delegated)** | Graph token via OBO exchange of the SSO token | Reading the user's own profile, meetings, transcripts (acts AS the user) |
| **The app (caller)** | client_credentials app token (`api://botid-<appId>`) | Authenticating the proxy to the AgentCore runtime (customJWTAuthorizer) |

The user's Graph token is passed to the agent in the **payload** (`graph_token`)
— the same payload-passthrough pattern proven in the OBO demo. The agent's tools
call Graph directly with it.

---

## 3. AgentCore Memory model

| Aspect | Detail |
|--------|--------|
| **Memory resource** | `meetingAssistantMemory-4DrhcBHjBm` (us-east-1), event expiry 90 days |
| **Strategy** | `SEMANTIC` (`meetingFacts`), namespace `/users/{actorId}/facts/` |
| **Short-term** | `create_event` writes raw turns immediately (actor_id = sanitized user id, session_id = sanitized meeting id) |
| **Long-term** | The semantic strategy asynchronously extracts facts from **USER-role** turns into `/users/{actorId}/facts/` (takes ~minutes) |
| **Recall** | `retrieve_memories(namespace=/users/{actorId}/facts/, query=...)` |
| **Isolation** | App-enforced: the agent scopes every query to the token-derived `actorId`'s namespace, so a user only retrieves their own facts. IAM on the Memory resource is resource-level (an admin/role with access can read any namespace). Encryption: AWS-managed at rest (KMS CMK optional), TLS in transit. |

> **Critical**: semantic extraction only processes **USER** turns. Notes must be
> written with a USER message (e.g. "Please remember: <note>") — an ASSISTANT-only
> event is never extracted to long-term memory.

---

## 4. Components

| Component | Detail |
|-----------|--------|
| **Entra app** `AgentCore-Meeting-App` | `65cfe97c-a488-44b2-9e69-d271e3947940`. Delegated Graph: `User.Read`, `OnlineMeetings.Read`, `OnlineMeetingTranscript.Read.All` (+ consent). Exposes `access_as_user`. Two identifier URIs: `api://botid-<appId>` (runtime audience) and `api://<appFQDN>/<appId>` (TAB SSO resource). |
| **Container App** `agentcore-meeting-app` | Node 20, westus2, port 3981. Serves the side panel + `/api/agent` OBO proxy. |
| **AgentCore agent** `meetingAgent` | us-east-1, HTTP, customJWTAuthorizer. Tools: summarize / save / recall. Memory enabled via `MEMORY_ID` env var. |
| **AgentCore Memory** | `meetingAssistantMemory-4DrhcBHjBm`, semantic strategy. |
| **Teams app package** | Manifest id `65fde481-5949-432d-a706-c9009ed12ea3`. `configurableTabs` with `context:["meetingSidePanel","meetingChatTab","meetingDetailsTab"]`, `scopes:["groupChat"]`, `webApplicationInfo.resource = api://<appFQDN>/<appId>`. |

---

## 5. Deploy

```bash
cd meetings/infra
./setup-entra-meeting.sh                       # app + delegated perms + SSO scope + consent
./deploy-aws-meeting.sh --region us-east-1      # IAM + Memory resource + agent + authorizer
./deploy-azure-meeting.sh                       # container + Teams package + SPA redirect
# >>> Upload meetings/app/appPackage.zip via Teams, add the tab to a meeting <<<
```

Transcripts require: meeting **transcription was ON**, you are the **organizer**,
and the meeting has **ended** (transcript available ~5–10 min after).

---

## 6. Gotchas discovered during build/test

1. **Tab SSO** "App resource defined in manifest and iframe origin do not match"
   → `webApplicationInfo.resource` for a **tab** must be `api://<appFQDN>/<appId>`,
   not `api://botid-<appId>`. Add it as a second identifier URI and to the runtime
   `allowedAudience`.
2. **Memory session-id validation** → Teams user/meeting ids contain `:` `@` and
   are long; sanitize to `[A-Za-z0-9_-]` (≤100 chars) before using as actor/session id.
3. **Conversation history** → each invoke is stateless; the side panel tracks turns
   and sends a `history` array which the agent seeds via `Agent(messages=...)`.
4. **Long-term extraction** → only **USER**-role turns are extracted by the semantic
   strategy. Write notes as USER (+ ASSISTANT ack). Extraction is async (~minutes).
5. **Caching** → Teams caches tab HTML and Docker caches `COPY public/`. Use an
   `ARG CACHEBUST` before the COPY, build with `--build-arg CACHEBUST=$(date +%s)`,
   bump the image tag, and remove+re-add the tab in the meeting to refresh the client.
6. After every `agentcore deploy`, re-apply `customJWTAuthorizer` + `MEMORY_ID` env
   (deploy wipes runtime config). Use `--query/--output table`, never `--output none`.

---

## 7. Not implemented (production upgrade path)

- **Real-time audio capture / live transcription** — requires a Graph Communications
  calling bot with application-hosted media (Windows VM + .NET Media SDK). Out of
  scope for this demo; the side panel + post-meeting transcript covers the use case
  without that infrastructure.
- **Server-side identity binding** — currently the proxy passes `user_id` in the
  payload. A hardened version would pass the user JWT and let AgentCore
  `GetWorkloadAccessTokenForJWT` derive the actor id, removing trust in a
  client-supplied id.
