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

// DATA PROTECTION NOTE: This client passes user messages (which may contain personal
// data) to the AgentCore runtime. Handling this data may be subject to GDPR and similar
// frameworks. Under the AWS shared responsibility model, customers deploying this sample
// are responsible for meeting applicable data-protection requirements.
// See https://aws.amazon.com/compliance/shared-responsibility-model/
import { ManagedIdentityCredential, ClientAssertionCredential } from "@azure/identity";

const RUNTIME_ID = process.env.AGENTCORE_RUNTIME_ID!;
const ACCOUNT_ID = process.env.AWS_ACCOUNT_ID!;
const AWS_REGION = process.env.AWS_REGION || "us-east-1";
const RUNTIME_ENDPOINT = `https://bedrock-agentcore.${AWS_REGION}.amazonaws.com/runtimes/${RUNTIME_ID}/invocations?accountId=${ACCOUNT_ID}`;

export class AgentCoreClient {
  private credential: ClientAssertionCredential | null = null;
  private miCredential: ManagedIdentityCredential | null = null;

  private getCredential(): ClientAssertionCredential {
    if (!this.credential) {
      const miClientId = process.env.MI_CLIENT_ID!;
      const tenantId = process.env.TENANT_ID!;
      const botAppId = process.env.BOT_APP_ID!;

      this.miCredential = new ManagedIdentityCredential(miClientId);

      // Use Federated Identity Credential: MI gets a token for AzureADTokenExchange,
      // then exchanges it for a token scoped to our custom app
      this.credential = new ClientAssertionCredential(
        tenantId,
        botAppId,
        async () => {
          const miToken = await this.miCredential!.getToken("api://AzureADTokenExchange");
          return miToken.token;
        }
      );
    }
    return this.credential;
  }

  private async getEntraToken(): Promise<string> {
    const credential = this.getCredential();
    const tokenResponse = await credential.getToken(
      `api://${process.env.BOT_APP_ID}/.default`
    );
    if (!tokenResponse?.token) {
      throw new Error("Failed to acquire Entra token via managed identity federation");
    }
    return tokenResponse.token;
  }

  async invokeAgent(message: string, userId: string): Promise<string> {
    const token = await this.getEntraToken();
    const payload = JSON.stringify({ prompt: message });

    const response = await fetch(RUNTIME_ENDPOINT, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "text/event-stream",
        Authorization: `Bearer ${token}`,
      },
      body: payload,
    });

    if (!response.ok) {
      const errText = await response.text();
      throw new Error(
        `AgentCore Runtime ${response.status}: ${errText.slice(0, 200)}`
      );
    }

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
      const parsed =
        typeof data.payload === "string"
          ? JSON.parse(data.payload)
          : data.payload;
      return parsed.response || parsed.data || JSON.stringify(parsed);
    }
    return JSON.stringify(data);
  }
}
