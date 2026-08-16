# AI Platform Operator

Multi-agent automation layer for devops-lab.

## Phase 1

Builder:
- OpenAI Codex CLI
- repository edits
- tests and validation
- ai/* branches only

Human approval:
- risky infrastructure changes
- merge to main
- production/live mutations

## Planned agents

- Builder
- Reviewer
- Security
- Upgrade
- Reliability
- Architect

## Safety model

Green:
automatic repository work

Yellow:
proposal + human approval

Red:
never autonomous
