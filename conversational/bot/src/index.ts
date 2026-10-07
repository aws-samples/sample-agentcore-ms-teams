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

// DATA PROTECTION NOTE: This bot processes Teams messages, user identifiers, and
// conversation references and routes proactive notifications — personal data under
// GDPR and similar frameworks. Under the AWS shared responsibility model, customers
// deploying this sample are responsible for meeting applicable data-protection
// requirements. See https://aws.amazon.com/compliance/shared-responsibility-model/
import * as restify from "restify";
import {
  CloudAdapter,
  ConfigurationBotFrameworkAuthentication,
  TurnContext,
  CardFactory,
  MessageFactory,
  ConversationReference,
} from "botbuilder";
import { AgentCoreBot, getConversationReferences } from "./bot";
import { validateNotifyRequest } from "./notifyAuth";
import * as dotenv from "dotenv";

dotenv.config({ path: "../.env" });
dotenv.config();

const botFrameworkAuth = new ConfigurationBotFrameworkAuthentication({
  MicrosoftAppId: process.env.BOT_APP_ID,
  MicrosoftAppPassword: process.env.BOT_APP_SECRET || "",
  MicrosoftAppTenantId: process.env.TENANT_ID,
  MicrosoftAppType: "SingleTenant",
});

const adapter = new CloudAdapter(botFrameworkAuth);

adapter.onTurnError = async (context: TurnContext, error: Error) => {
  console.error(`[onTurnError] ${error.message}`, error.stack);
  await context.sendActivity("Sorry, something went wrong. Please try again.");
};

const bot = new AgentCoreBot();

const server = restify.createServer();
server.use(restify.plugins.bodyParser());

server.post("/api/messages", async (req, res) => {
  await adapter.process(req, res, (context) => bot.run(context));
});

server.post("/api/notify", async (req, res) => {
  const { valid, error: authError } = validateNotifyRequest(req);
  if (!valid) {
    res.send(401, { error: authError });
    return;
  }

  const { title, message, conversationId } = req.body || {};

  if (!title || !message) {
    res.send(400, { error: "title and message are required" });
    return;
  }

  const references = getConversationReferences();

  let ref: Partial<ConversationReference> | undefined;
  if (conversationId) {
    ref = references.get(conversationId);
  } else {
    ref = Array.from(references.values()).find(
      (r) => r.conversation?.conversationType === "channel"
    ) || references.values().next().value;
  }

  if (!ref) {
    res.send(404, {
      error: "No conversation references. Add the bot to a team and send a message first.",
      hint: "Send @AgentCore Bot hi in a team channel",
    });
    return;
  }

  const card = CardFactory.adaptiveCard({
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
            items: [
              { type: "Image", url: "https://img.icons8.com/color/48/amazon-web-services.png", size: "Small" },
            ],
          },
          {
            type: "Column",
            width: "stretch",
            items: [
              { type: "TextBlock", text: "AgentCore Notification", weight: "Bolder", size: "Small", color: "Accent" },
              { type: "TextBlock", text: title, weight: "Bolder", size: "Medium", spacing: "None" },
            ],
          },
        ],
      },
      { type: "TextBlock", text: message, wrap: true, spacing: "Medium" },
      {
        type: "TextBlock",
        text: "Sent by Amazon Bedrock AgentCore Agent",
        size: "Small",
        isSubtle: true,
        spacing: "Medium",
      },
    ],
  });

  try {
    await adapter.continueConversationAsync(
      process.env.BOT_APP_ID!,
      ref,
      async (context) => {
        await context.sendActivity(MessageFactory.attachment(card));
      }
    );
    res.send(200, { status: "sent", target: ref.conversation?.conversationType, conversationId: ref.conversation?.id });
  } catch (error: any) {
    console.error("Proactive message failed:", error.message);
    res.send(500, { error: error.message });
  }
});

server.get("/api/conversations", async (req, res) => {
  const refs = getConversationReferences();
  const list = Array.from(refs.entries()).map(([id, ref]) => ({
    id,
    type: ref.conversation?.conversationType,
    name: ref.conversation?.name,
  }));
  res.send(200, { conversations: list, count: list.length });
});

const port = process.env.PORT || 3978;
server.listen(port, () => {
  console.log(`Bot listening on http://localhost:${port}/api/messages`);
  console.log(`Notification endpoint: http://localhost:${port}/api/notify`);
});
