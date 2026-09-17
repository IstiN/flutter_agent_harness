#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  CROSS-MODULE DUPLICATION GATE (issue #487) — ONLY TIGHTEN THE THRESHOLD  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# The per-package jscpd gates (dup stage: core lib/ < 1%, flutter_app/lib/
# < 3.7%) only see duplication INSIDE one module. Copy-paste ACROSS module
# boundaries (lib, bin ↔ flutter_app/lib ↔ packages/*/lib ↔ browser_ext/dart)
# was invisible — issue #487 measured 20 files shipped as cross-module
# clones (OAuth callback, ASR tool, chrome/persistent web env, fahx import…).
#
# ONE jscpd invocation over all module roots; a clone counts toward the gate
# only when its two sides live in DIFFERENT module roots. Pinned threshold
# DUP_THRESHOLD_XMOD lives in scripts/ci_fast_gate.sh (single pinned copy,
# same ratchet policy as DUP_THRESHOLD/DUP_THRESHOLD_APP): measured 0.3013%
# of the combined ~283k-line surface at the #487 baseline, pinned 0.31 —
# lower after dedup work, never raise.
#
# Usage: scripts/check_dup_cross_module.sh [threshold-percent]
# Exit:  0 pass · 1 fail (or report unreadable — fail closed; a gate that
#        silently greens on tool failure rots) · 2 jscpd unavailable
#        (caller prints the SKIP marker).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

THRESHOLD="${1:-0.31}"

MODULES=(
  lib
  bin
  flutter_app/lib
  packages/fa_ui/lib
  packages/dap_hub/lib
  packages/fa_llm/lib
  packages/fa_llm_mock/lib
  packages/fa_llm_flutter/lib
  browser_ext/dart
)

# Prefer the global binary (pre-commit machines), fall back to npx like CI.
if command -v jscpd >/dev/null 2>&1; then
  JSCPD=(jscpd)
elif command -v npx >/dev/null 2>&1; then
  JSCPD=(npx --yes jscpd@5)
else
  exit 2
fi

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

# -a: absolute paths in the report — module attribution needs the root.
"${JSCPD[@]}" -a --min-tokens 50 --min-lines 5 --reporters json \
  --output "$OUT" "${MODULES[@]}" >/dev/null 2>&1 || true

python3 - "$OUT/jscpd-report.json" "$THRESHOLD" "$(pwd)" <<'EOF'
import json, os, sys

report_path, threshold, root = sys.argv[1], float(sys.argv[2]), sys.argv[3]
MODS = [
    "lib/", "bin/", "flutter_app/lib/", "packages/fa_ui/lib/",
    "packages/dap_hub/lib/", "packages/fa_llm/lib/",
    "packages/fa_llm_mock/lib/", "packages/fa_llm_flutter/lib/",
    "browser_ext/dart/",
]


def mod_of(path):
    rel = path[len(root) + 1:] if path.startswith(root + "/") else path
    hits = [m for m in MODS if rel.startswith(m)]
    return max(hits, key=len) if hits else None


try:
    with open(report_path) as f:
        report = json.load(f)
    total = report["statistics"]["total"]["lines"]
    clones = report.get("duplicates", [])
except Exception as exc:
    print(f"❌ cross-module duplication: jscpd report unreadable ({exc}) — FAILING CLOSED")
    sys.exit(1)

cross = []
for c in clones:
    m1, m2 = mod_of(c["firstFile"]["name"]), mod_of(c["secondFile"]["name"])
    if m1 and m2 and m1 != m2:
        cross.append(c)

pct = 100.0 * sum(c["lines"] for c in cross) / total if total else 0.0
print(f"Cross-module duplication: {pct:.4f}% "
      f"({len(cross)}/{len(clones)} clones over {total} lines) — threshold < {threshold}%")
for c in sorted(cross, key=lambda c: -c["lines"])[:5]:
    a, b = c["firstFile"]["name"], c["secondFile"]["name"]
    print(f"  {c['lines']:4d} ln  {a[len(root) + 1:] if a.startswith(root) else a}\n"
          f"        <-> {b[len(root) + 1:] if b.startswith(root) else b}")
sys.exit(0 if pct < threshold else 1)
EOF
