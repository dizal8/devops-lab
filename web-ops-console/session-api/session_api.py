#!/usr/bin/env python3

import json
import re
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


HOST = "127.0.0.1"
PORT = 7682
TMUX_TARGET = "dzl:0.0"

ALLOWED_ORIGINS = {
    "https://app.lab01.dzl.ro",
    "https://dzl.ro",
}

ANSI_RE = re.compile(
    r"\x1B(?:"
    r"\[[0-?]*[ -/]*[@-~]"
    r"|\][^\x07]*(?:\x07|\x1B\\)"
    r"|[PX^_].*?\x1B\\"
    r"|[@-_]"
    r")",
    re.DOTALL,
)


def run(*args, input_text=None):
    return subprocess.run(
        args,
        input=input_text,
        text=True,
        capture_output=True,
        timeout=8,
    )


def clean(value):
    value = ANSI_RE.sub("", value)
    value = value.replace("\r", "")

    output = []

    for line in value.splitlines():

        if re.search(
            r"\[sudo\]\s+password\s+for",
            line,
            re.IGNORECASE,
        ):
            output.append(
                "[sudo password prompt omitted]"
            )
            continue

        line = "".join(
            char
            for char in line
            if char == "\t" or ord(char) >= 32
        )

        output.append(
            line.rstrip()
        )

    while output and not output[0].strip():
        output.pop(0)

    while output and not output[-1].strip():
        output.pop()

    return "\n".join(output)


def capture():

    result = run(
        "tmux",
        "capture-pane",
        "-p",
        "-J",
        "-S",
        "-600",
        "-t",
        TMUX_TARGET,
    )

    if result.returncode != 0:
        raise RuntimeError(
            result.stderr.strip()
            or "tmux session unavailable"
        )

    return clean(
        result.stdout
    )


def last_execution():

    lines = capture().splitlines()

    prompts = [
        index
        for index, line in enumerate(lines)
        if "❯" in line
    ]

    if len(prompts) >= 2:

        block = lines[
            prompts[-2]:prompts[-1]
        ]

    elif len(prompts) == 1:

        block = lines[
            prompts[-1]:
        ]

    else:

        block = lines[-100:]

    result = "\n".join(block).strip()

    return (
        result
        or "No completed execution captured yet."
    )


def markdown():

    value = last_execution().replace(
        "```",
        "'''",
    )

    return (
        "```console\n"
        + value
        + "\n```"
    )


def clear_terminal():

    result = run(
        "tmux",
        "send-keys",
        "-t",
        TMUX_TARGET,
        "C-l",
    )

    if result.returncode != 0:
        raise RuntimeError(
            result.stderr.strip()
            or "clear failed"
        )


def paste_terminal(value):

    if not isinstance(value, str):
        raise RuntimeError(
            "Paste value must be text"
        )

    if len(value) > 200000:
        raise RuntimeError(
            "Paste payload too large"
        )

    result = run(
        "tmux",
        "load-buffer",
        "-",
        input_text=value,
    )

    if result.returncode != 0:
        raise RuntimeError(
            result.stderr.strip()
            or "load-buffer failed"
        )

    result = run(
        "tmux",
        "paste-buffer",
        "-d",
        "-t",
        TMUX_TARGET,
    )

    if result.returncode != 0:
        raise RuntimeError(
            result.stderr.strip()
            or "paste-buffer failed"
        )


class Handler(BaseHTTPRequestHandler):

    server_version = "DZLSessionAPI/2.0"

    def log_message(self, *_):
        return

    def allowed(self):

        origin = self.headers.get(
            "Origin",
            "",
        )

        return (
            not origin
            or origin in ALLOWED_ORIGINS
        )

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

    def answer(
        self,
        status,
        body,
        content_type="text/plain; charset=utf-8",
    ):

        payload = body.encode(
            "utf-8"
        )

        self.send_response(status)
        self.cors()

        self.send_header(
            "Content-Type",
            content_type,
        )

        self.send_header(
            "Cache-Control",
            "no-store",
        )

        self.send_header(
            "Content-Length",
            str(len(payload)),
        )

        self.end_headers()

        self.wfile.write(payload)

    def do_OPTIONS(self):

        if not self.allowed():
            self.answer(
                403,
                "Origin denied",
            )
            return

        self.send_response(204)
        self.cors()
        self.end_headers()

    def do_GET(self):

        if not self.allowed():
            self.answer(
                403,
                "Origin denied",
            )
            return

        try:

            if self.path == "/health":

                self.answer(
                    200,
                    json.dumps(
                        {
                            "status": "ok",
                            "tmux_target":
                                TMUX_TARGET,
                            "version": 2,
                        }
                    ),
                    "application/json; charset=utf-8",
                )
                return

            if self.path == "/last":

                self.answer(
                    200,
                    last_execution(),
                )
                return

            if self.path == "/last-md":

                self.answer(
                    200,
                    markdown(),
                    "text/markdown; charset=utf-8",
                )
                return

            self.answer(
                404,
                "Not found",
            )

        except Exception as exc:

            self.answer(
                503,
                f"Unavailable: {exc}",
            )

    def do_POST(self):

        if not self.allowed():
            self.answer(
                403,
                "Origin denied",
            )
            return

        try:

            if self.path == "/clear":

                clear_terminal()

                self.answer(
                    200,
                    "cleared",
                )
                return

            if self.path == "/paste":

                length = int(
                    self.headers.get(
                        "Content-Length",
                        "0",
                    )
                )

                raw = self.rfile.read(
                    length
                )

                data = json.loads(
                    raw.decode("utf-8")
                    or "{}"
                )

                paste_terminal(
                    data.get(
                        "text",
                        "",
                    )
                )

                self.answer(
                    200,
                    "pasted",
                )
                return

            self.answer(
                404,
                "Not found",
            )

        except Exception as exc:

            self.answer(
                503,
                f"Unavailable: {exc}",
            )


server = ThreadingHTTPServer(
    (HOST, PORT),
    Handler,
)

print(
    f"DZL Session API v2 on "
    f"http://{HOST}:{PORT}",
    flush=True,
)

server.serve_forever()
