#!/usr/bin/env python3
"""AC3 round-trip: scripts/replay_hang.sh replays a captured hang-*.json
against a local mock and prints the first-byte time.

Run: python3 -m unittest discover -s bench/terminal_bench
"""
import json
import re
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

_SCRIPT = Path(__file__).resolve().parent.parent.parent / "scripts" / "replay_hang.sh"


class _Mock(BaseHTTPRequestHandler):
    delay = 0.0

    def do_POST(self):
        import time

        time.sleep(self.delay)
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def log_message(self, *args):
        pass


@unittest.skipUnless(
    _SCRIPT.exists(), "scripts/replay_hang.sh not found (standalone checkout)"
)
class ReplayHangTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.mock = ThreadingHTTPServer(("127.0.0.1", 0), _Mock)
        self.port = self.mock.server_address[1]
        threading.Thread(target=self.mock.serve_forever, daemon=True).start()
        self.addCleanup(self.mock.shutdown)

    def _hang_file(self):
        path = Path(self.tmp.name) / "hang-t1.json"
        path.write_text(
            json.dumps(
                {
                    "trial": "t1__trial",
                    "gap_sec": 301.0,
                    "payload": {
                        "method": "POST",
                        "url": f"http://127.0.0.1:{self.port}/v1/chat",
                        "headers": {"content-type": "application/json"},
                        "body": json.dumps({"model": "glm", "stream": True}),
                    },
                    "replay": "scripts/replay_hang.sh <this-file>",
                }
            )
        )
        return path

    def test_replays_and_prints_first_byte_time(self):
        proc = subprocess.run(
            ["bash", str(_SCRIPT), str(self._hang_file())],
            capture_output=True,
            text=True,
            timeout=30,
            env={"PATH": "/usr/bin:/bin:/usr/local/bin", "HOME": self.tmp.name},
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("first byte after", proc.stdout)
        self.assertRegex(proc.stdout, r"first byte after [\d.]+s")
        self.assertIn("status 200", proc.stdout)

    def test_missing_url_argument_fails_loudly(self):
        hang = json.loads(self._hang_file().read_text())
        hang["payload"]["url"] = ""
        path = Path(self.tmp.name) / "hang-nourl.json"
        path.write_text(json.dumps(hang))
        proc = subprocess.run(
            ["bash", str(_SCRIPT), str(path)],
            capture_output=True,
            text=True,
            timeout=30,
            env={"PATH": "/usr/bin:/bin:/usr/local/bin", "HOME": self.tmp.name},
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("no replay url", proc.stderr)


if __name__ == "__main__":
    unittest.main()
