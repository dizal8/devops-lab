#!/usr/bin/env python3

import json
import os
import signal
import subprocess
import threading
import time
import urllib.request
import uuid

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


HOST = "127.0.0.1"
PORT = 7684

REPO = Path("/home/dizal/devops-lab").resolve()
STATE_DIR = REPO / "web-ops-console/agent/state"
STATE_FILE = STATE_DIR / "state.json"

OLLAMA_URL = "http://127.0.0.1:11434/api/chat"
MODEL = os.environ.get("DZL_AGENT_MODEL", "gpt-oss:20b")

# DZL_AGENT_CORS_V1
ALLOWED_ORIGINS = {
    "https://app.lab01.dzl.ro",
    "https://dzl.ro",
}

LOCK = threading.RLock()

WORKER = None
STOP_EVENT = threading.Event()

APPROVAL_EVENT = threading.Event()
APPROVAL_DECISION = None


STATE = {
    "agent_state": "READY",
    "mode": "SAFE",
    "model": MODEL,
    "repo": str(REPO),
    "task": None,
    "pending_approval": None,
    "events": [],
}


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def save_state():
    STATE_DIR.mkdir(parents=True, exist_ok=True)

    tmp = STATE_FILE.with_suffix(".tmp")

    tmp.write_text(
        json.dumps(
            STATE,
            indent=2,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    tmp.replace(STATE_FILE)


def load_state():
    if not STATE_FILE.exists():
        return

    try:
        data = json.loads(
            STATE_FILE.read_text(
                encoding="utf-8"
            )
        )

        STATE["events"] = data.get(
            "events",
            [],
        )[-1000:]

        STATE["task"] = data.get("task")

        # Never restore a stale approval after restart.
        STATE["pending_approval"] = None

        if data.get("agent_state") in (
            "BUSY",
            "WAITING_APPROVAL",
        ):
            STATE["agent_state"] = "READY"

    except Exception:
        pass


def event(
    event_type,
    status,
    label,
    target=None,
    summary=None,
):
    item = {
        "id": str(uuid.uuid4()),
        "timestamp": now(),
        "type": event_type,
        "status": status,
        "label": label,
        "target": target,
        "summary": summary,
    }

    with LOCK:
        STATE["events"].append(item)
        STATE["events"] = STATE["events"][-1000:]
        save_state()

    return item


def git_branch():
    try:
        return subprocess.check_output(
            [
                "git",
                "branch",
                "--show-current",
            ],
            cwd=REPO,
            text=True,
            timeout=5,
        ).strip()

    except Exception:
        return "UNKNOWN"


def safe_path(raw):
    if not raw:
        raise ValueError("path required")

    p = Path(raw)

    if not p.is_absolute():
        p = REPO / p

    p = p.resolve()

    if p != REPO and REPO not in p.parents:
        raise ValueError(
            "path outside repository"
        )

    return p


def truncate(text, limit=50000):
    if len(text) <= limit:
        return text

    return (
        text[:limit]
        + "\n...[TRUNCATED]"
    )


def tool_read_file(arguments):
    p = safe_path(
        arguments.get("path", "")
    )

    event(
        "READ",
        "running",
        "Read file",
        str(p),
    )

    if not p.is_file():
        raise FileNotFoundError(str(p))

    content = p.read_text(
        encoding="utf-8",
        errors="replace",
    )

    content = truncate(content)

    event(
        "READ",
        "success",
        "Read file",
        str(p),
        f"{len(content)} characters",
    )

    return content


def tool_search_files(arguments):
    pattern = str(
        arguments.get("pattern", "")
    ).strip()

    if not pattern:
        raise ValueError(
            "search pattern required"
        )

    raw_path = arguments.get(
        "path",
        ".",
    )

    root = safe_path(raw_path)

    event(
        "SEARCH",
        "running",
        "Search repository",
        str(root),
        pattern,
    )

    result = subprocess.run(
        [
            "rg",
            "-n",
            "--no-heading",
            "--color",
            "never",
            pattern,
            str(root),
        ],
        cwd=REPO,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )

    if result.returncode not in (0, 1):
        raise RuntimeError(
            result.stderr.strip()
            or f"rg exit={result.returncode}"
        )

    output = truncate(
        result.stdout,
        30000,
    )

    event(
        "SEARCH",
        "success",
        "Search repository",
        str(root),
        (
            f"pattern={pattern!r}; "
            f"matches={'yes' if output else 'no'}"
        ),
    )

    return output or "NO_MATCHES"


def tool_git_status(arguments):
    event(
        "COMMAND",
        "running",
        "git status --short",
        str(REPO),
    )

    result = subprocess.run(
        [
            "git",
            "status",
            "--short",
        ],
        cwd=REPO,
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )

    output = result.stdout

    if result.stderr:
        output += result.stderr

    event(
        "COMMAND",
        (
            "success"
            if result.returncode == 0
            else "failed"
        ),
        "git status --short",
        str(REPO),
        f"exit={result.returncode}",
    )

    return output


def request_approval(
    tool_name,
    arguments,
    preview,
):
    global APPROVAL_DECISION

    approval_id = str(uuid.uuid4())

    with LOCK:
        APPROVAL_DECISION = None
        APPROVAL_EVENT.clear()

        STATE["agent_state"] = (
            "WAITING_APPROVAL"
        )

        STATE["pending_approval"] = {
            "id": approval_id,
            "tool": tool_name,
            "arguments": arguments,
            "preview": preview,
            "created_at": now(),
        }

        save_state()

    event(
        "APPROVAL",
        "queued",
        f"Approval required: {tool_name}",
        arguments.get("path"),
        preview,
    )

    while True:
        if STOP_EVENT.is_set():
            raise RuntimeError(
                "task stopped while waiting "
                "for approval"
            )

        if APPROVAL_EVENT.wait(0.5):
            break

    with LOCK:
        decision = APPROVAL_DECISION

        STATE["pending_approval"] = None

        if decision == "approve":
            STATE["agent_state"] = "BUSY"
        else:
            STATE["agent_state"] = "BUSY"

        save_state()

    if STOP_EVENT.is_set() or decision is None:
        event(
            "APPROVAL",
            "stopped",
            f"Cancelled by stop: {tool_name}",
            arguments.get("path"),
        )

        raise RuntimeError(
            "task stopped by operator"
        )

    if decision != "approve":
        event(
            "APPROVAL",
            "stopped",
            f"Rejected: {tool_name}",
            arguments.get("path"),
        )

        return False

    event(
        "APPROVAL",
        "success",
        f"Approved: {tool_name}",
        arguments.get("path"),
    )

    return True


def tool_write_file(arguments):
    p = safe_path(
        arguments.get("path", "")
    )

    content = str(
        arguments.get("content", "")
    )

    preview = (
        f"WRITE {p}\n"
        f"bytes={len(content.encode('utf-8'))}\n\n"
        f"{truncate(content, 4000)}"
    )

    approved = request_approval(
        "write_file",
        {
            "path": str(p),
            "content": content,
        },
        preview,
    )

    if not approved:
        return "WRITE_REJECTED_BY_OPERATOR"

    event(
        "EDIT",
        "running",
        "Write file",
        str(p),
    )

    p.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    p.write_text(
        content,
        encoding="utf-8",
    )

    event(
        "EDIT",
        "success",
        "Write file",
        str(p),
        f"{len(content)} characters",
    )

    return (
        "APPROVED_AND_EXECUTED: true\n"
        "tool=write_file\n"
        f"path={p}\n"
        f"WRITE_OK: {p}\n"
        f"characters={len(content)}"
    )


def tool_edit_file(arguments):
    p = safe_path(
        arguments.get("path", "")
    )

    old_text = str(
        arguments.get("old_text", "")
    )

    new_text = str(
        arguments.get("new_text", "")
    )

    if not p.is_file():
        raise FileNotFoundError(str(p))

    if not old_text:
        raise ValueError(
            "old_text required"
        )

    current = p.read_text(
        encoding="utf-8",
        errors="replace",
    )

    count = current.count(old_text)

    if count != 1:
        raise ValueError(
            "edit_file requires old_text "
            f"to match exactly once; matches={count}"
        )

    preview = (
        f"EDIT {p}\n\n"
        f"--- OLD ---\n"
        f"{truncate(old_text, 3000)}\n\n"
        f"--- NEW ---\n"
        f"{truncate(new_text, 3000)}"
    )

    approved = request_approval(
        "edit_file",
        {
            "path": str(p),
            "old_text": old_text,
            "new_text": new_text,
        },
        preview,
    )

    if not approved:
        return "EDIT_REJECTED_BY_OPERATOR"

    updated = current.replace(
        old_text,
        new_text,
        1,
    )

    event(
        "EDIT",
        "running",
        "Edit file",
        str(p),
    )

    p.write_text(
        updated,
        encoding="utf-8",
    )

    event(
        "EDIT",
        "success",
        "Edit file",
        str(p),
        "exact replacement applied",
    )

    return f"EDIT_OK: {p}"


TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": (
                "Read a text file inside "
                "/home/dizal/devops-lab."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                    }
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "search_files",
            "description": (
                "Search text recursively inside "
                "the repository using ripgrep."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "pattern": {
                        "type": "string",
                    },
                    "path": {
                        "type": "string",
                    },
                },
                "required": ["pattern"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "git_status",
            "description": (
                "Run exactly git status --short "
                "in the repository."
            ),
            "parameters": {
                "type": "object",
                "properties": {},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": (
                "Create or replace a text file "
                "inside the repository. "
                "Operator approval is required."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                    },
                    "content": {
                        "type": "string",
                    },
                },
                "required": [
                    "path",
                    "content",
                ],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "edit_file",
            "description": (
                "Replace one exact text fragment "
                "inside a repository file. "
                "Operator approval is required."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                    },
                    "old_text": {
                        "type": "string",
                    },
                    "new_text": {
                        "type": "string",
                    },
                },
                "required": [
                    "path",
                    "old_text",
                    "new_text",
                ],
            },
        },
    },
]


def execute_tool(name, arguments):
    event(
        "TOOL",
        "running",
        name,
        summary=json.dumps(
            arguments,
            ensure_ascii=False,
        )[:4000],
    )

    if name == "read_file":
        result = tool_read_file(arguments)

    elif name == "search_files":
        result = tool_search_files(arguments)

    elif name == "git_status":
        result = tool_git_status(arguments)

    elif name == "write_file":
        result = tool_write_file(arguments)

    elif name == "edit_file":
        result = tool_edit_file(arguments)

    else:
        event(
            "ERROR",
            "failed",
            "Unknown tool",
            name,
        )

        raise ValueError(
            f"Unknown tool: {name}"
        )

    rejected_results = {
        "WRITE_REJECTED_BY_OPERATOR",
        "EDIT_REJECTED_BY_OPERATOR",
    }

    if result in rejected_results:
        event(
            "TOOL",
            "stopped",
            name,
            summary="rejected by operator",
        )
    else:
        event(
            "TOOL",
            "success",
            name,
        )

    return result


def ollama_chat(messages):
    payload = {
        "model": MODEL,
        "messages": messages,
        "tools": TOOLS,
        "stream": False,
        "options": {
            "temperature": 0,
            "num_ctx": 8192,
        },
        "keep_alive": "15m",
    }

    request = urllib.request.Request(
        OLLAMA_URL,
        data=json.dumps(payload).encode(
            "utf-8"
        ),
        headers={
            "Content-Type":
                "application/json",
        },
        method="POST",
    )

    with urllib.request.urlopen(
        request,
        timeout=300,
    ) as response:
        return json.loads(
            response.read().decode(
                "utf-8"
            )
        )


def run_task(task_id, instruction):
    global WORKER

    STOP_EVENT.clear()

    with LOCK:
        STATE["agent_state"] = "BUSY"

        STATE["task"] = {
            "id": task_id,
            "instruction": instruction,
            "status": "running",
            "started_at": now(),
            "finished_at": None,
            "result": None,
        }

        STATE["pending_approval"] = None

        save_state()

    event(
        "TASK",
        "running",
        "Agent task started",
        summary=instruction,
    )

    system = """
You are DZL Agent running in SAFE mode.

Repository:
/home/dizal/devops-lab

You are an implementation engineering agent.

Available tools:

read_file
search_files
git_status
write_file
edit_file

Use ONLY those exact tool names.

Do not invent:
container.exec
Bash
shell
terminal
sudo
kubectl
systemctl

READ, SEARCH and git_status are read-only.

write_file and edit_file require operator approval automatically.

When a write/edit is rejected:
do not retry the same modification unless the user explicitly asks.

Do not commit.
Do not push.
Do not deploy.
Do not run arbitrary shell commands.

Inspect before modifying.
Make minimal coherent changes.
Complete the requested workflow before the final response.
""".strip()

    messages = [
        {
            "role": "system",
            "content": system,
        },
        {
            "role": "user",
            "content": instruction,
        },
    ]

    final_text = None

    # DZL_AGENT_V811_APPROVAL_CONTINUATION
    mutation_executed = False
    continuation_guard_used = False

    try:
        for turn in range(1, 13):
            if STOP_EVENT.is_set():
                raise RuntimeError(
                    "task stopped by operator"
                )

            event(
                "STATE",
                "running",
                f"Model turn {turn}",
            )

            response = ollama_chat(
                messages
            )

            message = response.get(
                "message",
                {},
            )

            calls = (
                message.get("tool_calls")
                or []
            )

            assistant_message = {
                "role": "assistant",
                "content": message.get(
                    "content",
                    "",
                ),
            }

            if calls:
                assistant_message[
                    "tool_calls"
                ] = calls

            messages.append(
                assistant_message
            )

            if not calls:
                candidate_final = (
                    message.get(
                        "content",
                        "",
                    ).strip()
                )

                # DZL_AGENT_V811_FINAL_GUARD
                stale_approval_phrases = (
                    "wait for operator approval",
                    "waiting for operator approval",
                    "wait for approval",
                    "waiting for approval",
                    "awaiting approval",
                    "please confirm",
                )

                stale_final = (
                    mutation_executed
                    and any(
                        phrase
                        in candidate_final.lower()
                        for phrase
                        in stale_approval_phrases
                    )
                )

                if (
                    stale_final
                    and not continuation_guard_used
                ):
                    continuation_guard_used = True

                    event(
                        "STATE",
                        "running",
                        "Approval continuation guard",
                        summary=(
                            "Rejected stale final response; "
                            "approved mutation already executed"
                        ),
                    )

                    messages.append(
                        {
                            "role": "user",
                            "content": (
                                "DZL ORCHESTRATOR STATE: "
                                "The previous write_file operation "
                                "was already approved by the operator "
                                "and executed successfully. "
                                "Do not request approval again for "
                                "that completed write. Continue the "
                                "original task now. Perform every "
                                "remaining requested read-back or "
                                "verification step using the "
                                "available read-only tools, then "
                                "return the requested final result."
                            ),
                        }
                    )

                    continue

                final_text = candidate_final

                event(
                    "RESULT",
                    "success",
                    "Agent final response",
                    summary=final_text,
                )

                break

            for call in calls:
                if STOP_EVENT.is_set():
                    raise RuntimeError(
                        "task stopped by operator"
                    )

                fn = call.get(
                    "function",
                    {},
                )

                name = fn.get(
                    "name",
                    "",
                )

                arguments = (
                    fn.get("arguments")
                    or {}
                )

                if isinstance(
                    arguments,
                    str,
                ):
                    arguments = json.loads(
                        arguments
                    )

                result = execute_tool(
                    name,
                    arguments,
                )

                messages.append(
                    {
                        "role": "tool",
                        "content": result,
                    }
                )

                # DZL_AGENT_V811_TOOL_CONTINUATION
                if (
                    name == "write_file"
                    and result.startswith(
                        "APPROVED_AND_EXECUTED: true"
                    )
                ):
                    mutation_executed = True

                    event(
                        "STATE",
                        "success",
                        "Approved mutation executed",
                        target=arguments.get("path"),
                        summary="write_file",
                    )

                    messages.append(
                        {
                            "role": "user",
                            "content": (
                                "DZL ORCHESTRATOR STATE: "
                                "write_file was approved by the "
                                "operator and has already executed "
                                "successfully. The approval is "
                                "consumed. Do not ask for approval "
                                "again for this completed write. "
                                "Continue the original workflow. "
                                "If read-back or verification was "
                                "requested, perform it before the "
                                "final response."
                            ),
                        }
                    )

        else:
            raise RuntimeError(
                "Agent exceeded Phase 2 "
                "turn limit"
            )

        with LOCK:
            STATE["agent_state"] = "READY"
            STATE["task"]["status"] = (
                "success"
            )
            STATE["task"][
                "finished_at"
            ] = now()
            STATE["task"]["result"] = (
                final_text
            )
            STATE["pending_approval"] = None

            save_state()

        event(
            "TASK",
            "success",
            "Agent task completed",
        )

    except Exception as exc:
        if STOP_EVENT.is_set():
            event(
                "TASK",
                "stopped",
                "Agent task stopped",
                summary=str(exc),
            )
        else:
            event(
                "ERROR",
                "failed",
                type(exc).__name__,
                summary=str(exc),
            )

        with LOCK:
            if STOP_EVENT.is_set():
                STATE["agent_state"] = (
                    "READY"
                )
                task_status = "stopped"
            else:
                STATE["agent_state"] = (
                    "ERROR"
                )
                task_status = "failed"

            if STATE.get("task"):
                STATE["task"][
                    "status"
                ] = task_status

                STATE["task"][
                    "finished_at"
                ] = now()

                STATE["task"][
                    "result"
                ] = str(exc)

            STATE["pending_approval"] = None

            save_state()

    finally:
        WORKER = None
        APPROVAL_EVENT.set()


class Handler(
    BaseHTTPRequestHandler
):

    def cors(self):
        origin = self.headers.get(
            "Origin",
            "",
        )

        if origin in ALLOWED_ORIGINS:
            self.send_header(
                "Access-Control-Allow-Origin",
                origin,
            )

            self.send_header(
                "Vary",
                "Origin",
            )

        self.send_header(
            "Access-Control-Allow-Methods",
            "GET,POST,OPTIONS",
        )

        self.send_header(
            "Access-Control-Allow-Headers",
            "Content-Type",
        )

        self.send_header(
            "Cache-Control",
            "no-store",
        )

    def do_OPTIONS(self):
        origin = self.headers.get(
            "Origin",
            "",
        )

        if origin not in ALLOWED_ORIGINS:
            self.send_response(403)
            self.end_headers()
            return

        self.send_response(204)
        self.cors()
        self.end_headers()

    def log_message(
        self,
        fmt,
        *args,
    ):
        print(
            f"[{self.log_date_time_string()}] "
            f"{self.address_string()} "
            f"{fmt % args}",
            flush=True,
        )

    def json_response(
        self,
        code,
        data,
    ):
        body = json.dumps(
            data,
            ensure_ascii=False,
        ).encode("utf-8")

        self.send_response(code)

        self.cors()

        self.send_header(
            "Content-Type",
            "application/json; charset=utf-8",
        )

        self.send_header(
            "Content-Length",
            str(len(body)),
        )

        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        size = int(
            self.headers.get(
                "Content-Length",
                "0",
            )
        )

        if size <= 0:
            return {}

        return json.loads(
            self.rfile.read(
                size
            ).decode("utf-8")
        )

    def do_GET(self):
        if self.path == "/agent/health":
            self.json_response(
                200,
                {
                    "ok": True,
                    "service": "dzl-agent",
                    "model": MODEL,
                },
            )
            return

        if self.path == "/agent/status":
            with LOCK:
                data = {
                    "state":
                        STATE["agent_state"],
                    "mode":
                        STATE["mode"],
                    "model":
                        MODEL,
                    "repo":
                        str(REPO),
                    "branch":
                        git_branch(),
                    "task":
                        STATE["task"],
                    "pending_approval":
                        STATE[
                            "pending_approval"
                        ],
                }

            self.json_response(
                200,
                data,
            )
            return

        if self.path == "/agent/events":
            with LOCK:
                events = list(
                    STATE["events"]
                )

            self.json_response(
                200,
                {
                    "events": events,
                },
            )
            return

        self.json_response(
            404,
            {
                "error": "not found",
            },
        )

    def do_POST(self):
        global WORKER
        global APPROVAL_DECISION

        if self.path == "/agent/tasks":
            payload = self.read_json()

            instruction = str(
                payload.get(
                    "instruction",
                    "",
                )
            ).strip()

            if not instruction:
                self.json_response(
                    400,
                    {
                        "error":
                            "instruction required",
                    },
                )
                return

            with LOCK:
                if (
                    WORKER
                    and WORKER.is_alive()
                ):
                    self.json_response(
                        409,
                        {
                            "error":
                                "agent busy",
                        },
                    )
                    return

                task_id = str(
                    uuid.uuid4()
                )

                WORKER = threading.Thread(
                    target=run_task,
                    args=(
                        task_id,
                        instruction,
                    ),
                    daemon=True,
                )

                WORKER.start()

            self.json_response(
                202,
                {
                    "accepted": True,
                    "task_id": task_id,
                },
            )
            return

        if self.path in (
            "/agent/approve",
            "/agent/reject",
        ):
            payload = self.read_json()

            approval_id = str(
                payload.get(
                    "approval_id",
                    "",
                )
            )

            with LOCK:
                pending = STATE.get(
                    "pending_approval"
                )

                if not pending:
                    self.json_response(
                        409,
                        {
                            "error":
                                "no pending approval",
                        },
                    )
                    return

                if (
                    pending["id"]
                    != approval_id
                ):
                    self.json_response(
                        409,
                        {
                            "error":
                                "approval id mismatch",
                        },
                    )
                    return

                if (
                    self.path
                    == "/agent/approve"
                ):
                    APPROVAL_DECISION = (
                        "approve"
                    )
                else:
                    APPROVAL_DECISION = (
                        "reject"
                    )

                APPROVAL_EVENT.set()

            self.json_response(
                200,
                {
                    "ok": True,
                    "decision":
                        APPROVAL_DECISION,
                },
            )
            return

        if self.path == "/agent/stop":
            STOP_EVENT.set()
            APPROVAL_EVENT.set()

            event(
                "STATE",
                "stopped",
                "Stop requested",
            )

            self.json_response(
                200,
                {
                    "ok": True,
                    "stop_requested": True,
                },
            )
            return

        self.json_response(
            404,
            {
                "error": "not found",
            },
        )


def handle_signal(
    signum,
    frame,
):
    STOP_EVENT.set()
    APPROVAL_EVENT.set()

    raise KeyboardInterrupt


def main():
    load_state()

    signal.signal(
        signal.SIGTERM,
        handle_signal,
    )

    signal.signal(
        signal.SIGINT,
        handle_signal,
    )

    event(
        "STATE",
        "success",
        "DZL Agent backend started",
        f"{HOST}:{PORT}",
        f"model={MODEL}",
    )

    server = ThreadingHTTPServer(
        (
            HOST,
            PORT,
        ),
        Handler,
    )

    print(
        f"DZL Agent listening on "
        f"http://{HOST}:{PORT}",
        flush=True,
    )

    try:
        server.serve_forever()

    except KeyboardInterrupt:
        pass

    finally:
        server.server_close()


if __name__ == "__main__":
    main()
