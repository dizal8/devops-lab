# DZL Agent V8.1

DZL Agent is the orchestration layer for the DZL Console AI Workspace.

## Phase 1

Current model:

- `gpt-oss:20b`
- Ollama native `/api/chat`
- localhost only

Current SAFE tools:

- `read_file`
- `git_status`

Phase 1 intentionally does not provide:

- arbitrary shell execution
- file writes
- sudo
- kubectl writes
- git push
- systemctl
- Vault writes

## API

- `GET /agent/health`
- `GET /agent/status`
- `GET /agent/events`
- `POST /agent/tasks`

## Events

The backend records observable engineering activity:

- TASK
- PLAN
- READ
- SEARCH
- TOOL
- COMMAND
- EDIT
- VALIDATE
- TEST
- WARNING
- ERROR
- RESULT
- STATE

No private chain-of-thought is exposed.

## Goal

The browser UI will consume these events and display a live workflow similar to:

READ
→ ANALYZE
→ PLAN
→ EDIT
→ VALIDATE
→ RESULT

Phase 1 validates the native multi-turn Ollama tool loop before write/edit tools are enabled.
