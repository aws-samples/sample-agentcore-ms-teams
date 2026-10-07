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

"""AgentCore Meeting Assistant Agent.

A meeting copilot that:
  - reads the user's Teams meeting transcript via Microsoft Graph (delegated,
    using the user's own token passed in the payload — same pattern as the OBO demo)
  - summarizes meetings and extracts decisions/action items
  - SAVES context to AgentCore Memory (short-term events + long-term facts)
  - RECALLS prior meeting context across sessions

This is the first demo that uses AgentCore Memory. The Memory resource id is
provided via the MEMORY_ID env var (created by infra-meeting/deploy-aws-meeting.sh).

DATA PROTECTION NOTE: This agent processes personal data — user profile, calendar
events, and meeting transcripts (spoken conversation content). Handling this data
may be subject to GDPR and similar frameworks. Under the AWS shared responsibility
model, customers deploying this sample are responsible for meeting applicable
data-protection requirements. See https://aws.amazon.com/compliance/shared-responsibility-model/
"""

import os
import re
import json
import contextvars
from datetime import datetime, timezone
import httpx
from strands import Agent, tool
from strands.models import BedrockModel
from bedrock_agentcore import BedrockAgentCoreApp


def _sanitize_id(value: str, fallback: str) -> str:
    """AgentCore Memory actor/session ids must be reasonably short and use a
    limited character set. Teams meeting/user ids contain ':', '@', etc. and can
    be very long, so normalize to [A-Za-z0-9_-], cap length, and fall back."""
    if not value:
        return fallback
    cleaned = re.sub(r"[^A-Za-z0-9_-]", "-", value)
    cleaned = cleaned.strip("-")[:100]
    return cleaned or fallback

MEMORY_ID = os.getenv("MEMORY_ID", "")
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")

# Per-request context: the user's Graph token, their id (actor), and the meeting (session)
_ctx: contextvars.ContextVar = contextvars.ContextVar("ctx", default={})


def _graph_get(path: str, accept: str = "application/json") -> httpx.Response:
    token = _ctx.get().get("graph_token")
    if not token:
        raise ValueError("No Graph token available for this request")
    return httpx.get(
        f"https://graph.microsoft.com/v1.0{path}",
        headers={"Authorization": f"Bearer {token}", "Accept": accept},
        timeout=20,
    )


def _memory_client():
    from bedrock_agentcore.memory import MemoryClient
    return MemoryClient(region_name=AWS_REGION)


def _actor_session():
    c = _ctx.get()
    return c.get("actor_id", "unknown-user"), c.get("session_id", "default-session")


# ---------------------------------------------------------------------------
# Transcript tools (delegated Graph, acting as the user)
# ---------------------------------------------------------------------------
@tool
def summarize_meeting_transcript(join_url: str) -> str:
    """Fetch and return the transcript text of a Teams meeting so it can be summarized.

    Args:
        join_url: The Teams meeting join URL (the agent will resolve it to a meeting).
    """
    if not _ctx.get().get("graph_token"):
        return "You're not signed in. Open the meeting side panel and sign in first."

    # Resolve onlineMeeting from join URL
    try:
        filt = join_url.replace("'", "''")
        meetings = _graph_get(f"/me/onlineMeetings?$filter=JoinWebUrl eq '{filt}'")
    except Exception as e:
        return f"Failed to resolve meeting: {type(e).__name__}: {e}"
    if meetings.status_code != 200:
        return f"Meeting lookup failed: {meetings.status_code} - {meetings.text[:200]}"
    vals = meetings.json().get("value", [])
    if not vals:
        return "No meeting found for that join URL (are you the organizer?)."
    meeting_id = vals[0]["id"]

    # List transcripts
    tr = _graph_get(f"/me/onlineMeetings/{meeting_id}/transcripts")
    if tr.status_code != 200:
        return f"Transcript list failed: {tr.status_code} - {tr.text[:200]}"
    transcripts = tr.json().get("value", [])
    if not transcripts:
        return "No transcript available. Was transcription turned on, and has the meeting ended?"

    # Fetch the latest transcript content (VTT)
    tid = transcripts[-1]["id"]
    content = _graph_get(
        f"/me/onlineMeetings/{meeting_id}/transcripts/{tid}/content?$format=text/vtt",
        accept="text/vtt",
    )
    if content.status_code != 200:
        return f"Transcript content failed: {content.status_code} - {content.text[:200]}"

    vtt = content.text
    # Return a trimmed transcript for the model to summarize
    return f"TRANSCRIPT (VTT, meeting {meeting_id}):\n{vtt[:12000]}"


# ---------------------------------------------------------------------------
# Memory tools
# ---------------------------------------------------------------------------
@tool
def save_meeting_note(note: str) -> str:
    """Save an important note, decision, or action item from this meeting to long-term memory.

    Args:
        note: The note/decision/action-item text to remember for future sessions.
    """
    if not MEMORY_ID:
        return "Memory is not configured (MEMORY_ID missing)."
    actor_id, session_id = _actor_session()
    try:
        client = _memory_client()
        # Write as a USER turn (+ ASSISTANT ack) so the SEMANTIC strategy extracts
        # the fact into long-term memory. Assistant-only events are not extracted.
        client.create_event(
            memory_id=MEMORY_ID,
            actor_id=actor_id,
            session_id=session_id,
            messages=[
                (f"Please remember this for future meetings: {note}", "USER"),
                ("Saved to your long-term meeting memory.", "ASSISTANT"),
            ],
            event_timestamp=datetime.now(timezone.utc),
        )
        return f"Saved to memory: {note[:80]}"
    except Exception as e:
        return f"Failed to save note: {type(e).__name__}: {str(e)[:200]}"


@tool
def recall_context(query: str) -> str:
    """Recall relevant notes/decisions from this user's past meetings.

    Args:
        query: What to search for in prior meeting memory.
    """
    if not MEMORY_ID:
        return "Memory is not configured (MEMORY_ID missing)."
    actor_id, _ = _actor_session()
    try:
        client = _memory_client()
        results = client.retrieve_memories(
            memory_id=MEMORY_ID,
            namespace=f"/users/{actor_id}/facts/",
            query=query,
            top_k=5,
        )
        if not results:
            return "No relevant prior context found."
        items = []
        for r in results:
            text = (r.get("content", {}) or {}).get("text") or json.dumps(r)[:200]
            items.append(f"- {text}")
        return "Recalled context:\n" + "\n".join(items)
    except Exception as e:
        return f"Failed to recall context: {type(e).__name__}: {str(e)[:200]}"


app = BedrockAgentCoreApp()


@app.entrypoint
async def invoke(payload, context):
    message = payload.get("prompt", payload.get("message", ""))
    _ctx.set({
        "graph_token": payload.get("graph_token"),
        "actor_id": _sanitize_id(payload.get("user_id", ""), "unknown-user"),
        "session_id": _sanitize_id(payload.get("meeting_id", ""), "default-session"),
    })

    # Conversation history: the client sends recent turns so the agent has context.
    # Each item: {"role": "user"|"assistant", "content": "..."}
    history = payload.get("history", [])
    messages = []
    for turn in history[-12:]:
        role = turn.get("role")
        content = turn.get("content", "")
        if role in ("user", "assistant") and content:
            messages.append({"role": role, "content": [{"text": content}]})

    model = BedrockModel(model_id="us.anthropic.claude-sonnet-4-6")
    agent = Agent(
        model=model,
        messages=messages,
        system_prompt=(
            "You are a Microsoft Teams meeting assistant. You help the signed-in user "
            "during and after meetings. You can: summarize a meeting transcript "
            "(summarize_meeting_transcript with the join URL), save important notes/"
            "decisions/action-items to long-term memory (save_meeting_note), and recall "
            "context from the user's past meetings (recall_context). When you summarize a "
            "meeting, proactively save the key decisions and action items to memory. "
            "Use the conversation history to understand follow-up requests like 'try again' "
            "or 'save that'. Always act using the user's own delegated identity."
        ),
        tools=[summarize_meeting_transcript, save_meeting_note, recall_context],
    )

    stream = agent.stream_async(message)
    async for event in stream:
        if "data" in event and isinstance(event["data"], str):
            yield event["data"]


if __name__ == "__main__":
    app.run()
