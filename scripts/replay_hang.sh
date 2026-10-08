#!/usr/bin/env bash
# replay_hang.sh — byte-identical replay of a StallSentinel dump (gh-1395 AC3).
#
# Usage: scripts/replay_hang.sh <path/to/meta.json>
#
# Re-sends the dumped outbound payload (payload.bin next to meta.json)
# against the endpoint recorded in the meta, with the same method/headers
# and a curl --max-time bound of the dump's idle budget. Auth headers were
# redacted at capture time; re-inject live values via env when needed:
#   REPLAY_AUTHORIZATION='Bearer ...' scripts/replay_hang.sh meta.json
#
# Exit codes:
#   0 — the endpoint ANSWERED within the budget (stall exonerated upstream;
#       "replayed: <status>" on stdout);
#   2 — the stall signature REPRODUCED: no response within the idle budget
#       ("stalled: <detail>" on stdout);
#   1 — usage/read/other curl failure ("replay-error: <detail>").
set -uo pipefail

if [ $# -ne 1 ]; then
  echo "replay-error: usage: $0 <meta.json>" >&2
  exit 1
fi

META="$1"
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
