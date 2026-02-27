"""Echo backend for nginx integration tests.

Returns request details as JSON for verifying reverse proxy behavior.
"""

import json
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler


class EchoHandler(BaseHTTPRequestHandler):
    def _respond(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else b""

        response = {
            "method": self.command,
            "path": self.path,
            "headers": dict(self.headers),
            "body_length": len(body),
        }

        payload = json.dumps(response, indent=2).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self._respond()

    def do_POST(self):
        self._respond()

    def do_PUT(self):
        self._respond()

    def do_DELETE(self):
        self._respond()

    def do_PATCH(self):
        self._respond()

    def do_HEAD(self):
        """Handle HEAD requests (same as GET but no body)."""
        response = {
            "method": self.command,
            "path": self.path,
            "headers": dict(self.headers),
            "body_length": 0,
        }
        payload = json.dumps(response, indent=2).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()

    def do_OPTIONS(self):
        self._respond()

    def log_message(self, format, *args):
        sys.stderr.write(f"[backend] {args[0]}\n")


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
    server = HTTPServer(("0.0.0.0", port), EchoHandler)
    print(f"Echo backend listening on :{port}", flush=True)
    server.serve_forever()
