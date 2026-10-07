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

import json
from typing import Any, Dict


def lambda_handler(event, context):
    """
    Generic Lambda handler for Bedrock AgentCore Gateway placeholder tool.

    Expected input:
        event: {
            # optional tool arguments
            "param_0": val0,
            "param_1": val1,
            ...
        }

    Context should contain:
        context.client_context.custom["bedrockAgentCoreToolName"]
        → e.g. "LambdaTarget___placeholder_tool"
    """
    try:
        extended_name = context.client_context.custom.get("bedrockAgentCoreToolName")
        tool_name = None

        # handle agentcore gateway tool naming convention
        # https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-tool-naming.html
        if extended_name and "___" in extended_name:
            tool_name = extended_name.split("___", 1)[1]

        if not tool_name:
            return _response(400, {"error": "Missing tool name"})

        if tool_name != "placeholder_tool":
            return _response(400, {"error": f"Unknown tool '{tool_name}'"})

        result = placeholder_tool(event)
        return _response(200, {"result": result})

    except Exception as e:
        return _response(500, {"system_error": str(e)})


def _response(status_code: int, body: Dict[str, Any]):
    """Consistent JSON response wrapper."""
    return {"statusCode": status_code, "body": json.dumps(body)}


def placeholder_tool(event: Dict[str, Any]):
    """
    no-op placeholder tool.

    Demonstrates argument passing from AgentCore Gateway.
    """
    return {
        "message": "Placeholder tool executed.",
        "string_param": event.get("string_param"),
        "int_param": event.get("int_param"),
        "float_array_param": event.get("float_array_param"),
        "event_args_received": event,
    }