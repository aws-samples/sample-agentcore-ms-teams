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

// DATA PROTECTION NOTE: This is the bot-side of the On-Behalf-Of flow. It passes
// the user's Microsoft Graph token and user identity to the AgentCore runtime,
// where the agent uses them to access the user's M365 personal data (mail,
// calendar, profile). Handling delegated access to personal data may be subject
// to GDPR and similar regulations. Under the AWS shared responsibility model,
// customers deploying this sample are responsible for meeting the applicable
// data-protection requirements. See https://aws.amazon.com/compliance/shared-responsibility-model/
import { ClientAssertionCredential, ManagedIdentityCredential, ClientSecretCredential } from "@azure/identity";

const RUNTIME_ID = process.env.AGENTCORE_RUNTIME_ID || "";
const ACCOUNT_ID = process.env.AWS_ACCOUNT_ID || "";
const AWS_REGION = process.env.AWS_REGION || "us-east-1";

export class AgentCoreOBOClient {
  private credential: ClientAssertionCredential | ClientSecretCredential | null = null;

  private getRuntimeEndpoint(): string {
    return `https://bedrock-agentcore.${AWS_REGION}.amazonaws.com/runtimes/${RUNTIME_ID}/invocations?accountId=${ACCOUNT_ID}`;
  }

  private getCredential(): ClientAssertionCredential | ClientSecretCredential {
    if (!this.credential) {
      const miClientId = process.env.MI_CLIENT_ID;
      const tenantId = process.env.TENANT_ID!;
      const appId = process.env.OBO_BOT_APP_ID!;
      if (miClientId) {
        const mi = new ManagedIdentityCredential(miClientId);
        this.credential = new ClientAssertionCredential(tenantId, appId, async () => {
          const t = await mi.getToken("api://AzureADTokenExchange");
          return t.token;
        });
      } else {
        this.credential = new ClientSecretCredential(tenantId, appId, process.env.OBO_BOT_APP_SECRET!);
      }
    }
    return this.credential;
  }

  private async getAppToken(): Promise<string> {
    const result = await this.getCredential().getToken(`api://botid-${process.env.OBO_BOT_APP_ID}/.default`);
    return result.token;
  }

  /**
   * Invoke the agent, passing the user's Microsoft Graph token in the payload.
   * The bot authenticates to AgentCore with its own app token (JWT authorizer),
   * and the agent uses the Graph token to call Graph AS the user.
   */
  async invokeAgentWithGraphToken(message: string, graphToken: string | undefined, userName: string): Promise<string> {
    const endpoint = this.getRuntimeEndpoint();
    const appToken = await this.getAppToken();

    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "text/event-stream",
        Authorization: `Bearer ${appToken}`,
      },
      body: JSON.stringify({
        prompt: message,
        user_name: userName,
        graph_token: graphToken || null,
      }),
    });

    if (!response.ok) {
      const errText = await response.text();
      throw new Error(`AgentCore Runtime ${response.status}: ${errText.slice(0, 200)}`);
    }

    return this.parseResponse(response);
  }

  private async parseResponse(response: Response): Promise<string> {
    const contentType = response.headers.get("content-type") || "";
    if (contentType.includes("text/event-stream")) {
      const text = await response.text();
      const chunks: string[] = [];
      for (const line of text.split("\n")) {
        if (line.startsWith("data: ")) {
          let chunk = line.slice(6).trim();
          try {
            chunk = JSON.parse(chunk);
          } catch {}
          chunks.push(chunk);
        }
      }
      return chunks.join("") || text;
    }

    const data: any = await response.json();
    if (data.payload) {
      const parsed = typeof data.payload === "string" ? JSON.parse(data.payload) : data.payload;
      return parsed.response || parsed.data || JSON.stringify(parsed);
    }
    return JSON.stringify(data);
  }
}
