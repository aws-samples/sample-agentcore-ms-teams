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

// DATA PROTECTION NOTE: This bot processes Teams messages and stores conversation
// references (user IDs, conversation IDs) — personal data under GDPR and similar
// frameworks. Under the AWS shared responsibility model, customers deploying this
// sample are responsible for meeting applicable data-protection requirements.
// See https://aws.amazon.com/compliance/shared-responsibility-model/
import {
  ActivityHandler,
  TurnContext,
  CardFactory,
  MessageFactory,
  ConversationReference,
} from "botbuilder";
import { AgentCoreClient } from "./agentcoreClient";

const conversationReferences: Map<string, Partial<ConversationReference>> = new Map();

export function getConversationReferences() {
  return conversationReferences;
}

export class AgentCoreBot extends ActivityHandler {
  private agentClient: AgentCoreClient;

  constructor() {
    super();
    this.agentClient = new AgentCoreClient();

    this.onConversationUpdate(async (context: TurnContext, next) => {
      this.addConversationReference(context);
      await next();
    });

    this.onMessage(async (context: TurnContext, next) => {
      this.addConversationReference(context);

      const userMessage = context.activity.text?.trim();
      if (!userMessage) {
        await context.sendActivity("Please send a text message.");
        await next();
        return;
      }

      await context.sendActivity({ type: "typing" });

      try {
        const agentResponse = await this.agentClient.invokeAgent(
          userMessage,
          context.activity.from.id
        );

        const card = CardFactory.adaptiveCard({
          $schema: "http://adaptivecards.io/schemas/adaptive-card.json",
          type: "AdaptiveCard",
          version: "1.4",
          body: [
            {
              type: "TextBlock",
              text: agentResponse,
              wrap: true,
            },
            {
              type: "TextBlock",
              text: "Powered by Amazon Bedrock AgentCore",
              size: "Small",
              isSubtle: true,
            },
          ],
        });

        await context.sendActivity(MessageFactory.attachment(card));
      } catch (error: any) {
        console.error("AgentCore invocation failed:", error.message);
        await context.sendActivity(
          `I couldn't reach the AgentCore backend: ${error.message}`
        );
      }

      await next();
    });

    this.onMembersAdded(async (context: TurnContext, next) => {
      this.addConversationReference(context);
      for (const member of context.activity.membersAdded || []) {
        if (member.id !== context.activity.recipient.id) {
          await context.sendActivity(
            "Hello! I'm an AI agent powered by Amazon Bedrock AgentCore. " +
              "Send me a message and I'll respond using my AI backend."
          );
        }
      }
      await next();
    });
  }

  private addConversationReference(context: TurnContext) {
    const ref = TurnContext.getConversationReference(context.activity);
    const key = ref.conversation?.id || "default";
    conversationReferences.set(key, ref);
    // Log count only — the conversation id is a user-linked identifier (personal data).
    console.log(`Stored conversation reference (total: ${conversationReferences.size})`);
  }
}
