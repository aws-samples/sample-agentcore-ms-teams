/*
 * Copyright 2026 Amazon.com, Inc. or its affiliates
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// DATA PROTECTION NOTE: This app performs an OBO token exchange and uses the
// resulting delegated token to read personal data from Microsoft Graph (user
// profile, calendar, and meeting transcripts) which it passes to an AI agent.
// Handling this data may be subject to privacy regulations such as GDPR. Under
// the AWS shared responsibility model, customers deploying this sample are
// responsible for meeting the applicable data-protection requirements (lawful
// basis, retention, minimization, and access controls) for the personal data
// processed here. See https://aws.amazon.com/compliance/shared-responsibility-model/
import * as restify from "restify";
import * as fs from "fs";
import * as path from "path";
import { ConfidentialClientApplication } from "@azure/msal-node";
import * as dotenv from "dotenv";

dotenv.config({ path: "../.env.meeting" });
dotenv.config();

const TENANT_ID = process.env.TENANT_ID!;
const APP_ID = process.env.MEETING_APP_ID!;
const APP_SECRET = process.env.MEETING_APP_SECRET!;
const RUNTIME_ID = process.env.MEETING_AGENT_RUNTIME_ID || "";
const ACCOUNT_ID = process.env.AWS_ACCOUNT_ID || "";
const AWS_REGION = process.env.AWS_REGION || "us-east-1";
const PUBLIC_DIR = path.join(__dirname, "..", "public");

const msal = new ConfidentialClientApplication({
  auth: {
    clientId: APP_ID,
    clientSecret: APP_SECRET,
    authority: `https://login.microsoftonline.com/${TENANT_ID}`,
  },
});

/** OBO: exchange the side-panel SSO token for a Microsoft Graph token. */
async function oboGraphToken(ssoToken: string): Promise<string> {
  const result = await msal.acquireTokenOnBehalfOf({
    oboAssertion: ssoToken,
    scopes: [
      "https://graph.microsoft.com/User.Read",
      "https://graph.microsoft.com/OnlineMeetings.Read",
      "https://graph.microsoft.com/OnlineMeetingTranscript.Read.All",
    ],
  });
  if (!result?.accessToken) throw new Error("OBO exchange returned no token");
  return result.accessToken;
}

/** App token whose audience the AgentCore runtime authorizer accepts. */
async function agentAppToken(): Promise<string> {
  const result = await msal.acquireTokenByClientCredential({
    scopes: [`api://botid-${APP_ID}/.default`],
  });
  if (!result?.accessToken) throw new Error("Failed to acquire agent app token");
  return result.accessToken;
}

async function invokeAgent(prompt: string, graphToken: string, userId: string, meetingId: string, history: any[]): Promise<string> {
  const appToken = await agentAppToken();
  const endpoint = `https://bedrock-agentcore.${AWS_REGION}.amazonaws.com/runtimes/${RUNTIME_ID}/invocations?accountId=${ACCOUNT_ID}`;
  const resp = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "text/event-stream",
      Authorization: `Bearer ${appToken}`,
    },
    body: JSON.stringify({ prompt, graph_token: graphToken, user_id: userId, meeting_id: meetingId, history: history || [] }),
  });
  if (!resp.ok) throw new Error(`AgentCore ${resp.status}: ${(await resp.text()).slice(0, 200)}`);

  const ct = resp.headers.get("content-type") || "";
  if (ct.includes("text/event-stream")) {
    const text = await resp.text();
    const chunks: string[] = [];
    for (const line of text.split("\n")) {
      if (line.startsWith("data: ")) {
        let c = line.slice(6).trim();
        try { c = JSON.parse(c); } catch {}
        chunks.push(c);
      }
    }
    return chunks.join("") || text;
  }
  const data: any = await resp.json();
  return data.payload ? JSON.stringify(data.payload) : JSON.stringify(data);
}

const server = restify.createServer();
server.use(restify.plugins.bodyParser());
server.use(restify.plugins.queryParser());

// Serve static tab pages
function serveStatic(file: string) {
  return (req: restify.Request, res: restify.Response, next: restify.Next) => {
    try {
      const body = fs.readFileSync(path.join(PUBLIC_DIR, file), "utf8");
      res.setHeader("Content-Type", file.endsWith(".html") ? "text/html" : "application/javascript");
      res.sendRaw(200, body);
    } catch {
      res.send(404, "Not found");
    }
    return next();
  };
}
server.get("/", serveStatic("sidepanel.html"));
server.get("/sidepanel.html", serveStatic("sidepanel.html"));
server.get("/config.html", serveStatic("config.html"));
server.get("/auth-start.html", serveStatic("auth-start.html"));
server.get("/auth-end.html", serveStatic("auth-end.html"));
// Self-hosted Microsoft Teams JS SDK (vendored, see public/vendor/teams-js/README.md)
server.get("/vendor/teams-js/2.19.0/MicrosoftTeams.min.js",
  serveStatic("vendor/teams-js/2.19.0/MicrosoftTeams.min.js"));

server.get("/health", (req, res, next) => { res.send(200, { status: "ok" }); return next(); });

/** Tab → agent. Body: { ssoToken, prompt, userId, meetingId } */
server.post("/api/agent", async (req, res) => {
  const { ssoToken, prompt, userId, meetingId, history } = req.body || {};
  if (!ssoToken || !prompt) {
    res.send(400, { error: "ssoToken and prompt are required" });
    return;
  }
  try {
    const graphToken = await oboGraphToken(ssoToken);
    const answer = await invokeAgent(prompt, graphToken, userId || "unknown-user", meetingId || "default-session", history || []);
    res.send(200, { answer });
  } catch (err: any) {
    // Log metadata only — err.message may contain fragments of user input / agent output.
    console.error("agent proxy error:", err?.name || "Error");
    res.send(500, { error: "internal error" });
  }
});

const port = process.env.PORT || 3981;
server.listen(port, () => {
  console.log(`Meeting app listening on http://localhost:${port}`);
});
