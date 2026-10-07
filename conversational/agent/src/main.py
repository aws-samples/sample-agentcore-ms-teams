# Copyright 2026 Amazon.com, Inc. or its affiliates
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""AgentCore Runtime entry point.

When deployed to AgentCore Runtime, this is the handler that receives
invocations from the Gateway.

DATA PROTECTION NOTE: This handler receives user messages, which may contain
personal data regulated under GDPR and similar frameworks. Under the AWS shared
responsibility model, customers deploying this sample are responsible for
applicable data-protection requirements. See https://aws.amazon.com/compliance/shared-responsibility-model/
"""

import json
import logging
import os
from bedrock_agentcore.runtime import RuntimeApp, InvokeAgentRequest, InvokeAgentResponse

from src.agent import create_agent

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = RuntimeApp()
agent = create_agent()


@app.invoke_agent()
async def handle_invoke(request: InvokeAgentRequest) -> InvokeAgentResponse:
    """Handle inbound agent invocation from Gateway."""
    payload = json.loads(request.payload) if isinstance(request.payload, str) else request.payload
    user_message = payload.get("message", "")

    # Log only metadata, never user message content (may contain PII).
    logger.info("Received message (%d chars)", len(user_message))

    result = agent(user_message)
    response_text = str(result.message) if hasattr(result, "message") else str(result)

    return InvokeAgentResponse(
        payload=json.dumps({
            "response": response_text,
            "session_id": request.session_id,
        })
    )


if __name__ == "__main__":
    # This runs inside the AgentCore Runtime container, which must listen on all
    # interfaces to receive invocations; network exposure is controlled by the
    # AgentCore network configuration, not by the bind address. Overridable via HOST.
    host = os.environ.get("HOST", "0.0.0.0")  # nosec B104
    app.run(host=host, port=int(os.environ.get("PORT", "8000")))
