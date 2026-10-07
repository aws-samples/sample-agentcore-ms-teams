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

// DATA PROTECTION NOTE: this module resolves Teams users by UPN/email and reads user/team/channel identifiers via Microsoft Graph — personal data. Handling this data may be subject to
// GDPR and similar frameworks. Under the AWS shared responsibility model, customers
// deploying this sample are responsible for applicable data-protection requirements.
// See https://aws.amazon.com/compliance/shared-responsibility-model/

/**
 * Graph helper for proactive notification targeting.
 *
 * Resolves a target (user UPN/email, or "Team / Channel") to a Teams
 * conversation, ensuring the bot app is installed so a chat/channel exists,
 * then returns the conversation id + service URL needed to build a
 * Bot Framework ConversationReference.
 *
 * Uses application (app-only) Graph permissions via client credentials.
 */

const TENANT_ID = process.env.TENANT_ID!;
const NOTIFY_APP_ID = process.env.NOTIFY_BOT_APP_ID!;
const NOTIFY_APP_SECRET = process.env.NOTIFY_BOT_APP_SECRET!;
// The Teams app's external (manifest) id — used to look up the catalog app id.
const TEAMS_APP_EXTERNAL_ID = process.env.TEAMS_APP_EXTERNAL_ID!;
const GRAPH = "https://graph.microsoft.com/v1.0";

let cachedToken: { token: string; exp: number } | null = null;
let cachedCatalogAppId: string | null = null;

async function getGraphToken(): Promise<string> {
  if (cachedToken && cachedToken.exp > Date.now() + 60_000) {
    return cachedToken.token;
  }
  const resp = await fetch(
    `https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token`,
    {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "client_credentials",
        client_id: NOTIFY_APP_ID,
        client_secret: NOTIFY_APP_SECRET,
        scope: "https://graph.microsoft.com/.default",
      }),
    }
  );
  if (!resp.ok) {
    throw new Error(`Graph token failed ${resp.status}: ${(await resp.text()).slice(0, 200)}`);
  }
  const data: any = await resp.json();
  cachedToken = { token: data.access_token, exp: Date.now() + data.expires_in * 1000 };
  return data.access_token;
}

async function graphGet(path: string): Promise<any> {
  const token = await getGraphToken();
  const resp = await fetch(`${GRAPH}${path}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!resp.ok) {
    throw new Error(`Graph GET ${path} -> ${resp.status}: ${(await resp.text()).slice(0, 200)}`);
  }
  return resp.json();
}

async function graphPost(path: string, body: any): Promise<Response> {
  const token = await getGraphToken();
  return fetch(`${GRAPH}${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

/** Look up the catalog (installable) teamsApp id from the manifest external id. */
async function getCatalogAppId(): Promise<string> {
  if (cachedCatalogAppId) return cachedCatalogAppId;
  const data = await graphGet(
    `/appCatalogs/teamsApps?$filter=externalId eq '${TEAMS_APP_EXTERNAL_ID}'`
  );
  const app = data.value?.[0];
  if (!app) {
    throw new Error(
      `Teams app with externalId ${TEAMS_APP_EXTERNAL_ID} not found in catalog. ` +
        `Upload/sideload the app package first.`
    );
  }
  cachedCatalogAppId = app.id;
  return app.id;
}

export interface ResolvedTarget {
  conversationId: string;
  serviceUrl: string;
  isGroup: boolean;
  conversationType: "personal" | "channel";
}

/** Resolve a user (by UPN/email) to a 1:1 chat, installing the bot if needed. */
export async function resolveUser(upnOrEmail: string): Promise<ResolvedTarget> {
  const user = await graphGet(`/users/${encodeURIComponent(upnOrEmail)}?$select=id`);
  const userId = user.id;
  const catalogAppId = await getCatalogAppId();

  // Check if already installed for this user
  let installId: string | null = null;
  const installed = await graphGet(
    `/users/${userId}/teamwork/installedApps?$expand=teamsApp&$filter=teamsApp/id eq '${catalogAppId}'`
  );
  if (installed.value?.length) {
    installId = installed.value[0].id;
  } else {
    const resp = await graphPost(`/users/${userId}/teamwork/installedApps`, {
      "teamsApp@odata.bind": `${GRAPH}/appCatalogs/teamsApps/${catalogAppId}`,
    });
    if (resp.status !== 201 && resp.status !== 200 && resp.status !== 409) {
      throw new Error(`Install for user failed ${resp.status}: ${(await resp.text()).slice(0, 200)}`);
    }
    // Re-fetch to get the install id
    const again = await graphGet(
      `/users/${userId}/teamwork/installedApps?$expand=teamsApp&$filter=teamsApp/id eq '${catalogAppId}'`
    );
    installId = again.value?.[0]?.id;
  }
  if (!installId) throw new Error("Could not determine app installation id for user");

  const chat = await graphGet(`/users/${userId}/teamwork/installedApps/${installId}/chat`);
  return {
    conversationId: chat.id,
    serviceUrl: "https://smba.trafficmanager.net/teams/",
    isGroup: false,
    conversationType: "personal",
  };
}

/** Resolve "Team Name / Channel Name" to a channel, installing the bot in the team if needed. */
export async function resolveChannel(teamName: string, channelName: string): Promise<ResolvedTarget> {
  // Find the team (group with Team provisioning)
  const groups = await graphGet(
    `/groups?$filter=displayName eq '${teamName.replace(/'/g, "''")}'&$select=id,displayName,resourceProvisioningOptions`
  );
  const team = groups.value?.find((g: any) =>
    (g.resourceProvisioningOptions || []).includes("Team")
  ) || groups.value?.[0];
  if (!team) throw new Error(`Team '${teamName}' not found`);
  const teamId = team.id;

  const catalogAppId = await getCatalogAppId();

  // Ensure bot installed in the team
  const installed = await graphGet(
    `/teams/${teamId}/installedApps?$expand=teamsApp&$filter=teamsApp/id eq '${catalogAppId}'`
  );
  if (!installed.value?.length) {
    const resp = await graphPost(`/teams/${teamId}/installedApps`, {
      "teamsApp@odata.bind": `${GRAPH}/appCatalogs/teamsApps/${catalogAppId}`,
    });
    if (resp.status !== 201 && resp.status !== 200 && resp.status !== 409) {
      throw new Error(`Install in team failed ${resp.status}: ${(await resp.text()).slice(0, 200)}`);
    }
  }

  // Resolve channel by name
  const channels = await graphGet(
    `/teams/${teamId}/channels?$filter=displayName eq '${channelName.replace(/'/g, "''")}'`
  );
  const channel = channels.value?.[0];
  if (!channel) throw new Error(`Channel '${channelName}' not found in team '${teamName}'`);

  return {
    conversationId: channel.id,
    serviceUrl: "https://smba.trafficmanager.net/teams/",
    isGroup: true,
    conversationType: "channel",
  };
}

/** Top-level resolver: "Team / Channel" => channel, otherwise => user. */
export async function resolveTarget(target: string): Promise<ResolvedTarget> {
  if (target.includes("/")) {
    const [team, channel] = target.split("/").map((s) => s.trim());
    return resolveChannel(team, channel);
  }
  return resolveUser(target.trim());
}
