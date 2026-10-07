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

// DATA PROTECTION NOTE: This bot resolves and stores user identifiers (UPN/email,
// conversation references) to target proactive notifications — personal data under GDPR
// and similar frameworks. Under the AWS shared responsibility model, customers deploying
// this sample are responsible for meeting applicable data-protection requirements.
// See https://aws.amazon.com/compliance/shared-responsibility-model/
import * as restify from "restify";
import {
  CloudAdapter,
  ConfigurationBotFrameworkAuthentication,
  TurnContext,
  ActivityHandler,
  CardFactory,
  MessageFactory,
  ConversationReference,
} from "botbuilder";
import { resolveTarget } from "./graphClient";
import * as dotenv from "dotenv";

dotenv.config({ path: "../.env.notify" });
dotenv.config();

const botFrameworkAuth = new ConfigurationBotFrameworkAuthentication({
  MicrosoftAppId: process.env.NOTIFY_BOT_APP_ID,
  MicrosoftAppPassword: process.env.NOTIFY_BOT_APP_SECRET,
  MicrosoftAppTenantId: process.env.TENANT_ID,
  MicrosoftAppType: "SingleTenant",
});

const adapter = new CloudAdapter(botFrameworkAuth);
adapter.onTurnError = async (context: TurnContext, error: Error) => {
  console.error(`[onTurnError] ${error.message}`, error.stack);
};

// Minimal handler so the bot accepts messages and records refs when added.
class NotifyBot extends ActivityHandler {
  constructor() {
    super();
    this.onMembersAdded(async (context, next) => {
      await context.sendActivity(
        "I'm the AgentCore notification bot. I deliver proactive notifications sent by the agent."
      );
      await next();
    });
    this.onMessage(async (context, next) => {
      await context.sendActivity("I only deliver notifications from the AgentCore agent.");
      await next();
    });
  }
}
const bot = new NotifyBot();

const BOT_APP_ID = process.env.NOTIFY_BOT_APP_ID!;
const NOTIFY_SECRET = process.env.NOTIFY_SECRET || "";

function buildCard(title: string, message: string) {
  return CardFactory.adaptiveCard({
    $schema: "http://adaptivecards.io/schemas/adaptive-card.json",
    type: "AdaptiveCard",
    version: "1.4",
    body: [
      {
        type: "ColumnSet",
        columns: [
          {
            type: "Column",
            width: "auto",
            verticalContentAlignment: "Center",
            items: [{ type: "TextBlock", text: "🔔", size: "ExtraLarge" }],
          },
          {
            type: "Column",
            width: "stretch",
            items: [
              { type: "TextBlock", text: "AgentCore Notification", weight: "Bolder", size: "Small", color: "Accent" },
              { type: "TextBlock", text: title, weight: "Bolder", size: "Medium", spacing: "None", wrap: true },
            ],
          },
        ],
      },
      { type: "TextBlock", text: message, wrap: true, spacing: "Medium" },
      { type: "TextBlock", text: "Sent by Amazon Bedrock AgentCore Agent", size: "Small", isSubtle: true, spacing: "Medium" },
    ],
  });
}

const server = restify.createServer();
server.use(restify.plugins.bodyParser());

server.post("/api/messages", async (req, res) => {
  await adapter.process(req, res, (context) => bot.run(context));
});

/**
 * Notify endpoint called by the AgentCore agent.
 * Body: { target, title, message }  — target = user UPN/email OR "Team / Channel"
 */
server.post("/api/notify", async (req, res) => {
  // Deny by default: NOTIFY_SECRET is required. An unconfigured deployment must
  // fail closed — otherwise anyone could push notifications to any tenant user.
  if (!NOTIFY_SECRET) {
    res.send(503, { error: "NOTIFY_SECRET is not configured; refusing request" });
    return;
  }
  const auth = (req.headers["authorization"] || "").replace("Bearer ", "");
  if (auth !== NOTIFY_SECRET) {
    res.send(401, { error: "Unauthorized" });
    return;
  }

  const { target, title, message } = req.body || {};
  if (!target || !title || !message) {
    res.send(400, { error: "target, title, and message are required" });
    return;
  }

  try {
    const resolved = await resolveTarget(target);

    const ref: Partial<ConversationReference> = {
      bot: { id: `28:${BOT_APP_ID}`, name: "AgentCore Notify" },
      conversation: {
        id: resolved.conversationId,
        isGroup: resolved.isGroup,
        conversationType: resolved.conversationType,
        tenantId: process.env.TENANT_ID,
      } as any,
      channelId: "msteams",
      serviceUrl: resolved.serviceUrl,
    };

    const card = buildCard(title, message);
    await adapter.continueConversationAsync(BOT_APP_ID, ref, async (context) => {
      await context.sendActivity(MessageFactory.attachment(card));
    });

    res.send(200, { status: "sent", target, type: resolved.conversationType });
  } catch (error: any) {
    console.error("Notify failed:", error.message);
    res.send(500, { error: error.message });
  }
});

server.get("/health", (req, res, next) => {
  res.send(200, { status: "ok" });
  return next();
});

const port = process.env.PORT || 3980;
server.listen(port, () => {
  console.log(`Notify bot listening on http://localhost:${port}/api/messages`);
});
