import json
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ORIGIN = "https://app.lab01.dzl.ro"
OLLAMA = "http://127.0.0.1:11434"
MODEL = "qwen3:8b"

class H(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def cors(self):
        self.send_header("Access-Control-Allow-Origin", ORIGIN)
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")

    def out(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.cors()
        self.end_headers()
        self.wfile.write(body)

    def ollama(self, path, payload=None, timeout=180):
        data = json.dumps(payload).encode() if payload else None
        req = urllib.request.Request(
            OLLAMA + path,
            data=data,
            headers={"Content-Type": "application/json"}
        )
        return json.loads(
            urllib.request.urlopen(req, timeout=timeout).read()
        )

    def do_OPTIONS(self):
        self.send_response(204)
        self.cors()
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            try:
                tags = self.ollama("/api/tags")
                names = [m["name"] for m in tags.get("models", [])]
                return self.out(200, {
                    "status": "ok",
                    "provider": "ollama",
                    "model": MODEL,
                    "available": MODEL in names,
                    "cost": "local"
                })
            except Exception as e:
                return self.out(503, {
                    "status": "offline",
                    "error": str(e)
                })

        if self.path == "/runtime":
            try:
                return self.out(200, self.ollama("/api/ps"))
            except Exception as e:
                return self.out(503, {"error": str(e)})

        self.send_error(404)

    def do_POST(self):
        if self.path != "/chat":
            return self.send_error(404)

        try:
            n = int(self.headers.get("Content-Length", "0"))
            message = json.loads(self.rfile.read(n)).get("message", "").strip()

            if not message:
                return self.out(400, {"error": "empty message"})

            result = self.ollama("/api/chat", {
                "model": MODEL,
                "messages": [{"role": "user", "content": message}],
                "stream": False,
                "keep_alive": "30m",
                "options": {"num_ctx": 4096}
            })

            return self.out(200, {
                "answer": result.get("message", {}).get("content", ""),
                "model": MODEL,
                "provider": "ollama"
            })

        except Exception as e:
            self.out(502, {"error": str(e)})

ThreadingHTTPServer(("127.0.0.1", 7683), H).serve_forever()
