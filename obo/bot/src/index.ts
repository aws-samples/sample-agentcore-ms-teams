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

import * as restify from "restify";
import * as fs from "fs";
import * as path from "path";
import {
  MemoryStorage,
  TurnContext,
  ConfigurationServiceClientCredentialFactory,
} from "botbuilder";
import { Application, TeamsAdapter, TurnState } from "@microsoft/teams-ai";
import * as dotenv from "dotenv";
import { registerHandlers } from "./bot";

dotenv.config({ path: "../.env.obo" });
dotenv.config();

const clientId = process.env.OBO_BOT_APP_ID!;
const clientSecret = process.env.OBO_BOT_APP_SECRET!;
const tenantId = process.env.TENANT_ID!;
const botDomain = process.env.BOT_DOMAIN || "localhost";

export const AUTH_SETTING = "graph";

const adapter = new TeamsAdapter(
  {
    MicrosoftAppId: clientId,
    MicrosoftAppPassword: clientSecret,
    MicrosoftAppTenantId: tenantId,
    MicrosoftAppType: "SingleTenant",
  },
  new ConfigurationServiceClientCredentialFactory({
    MicrosoftAppId: clientId,
    MicrosoftAppPassword: clientSecret,
    MicrosoftAppTenantId: tenantId,
    MicrosoftAppType: "SingleTenant",
  })
);

adapter.onTurnError = async (context: TurnContext, error: Error) => {
  // Log only metadata. Error messages/stacks from turn processing can contain
  // fragments of user conversation content; avoid writing them to console.
  console.error(`[onTurnError] ${error.name} at ${new Date().toISOString()}`);
  await context.sendActivity("Something went wrong. Please try again.");
};

const storage = new MemoryStorage();

const app = new Application<TurnState>({
  adapter,
  storage,
  authentication: {
    settings: {
      [AUTH_SETTING]: {
        // DATA PROTECTION NOTE: Mail.Read and Calendars.Read grant access to the
        // user's personal email and calendar — personal data regulated under GDPR
        // and similar frameworks. Under the AWS shared responsibility model,
        // customers deploying this sample are responsible for meeting applicable
        // data-protection requirements before production use.
        // See https://aws.amazon.com/compliance/shared-responsibility-model/
        scopes: [
          "https://graph.microsoft.com/User.Read",
          "https://graph.microsoft.com/Mail.Read",
          "https://graph.microsoft.com/Calendars.Read",
        ],
        msalConfig: {
          auth: {
            clientId,
            clientSecret,
            authority: `https://login.microsoftonline.com/${tenantId}`,
          },
        },
        signInLink: `https://${botDomain}/auth-start.html`,
        endOnInvalidMessage: true,
      },
    },
    default: AUTH_SETTING,
    autoSignIn: true,
  },
});

registerHandlers(app);

const server = restify.createServer();
server.use(restify.plugins.bodyParser());
server.use(restify.plugins.queryParser());

// Serve the SSO consent pages
server.get("/auth-start.html", (req, res, next) => {
  res.setHeader("Content-Type", "text/html");
  res.end(AUTH_START_HTML);
  return next();
});
server.get("/auth-end.html", (req, res, next) => {
  res.setHeader("Content-Type", "text/html");
  res.end(AUTH_END_HTML);
  return next();
});

// Self-hosted Microsoft Teams JS SDK (vendored, see public/vendor/teams-js/README.md)
const TEAMS_JS = fs.readFileSync(
  path.join(__dirname, "..", "public", "vendor", "teams-js", "2.19.0", "MicrosoftTeams.min.js"),
  "utf8"
);
server.get("/vendor/teams-js/2.19.0/MicrosoftTeams.min.js", (req, res, next) => {
  res.setHeader("Content-Type", "application/javascript");
  res.end(TEAMS_JS);
  return next();
});

server.post("/api/messages", async (req, res) => {
  await adapter.process(req, res, async (context) => {
    await app.run(context);
  });
});

const port = process.env.PORT || 3979;
server.listen(port, () => {
  console.log(`OBO Bot (teams-ai) listening on http://localhost:${port}/api/messages`);
});

// ---------------------------------------------------------------------------
// SSO consent pages (served for the popup fallback when silent SSO needs consent)
// ---------------------------------------------------------------------------
const AUTH_START_HTML = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Sign In</title>
<script src="/vendor/teams-js/2.19.0/MicrosoftTeams.min.js"></script>
</head><body>
<script>
microsoftTeams.app.initialize().then(function () {
  microsoftTeams.app.getContext().then(function (context) {
    var clientId = "${clientId}";
    var tenantId = "${tenantId}";
    var scope = encodeURIComponent("https://graph.microsoft.com/User.Read https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/Calendars.Read openid profile");
    var loginHint = context.user ? context.user.loginHint : "";
    var state = Math.random().toString(36).substring(2);
    localStorage.setItem("auth.state", state);
    var redirectUri = encodeURIComponent("https://${botDomain}/auth-end.html");
    var authUrl = "https://login.microsoftonline.com/" + tenantId +
      "/oauth2/v2.0/authorize?client_id=" + clientId +
      "&response_type=token&redirect_uri=" + redirectUri +
      "&scope=" + scope +
      "&state=" + state +
      "&login_hint=" + encodeURIComponent(loginHint) +
      "&nonce=" + Math.random().toString(36).substring(2);
    window.location.assign(authUrl);
  });
});
</script>
<p>Redirecting to sign-in...</p>
</body></html>`;

const AUTH_END_HTML = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Sign In Complete</title>
<script src="/vendor/teams-js/2.19.0/MicrosoftTeams.min.js"></script>
</head><body>
<script>
microsoftTeams.app.initialize().then(function () {
  var hash = window.location.hash.substring(1);
  var params = {};
  hash.split("&").forEach(function (kv) {
    var p = kv.split("=");
    params[p[0]] = decodeURIComponent(p[1]);
  });
  if (params["access_token"]) {
    microsoftTeams.authentication.notifySuccess(params["access_token"]);
  } else {
    microsoftTeams.authentication.notifyFailure(params["error"] || "AuthFailed");
  }
});
</script>
<p>Completing sign-in...</p>
</body></html>`;
