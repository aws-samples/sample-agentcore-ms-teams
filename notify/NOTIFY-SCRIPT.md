# `notify.py` — send Teams notifications via the notify agent

CLI wrapper that invokes the `notifyAgent` Bedrock AgentCore runtime
(us-east-1, IAM/SigV4 auth). The agent calls the teams-notify-bot, which
resolves the target via Microsoft Graph and delivers a proactive Adaptive Card.

## Prereqs
- AWS creds for account `111122223333` (SigV4 — no Entra token needed).
- `boto3` installed (`pip install boto3==1.35.0`).
- `notify/.env` populated (`NOTIFY_AGENT_RUNTIME_ID`, `AWS_REGION`) — already set.

## Usage

```bash
# Structured: explicit target + message (+ optional title)
./notify.py --to jane@example.com -t "CI" -m "Build #42 passed"

# Channel target
./notify.py --to "JP / General" -t "Release" -m "Deploy complete"

# Natural language (agent extracts target/title/message)
./notify.py "notify jane@example.com that the build passed"

# Message body from stdin (good for piping job output)
echo "Nightly job finished" | ./notify.py --to jane@example.com -t "Cron"
```

Targets are either a user email/UPN or a channel as `Team Name / Channel Name`.

> **Privacy:** when run interactively (or with `--verbose`), the full agent reply is
> printed and may contain personal data (emails, message text) echoed from the prompt
> or recalled by the agent. Don't run it on shared or logged terminals. When output is
> piped/redirected (e.g. CI), only a non-sensitive summary is printed. Customers are
> responsible for applicable data-protection requirements under the AWS shared
> responsibility model (https://aws.amazon.com/compliance/shared-responsibility-model/).

## Flags
| Flag | Meaning |
|------|---------|
| `--to` | Target user (email/UPN) or `Team / Channel`. |
| `-m`, `--message` | Body text (or pipe via stdin). |
| `-t`, `--title` | Optional card title. |
| `--runtime-id` | Override runtime id/ARN (default from `.env`). |
| `--region` | Override AWS region (default from `.env`). |
| `--session-id` | Override runtime session id (default: random). |

Positional args form a natural-language prompt instead of `--to/--message`.
