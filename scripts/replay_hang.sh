#!/usr/bin/env bash
# replay_hang.sh — replay a captured hang against a live endpoint.
#
# Two capture formats are dispatched automatically on the meta's keys:
#
#   1. StallSentinel dump (gh-1395 AC3): a meta.json with `idleSeconds`
#      and payload.bin alongside — byte-identical curl replay bounded by
#      the dump's idle budget. Auth headers were redacted at capture
#      time; re-inject live values via env:
#        REPLAY_AUTHORIZATION='Bearer ...' scripts/replay_hang.sh meta.json
#      Exit codes: 0 answered within budget ("replayed: <status>");
#      2 stall REPRODUCED ("stalled: <detail>"); 1 usage/curl failure.
#
#   2. Bench hang-*.json (issue #1392): a JSON whose `payload` carries
#      url/method/body/headers — python-stdlib replay that prints the
#      first-byte time, so a Class-C repro runs from any machine:
#        scripts/replay_hang.sh hang-t1__trial-213s.json [url]
#      (payload.url unless argv 2 / FA_REPLAY_URL; FA_REPLAY_TIMEOUT_SEC
#      bounds the wait, default 400s; exit 0 only on a first byte.)
set -uo pipefail

if [ $# -lt 1 ]; then
  echo "replay-error: usage: $0 <meta.json|hang-*.json> [url]" >&2
  exit 1
fi
FILE="$1"

# Dispatch on format: the StallSentinel meta is flat with `idleSeconds`;
# the bench hang file nests the request under `payload`.
IS_SENTINEL_META="$(python3 - "$FILE" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        m = json.load(fh)
except Exception:
    print("no")
else:
    print("yes" if isinstance(m, dict) and "idleSeconds" in m else "no")
PY
)"

if [ "$IS_SENTINEL_META" = "yes" ]; then
  META="$FILE"
  DIR="$(cd "$(dirname "$META")" && pwd)"
  PAYLOAD="$DIR/payload.bin"

  if [ ! -f "$META" ]; then
    echo "replay-error: meta not found: $META" >&2
    exit 1
  fi

  # meta.json is a flat object we wrote ourselves; python3 parses it
  # dependency-free (this box's jq is jaq with silent-stdin quirks).
  read -r URL METHOD IDLE CT < <(python3 - "$META" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    m = json.load(f)
print(m.get("url", ""), m.get("method", "POST"), m.get("idleSeconds", 300),
      m.get("headers", {}).get("content-type", ""))
PY
)

  if [ -z "$URL" ] || [ "$URL" = "unavailable" ]; then
    echo "replay-error: no url in meta" >&2
    exit 1
  fi

  ARGS=(--max-time "${IDLE:-300}" -s -o /dev/null -w '%{http_code}' -X "$METHOD")
  if [ -n "$CT" ]; then
    ARGS+=(-H "content-type: $CT")
  fi
  if [ -n "${REPLAY_AUTHORIZATION:-}" ]; then
    ARGS+=(-H "authorization: $REPLAY_AUTHORIZATION")
  fi
  if [ -f "$PAYLOAD" ]; then
    ARGS+=(--data-binary "@$PAYLOAD")
  fi

  STATUS="$(curl "${ARGS[@]}" "$URL")"
  CURL_RC=$?

  if [ "$CURL_RC" -eq 28 ]; then
    echo "stalled: no response within ${IDLE}s (same stall signature)"
    exit 2
  elif [ "$CURL_RC" -ne 0 ]; then
    echo "replay-error: curl exit $CURL_RC"
    exit 1
  fi

  echo "replayed: HTTP $STATUS within ${IDLE}s"
  exit 0
fi

# Bench hang-*.json replay (issue #1392).
python3 - "$FILE" "${2:-${FA_REPLAY_URL:-}}" <<'PY'
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
