#!/usr/bin/env bash
# replay_hang.sh — replay a captured hang-*.json (issue #1392 StallSentinel)
# against a live endpoint and print the first-byte time, so a Class-C
# "the request never returned" repro runs from any Mac without a bench:
#
#     scripts/replay_hang.sh hang-t1__trial-213s.json
#     scripts/replay_hang.sh hang-t1__trial-213s.json https://api.z.ai/...
#
# The hang file's own payload.url is used unless a URL is passed as argv 2
# (or FA_REPLAY_URL is set) — e.g. to retarget a captured payload at a
# local mock. Per-request knobs (FA_REPLAY_TIMEOUT_SEC, default 400s)
# bound the wait; the exit code is 0 only when a first byte arrived.
set -euo pipefail

file="${1:?usage: replay_hang.sh <hang-*.json> [url]}"
url="${2:-${FA_REPLAY_URL:-}}"

if [ ! -f "$file" ]; then
  echo "replay_hang: no such file: $file" >&2
  exit 2
fi

python3 - "$file" "$url" <<'PY'
import json
import sys
import time
import urllib.error
import urllib.request

hang_path, url = sys.argv[1], sys.argv[2]
with open(hang_path, "rb") as fh:
    hang = json.loads(fh.read().decode("utf-8", errors="replace"))
payload = hang.get("payload") or {}
url = url or payload.get("url") or ""
if not url:
    print("replay_hang: no replay url (argv 2, FA_REPLAY_URL, or payload.url)",
          file=sys.stderr)
    sys.exit(2)

body = payload.get("body")
data = body.encode() if isinstance(body, str) else (body or None)
method = (payload.get("method") or "POST").upper()
timeout = float(__import__("os").environ.get("FA_REPLAY_TIMEOUT_SEC", "400"))
req = urllib.request.Request(url, data=data, method=method)
for key, value in (payload.get("headers") or {}).items():
    req.add_header(key, value)

trial = hang.get("trial", "?")
gap = hang.get("gap_sec")
print(f"replaying {method} {url} (captured trial {trial},"
      f" gap {gap}s) ...")
start = time.monotonic()
try:
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        first = time.monotonic() - start
        print(f"first byte after {first:.2f}s — status {resp.status}")
        resp.read()
        print(f"body complete after {time.monotonic() - start:.2f}s")
except urllib.error.HTTPError as exc:
    first = time.monotonic() - start
    print(f"first byte after {first:.2f}s — status {exc.code} (HTTP error)")
except Exception as exc:  # noqa: BLE001 — the repro IS the diagnostic
    waited = time.monotonic() - start
    print(f"no first byte after {waited:.2f}s — {type(exc).__name__}: {exc}")
    sys.exit(1)
PY
