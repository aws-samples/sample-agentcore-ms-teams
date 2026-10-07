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

// DATA PROTECTION NOTE: This bot handles the user's delegated Microsoft Graph token
// and passes it to the agent to access personal data (email, calendar, profile) —
// regulated under GDPR and similar frameworks. Under the AWS shared responsibility
// model, customers deploying this sample are responsible for meeting applicable
// data-protection requirements. https://aws.amazon.com/compliance/shared-responsibility-model/
import { TurnContext, CardFactory, MessageFactory } from "botbuilder";
import { Application, TurnState } from "@microsoft/teams-ai";
import { AgentCoreOBOClient } from "./agentcoreClient";
import { AUTH_SETTING } from "./index";

export function registerHandlers(app: Application<TurnState>) {
  const agentClient = new AgentCoreOBOClient();

  app.authentication.get(AUTH_SETTING).onUserSignInSuccess(async (context, _state) => {
    await context.sendActivity("✅ Signed in! Now processing your request...");
  });

  app.authentication.get(AUTH_SETTING).onUserSignInFailure(async (context, _state, error) => {
    await context.sendActivity(`Sign-in failed: ${error.message}. Try sending your message again.`);
  });

  app.message(/.*/, async (context: TurnContext, state: TurnState) => {
    const userMessage = context.activity.text?.trim() ?? "";
    if (!userMessage) return;

    // teams-ai has already completed SSO by the time we get here.
    // The user's Microsoft Graph token is in state.temp.authTokens.
    const graphToken = (state.temp as any).authTokens?.[AUTH_SETTING];
    const userName = context.activity.from.name ?? "user";

    await context.sendActivity({ type: "typing" });

    try {
      // Pass the user's Graph token to the agent. The agent calls Graph AS the user.
      const agentResponse = await agentClient.invokeAgentWithGraphToken(
        userMessage,
        graphToken,
        userName
      );

      const card = CardFactory.adaptiveCard({
        $schema: "http://adaptivecards.io/schemas/adaptive-card.json",
        type: "AdaptiveCard",
        version: "1.4",
        body: [
          { type: "TextBlock", text: agentResponse, wrap: true },
          {
            type: "TextBlock",
            text: graphToken
              ? `Acting on behalf of ${userName} (delegated identity)`
              : "No user token available",
            size: "Small",
            isSubtle: true,
          },
        ],
      });

      await context.sendActivity(MessageFactory.attachment(card));
    } catch (error: any) {
      console.error("Agent invocation failed:", error.message);
      await context.sendActivity(`Error: ${error.message}`);
    }
  });
}
