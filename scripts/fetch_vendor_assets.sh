#!/usr/bin/env bash
# gh-1630 I2 — fetch + verify the vendored engine assets from the lock.
#
# Every remotely-loaded engine the extension package carries is pinned in
# browser_ext/vendor.lock.json (URL + post-transform SHA-256). This script
# is the ONLY sanctioned way vendor assets enter the package:
#
#   fetch_vendor_assets.sh [--lock P] [--dest D] [--verify-only]
#
#   default        download missing assets from the lock, apply the
#                  declared per-file `replacements` (each must occur
#                  EXACTLY once — that is how remote constants are
#                  stripped out of vendored bundles), verify the SHA-256
#                  of the final bytes, fail loud on any mismatch;
#   --verify-only  no network: verify the checksums of already-fetched
#                  assets (CI cache mode, the E1 selftest);
#   --dest D       target dir (default browser_ext/vendor — gitignored;
#                  the PACKAGE carries the bytes, the repo the lock);
#   --lock P       lock path (default browser_ext/vendor.lock.json).
#
# Replaces scripts/vendor_interpreters.sh (same interpreters/ layout, now
# checksum-pinned and covering ALL engines, not just the offscreen pair).
# Exit codes: 0 verified/fetched; 1 lock/dest missing, checksum mismatch,
# replacement count drift, network failure — NEVER a silent ship without
# verified assets (gh-1630 E1).
set -euo pipefail
cd "$(dirname "$0")/.."

lock=browser_ext/vendor.lock.json
dest=browser_ext/vendor
verify_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --lock) lock="$2"; shift 2 ;;
    --dest) dest="$2"; shift 2 ;;
    --verify-only) verify_only=1; shift ;;
    *) echo "fetch_vendor_assets: unknown option: $1" >&2; exit 1 ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "FATAL: fetch_vendor_assets requires python3 (lock parsing + sha256)" >&2
  exit 1
fi
if [ ! -f "$lock" ]; then
  echo "FATAL: vendor lock not found: $lock" >&2
  exit 1
fi

python3 - "$lock" "$dest" "$verify_only" <<'PY'
import hashlib
import json
import os
import subprocess
import sys

lock_path, dest, verify_only = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
try:
    lock = json.load(open(lock_path, encoding="utf-8"))
except (OSError, ValueError) as e:
    print(f"FATAL: cannot parse vendor lock {lock_path}: {e}", file=sys.stderr)
    sys.exit(1)

def fail(msg):
    print(f"FATAL: fetch_vendor_assets: {msg}", file=sys.stderr)
    sys.exit(1)

def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

fetched = verified = skipped = 0
for engine, entry in sorted(lock["engines"].items()):
    version = entry["version"]
    for file in entry["files"]:
        name, url, want = file["name"], file["url"], file["sha256"]
        out_path = os.path.join(dest, name)
        replacements = [
            (old.encode(), new.encode())
            for old, new in file.get("replacements", [])
        ]

        def verify(data: bytes) -> bytes:
            for old, new in replacements:
                count = data.count(old)
                if count != 1:
                    fail(f"{name}: replacement {old[:48]!r} occurs {count}x "
                         "(lock contract: exactly once) — lock/reality drift")
                data = data.replace(old, new)
            got = sha256(data)
            if got != want:
                fail(f"{name}: SHA-256 mismatch — lock pins {want}, "
                     f"fetched(+replacements) hashes to {got}. Refusing to "
                     "ship unverified vendor assets (gh-1630 E1).")
            return data

        if os.path.exists(out_path):
            data = open(out_path, "rb").read()
            got = sha256(data)
            if got == want:
                skipped += 1
                continue
            if verify_only:
                fail(f"{name}: checksum mismatch — on disk {got}, lock pins "
                     f"{want}. The staged vendor tree is stale or tampered.")
            print(f"vendor: {name} differs from the lock — re-fetching")
        elif verify_only:
            fail(f"{name}: missing from {dest} and --verify-only skips "
                 "network — run the full fetch first")
        else:
            print(f"vendor: downloading {name} ({engine} {version})")
            tmp = out_path + ".tmp"
            os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
            # -fsSL: fail on HTTP errors, follow redirects, silent; retries
            # for the flaky big-wasm legs. --retry-max-time spans CDN
            # rate-limit windows (jsdelivr 503s arrive in bursts — 4×3s
            # exhausted them and failed the whole build, gh-1630): 6 tries
            # spread over up to 5 min ride out a window per file.
            subprocess.run(
                ["curl", "-fsSL", "--retry", "6", "--retry-delay", "5",
                 "--retry-max-time", "300", "--retry-all-errors",
                 url, "-o", tmp],
                check=True,
            )
            data = open(tmp, "rb").read()
            data = verify(data)
            os.replace(tmp, out_path)
            fetched += 1
            print(f"vendor: {name} fetched + verified "
                  f"({len(data)} bytes)")
            continue
        # Existing file with drifted bytes and full mode: verify() above
        # only runs on the freshly downloaded payload; re-verify the
        # written result too.
        data = verify(data)
        with open(out_path + ".tmp", "wb") as f:
            f.write(data)
        os.replace(out_path + ".tmp", out_path)
        verified += 1

# The asyncify FFI module imports `@jitl/quickjs-ffi-types` — a bare npm
# specifier a browser page cannot resolve. The lock's replacement rewires
# it onto a vendored one-function shim (assertSync, the only export the
# module uses); this generates that companion file (not fetched — it is
# repo-owned code, so its content lives here; idempotent, gh-1630).
SHIM_NAME = "interpreters/asyncify/ffi-types-shim.mjs"
SHIM = """// Vendored shim for the single @jitl/quickjs-ffi-types export the
// asyncify FFI module uses (the vendor lock's replacement rewires the
// bare import onto this file — a browser page cannot resolve npm
// specifiers; gh-1630). assertSync wraps an emscripten cwrap'd function
// and throws if it ever returns a thenable (i.e. an unexpected asyncify
// suspension on a path declared synchronous).
export function assertSync(fn) {
  return function (...args) {
    const result = fn.apply(this, args);
    if (result != null && typeof result.then === 'function') {
      throw new Error('assertSync: function returned a promise');
    }
    return result;
  };
}
"""
shim_path = os.path.join(dest, SHIM_NAME)
os.makedirs(os.path.dirname(shim_path), exist_ok=True)
if not os.path.exists(shim_path) or open(shim_path, encoding="utf-8").read() != SHIM:
    open(shim_path, "w", encoding="utf-8").write(SHIM)
    print(f"vendor: {SHIM_NAME} written (generated companion)")

print(f"vendor: {len(lock['engines'])} engines — "
      f"{fetched} fetched, {verified} repaired, {skipped} already verified")
PY
echo "fetch_vendor_assets: OK ($lock → $dest)"
