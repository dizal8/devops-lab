#!/usr/bin/env python3

import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import threading
import time

from http.server import (
    BaseHTTPRequestHandler,
    ThreadingHTTPServer,
)


HOST = "127.0.0.1"
PORT = 7682

TMUX_TARGET = "dzl:0.0"

ALLOWED_ORIGINS = {
    "https://app.lab01.dzl.ro",
    "https://dzl.ro",
    "https://dzl.tail52c2d4.ts.net:8443",
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

paste_lock = threading.Lock()
last_paste_hash = ""
last_paste_time = 0.0

net_lock = threading.Lock()
last_net = None


def run(*args, input_text=None):

    return subprocess.run(
        args,
        input=input_text,
        text=True,
        capture_output=True,
        timeout=8,
    )


# ------------------------------------------------------------
# TERMINAL CAPTURE
# ------------------------------------------------------------

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
            if char == "\t"
            or ord(char) >= 32
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

    return clean(result.stdout)


def last_execution():

    lines = capture().splitlines()

    prompts = [
        index
        for index, line
        in enumerate(lines)
        if "❯" in line
    ]

    if len(prompts) >= 2:

        block = lines[
            prompts[-2]:
            prompts[-1]
        ]

    elif len(prompts) == 1:

        block = lines[
            prompts[-1]:
        ]

    else:

        block = lines[-100:]

    value = "\n".join(block).strip()

    return (
        value
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


# ------------------------------------------------------------
# CLEAR
# ------------------------------------------------------------

def clear_terminal():

    # Abort anything currently typed/running.
    result = run(
        "tmux",
        "send-keys",
        "-t",
        TMUX_TARGET,
        "C-c",
    )

    if result.returncode != 0:
        raise RuntimeError(
            result.stderr.strip()
            or "Ctrl-C failed"
        )

    time.sleep(0.08)

    # Run real shell clear.
    result = run(
        "tmux",
        "send-keys",
        "-t",
        TMUX_TARGET,
        "clear",
        "Enter",
    )

    if result.returncode != 0:
        raise RuntimeError(
            result.stderr.strip()
            or "clear command failed"
        )

    time.sleep(0.12)

    # Remove tmux scrollback as well.
    run(
        "tmux",
        "clear-history",
        "-t",
        TMUX_TARGET,
    )



def enter_terminal():

    result = run(
        "tmux",
        "send-keys",
        "-t",
        TMUX_TARGET,
        "Enter",
    )

    if result.returncode != 0:

        raise RuntimeError(
            result.stderr.strip()
            or "Enter failed"
        )

    return "executed"


def paste_terminal(value):

    global last_paste_hash
    global last_paste_time

    if not isinstance(value, str):
        raise RuntimeError(
            "Paste value must be text"
        )

    if len(value) > 200000:
        raise RuntimeError(
            "Paste payload too large"
        )

    value = (
        value
        .replace("\r\n", "\n")
        .replace("\r", "\n")
        .rstrip("\n")
    )

    if not value:
        return "empty"

    digest = hashlib.sha256(
        value.encode("utf-8")
    ).hexdigest()

    now = time.monotonic()

    with paste_lock:

        # Strong protection against double click /
        # duplicated browser event.
        if (
            digest == last_paste_hash
            and now - last_paste_time < 5.0
        ):
            return "duplicate-blocked"

        # Also inspect the actual active command line.
        # If the same payload is already visible at the
        # end of the tmux pane, never append it again.
        current = run(
            "tmux",
            "capture-pane",
            "-p",
            "-J",
            "-S",
            "-3",
            "-t",
            TMUX_TARGET,
        )

        if current.returncode == 0:

            visible = clean(
                current.stdout
            )

            last_lines = (
                visible
                .splitlines()
            )

            current_line = (
                last_lines[-1]
                if last_lines
                else ""
            )

            normalized_value = " ".join(
                value.split()
            )

            normalized_line = " ".join(
                current_line.split()
            )

            if (
                normalized_value
                and normalized_value
                in normalized_line
            ):
                return "already-present"

        last_paste_hash = digest
        last_paste_time = now

    load = run(
        "tmux",
        "load-buffer",
        "-",
        input_text=value,
    )

    if load.returncode != 0:
        raise RuntimeError(
            load.stderr.strip()
            or "load-buffer failed"
        )

    paste = run(
        "tmux",
        "paste-buffer",
        "-d",
        "-t",
        TMUX_TARGET,
    )

    if paste.returncode != 0:
        raise RuntimeError(
            paste.stderr.strip()
            or "paste-buffer failed"
        )

    return "pasted"




# ------------------------------------------------------------
# HARDWARE METRICS
# ------------------------------------------------------------

def cpu_snapshot():

    with open(
        "/proc/stat",
        "r",
        encoding="utf-8",
    ) as handle:

        values = handle.readline().split()

    nums = [
        int(x)
        for x in values[1:]
    ]

    idle = nums[3] + nums[4]
    total = sum(nums)

    return idle, total


def cpu_usage():

    idle1, total1 = cpu_snapshot()

    time.sleep(0.10)

    idle2, total2 = cpu_snapshot()

    total_delta = total2 - total1
    idle_delta = idle2 - idle1

    if total_delta <= 0:
        return 0.0

    return round(
        100.0
        * (
            1.0
            - idle_delta / total_delta
        ),
        1,
    )


def cpu_model():

    try:

        with open(
            "/proc/cpuinfo",
            "r",
            encoding="utf-8",
        ) as handle:

            for line in handle:

                if line.lower().startswith(
                    "model name"
                ):

                    return (
                        line.split(
                            ":",
                            1,
                        )[1]
                        .strip()
                    )

    except Exception:
        pass

    return "CPU"


def cpu_temperature():

    temps = []

    patterns = [
        "/sys/class/thermal/thermal_zone*/temp",
        "/sys/class/hwmon/hwmon*/temp*_input",
    ]

    for pattern in patterns:

        for filename in glob.glob(pattern):

            try:

                value = float(
                    open(
                        filename,
                        encoding="utf-8",
                    ).read().strip()
                )

                if value > 1000:
                    value /= 1000.0

                if 5 <= value <= 115:
                    temps.append(value)

            except Exception:
                pass

    if not temps:
        return None

    return round(
        max(temps),
        1,
    )


def memory_metrics():

    values = {}

    with open(
        "/proc/meminfo",
        "r",
        encoding="utf-8",
    ) as handle:

        for line in handle:

            key, value = line.split(
                ":",
                1,
            )

            values[key] = int(
                value.strip().split()[0]
            )

    total = values.get(
        "MemTotal",
        0,
    )

    available = values.get(
        "MemAvailable",
        0,
    )

    used = total - available

    percent = (
        used / total * 100
        if total
        else 0
    )

    return {
        "used_gb": round(
            used / 1024 / 1024,
            1,
        ),
        "total_gb": round(
            total / 1024 / 1024,
            1,
        ),
        "percent": round(
            percent,
            1,
        ),
    }


def gpu_metrics():

    if not shutil.which(
        "nvidia-smi"
    ):

        return {
            "available": False,
            "name": "N/A",
        }

    result = run(
        "nvidia-smi",
        "--query-gpu="
        "name,"
        "utilization.gpu,"
        "memory.used,"
        "memory.total,"
        "temperature.gpu",
        "--format=csv,noheader,nounits",
    )

    if result.returncode != 0:
        return {
            "available": False,
            "name": "N/A",
        }

    line = (
        result.stdout
        .splitlines()[0]
    )

    parts = [
        x.strip()
        for x in line.split(",")
    ]

    if len(parts) < 5:
        return {
            "available": False,
            "name": "N/A",
        }

    return {
        "available": True,
        "name": parts[0],
        "util": float(parts[1]),
        "memory_used_mb":
            float(parts[2]),
        "memory_total_mb":
            float(parts[3]),
        "temperature":
            float(parts[4]),
    }


def default_iface():

    result = run(
        "ip",
        "route",
        "show",
        "default",
    )

    if result.returncode != 0:
        return None

    parts = result.stdout.split()

    if "dev" not in parts:
        return None

    index = parts.index("dev")

    if index + 1 >= len(parts):
        return None

    return parts[index + 1]


def iface_bytes(interface):

    if not interface:
        return 0, 0

    with open(
        "/proc/net/dev",
        "r",
        encoding="utf-8",
    ) as handle:

        for line in handle:

            if ":" not in line:
                continue

            name, values = line.split(
                ":",
                1,
            )

            if name.strip() != interface:
                continue

            parts = values.split()

            rx = int(parts[0])
            tx = int(parts[8])

            return rx, tx

    return 0, 0


def network_metrics():

    global last_net

    interface = default_iface()

    rx, tx = iface_bytes(
        interface
    )

    now = time.monotonic()

    with net_lock:

        if (
            last_net is None
            or last_net["interface"]
            != interface
        ):

            last_net = {
                "interface": interface,
                "rx": rx,
                "tx": tx,
                "time": now,
            }

            return {
                "interface":
                    interface or "N/A",
                "rx_mbps": 0,
                "tx_mbps": 0,
            }

        elapsed = (
            now
            - last_net["time"]
        )

        if elapsed <= 0:
            elapsed = 1

        rx_rate = (
            (rx - last_net["rx"])
            * 8
            / elapsed
            / 1_000_000
        )

        tx_rate = (
            (tx - last_net["tx"])
            * 8
            / elapsed
            / 1_000_000
        )

        last_net = {
            "interface": interface,
            "rx": rx,
            "tx": tx,
            "time": now,
        }

    return {
        "interface":
            interface or "N/A",
        "rx_mbps":
            round(max(rx_rate, 0), 2),
        "tx_mbps":
            round(max(tx_rate, 0), 2),
    }


def storage_metrics():

    disk = shutil.disk_usage("/")

    total = disk.total
    used = disk.used

    percent = (
        used / total * 100
        if total
        else 0
    )

    return {
        "used_gb":
            round(
                used
                / 1024**3,
                1,
            ),
        "total_gb":
            round(
                total
                / 1024**3,
                1,
            ),
        "free_gb":
            round(
                disk.free
                / 1024**3,
                1,
            ),
        "percent":
            round(
                percent,
                1,
            ),
    }


def ssd_metrics():

    result = run(
        "lsblk",
        "-dn",
        "-o",
        "NAME,TYPE,ROTA,SIZE,MODEL",
    )

    ssds = []

    if result.returncode == 0:

        for line in result.stdout.splitlines():

            parts = line.split(
                None,
                4,
            )

            if len(parts) < 4:
                continue

            name = parts[0]
            dtype = parts[1]
            rota = parts[2]
            size = parts[3]

            model = (
                parts[4]
                if len(parts) >= 5
                else ""
            )

            if (
                dtype == "disk"
                and rota == "0"
            ):

                ssds.append({
                    "name": name,
                    "size": size,
                    "model":
                        model.strip(),
                })

    if not ssds:

        return {
            "count": 0,
            "label": "N/A",
        }

    first = ssds[0]

    label = (
        first["model"]
        or first["name"]
    )

    return {
        "count": len(ssds),
        "label": label,
        "size": first["size"],
        "devices": ssds,
    }


def uptime():

    try:

        value = float(
            open(
                "/proc/uptime",
                encoding="utf-8",
            ).read().split()[0]
        )

        return int(value)

    except Exception:
        return 0


def metrics():

    return {
        "cpu": {
            "usage": cpu_usage(),
            "model": cpu_model(),
            "temperature":
                cpu_temperature(),
        },
        "memory":
            memory_metrics(),
        "gpu":
            gpu_metrics(),
        "network":
            network_metrics(),
        "ssd":
            ssd_metrics(),
        "storage":
            storage_metrics(),
        "uptime_seconds":
            uptime(),
        "timestamp":
            int(time.time()),
    }


# ------------------------------------------------------------
# HTTP
# ------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):

    server_version = "DZLSessionAPI/3.0"

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
        content_type=
            "text/plain; charset=utf-8",
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

    def json_answer(
        self,
        status,
        value,
    ):

        self.answer(
            status,
            json.dumps(value),
            "application/json; charset=utf-8",
        )

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

                self.json_answer(
                    200,
                    {
                        "status": "ok",
                        "version": 3,
                        "tmux_target":
                            TMUX_TARGET,
                    },
                )

                return

            if self.path == "/metrics":

                self.json_answer(
                    200,
                    metrics(),
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

            if self.path == "/enter":

                result = enter_terminal()

                self.answer(
                    200,
                    result,
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

                result = paste_terminal(
                    data.get(
                        "text",
                        "",
                    )
                )

                self.answer(
                    200,
                    result,
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
    "DZL Session API v3 "
    f"http://{HOST}:{PORT}",
    flush=True,
)

server.serve_forever()
