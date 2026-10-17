#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  gh-1644 — update_git_mirror.sh self-test                                  ║
# ║  The contract closes the run-38855793382 incident ("Update local git      ║
# ║  mirrors" died exit 128 — "error: 2931 bytes of body are still            ║
# ║  expected"): the old inline workflow logic fetched ONCE (stderr            ║
# ║  swallowed), fell through to a full `git clone --mirror` whose ~1 h       ║
# ║  transfer died mid-flight, and had no retry and no partial-dir cleanup.   ║
# ║  Scenarios (local file:// fixture remotes, fault-injected `git` shim):    ║
# ║    T1 fresh clone creates a working mirror                                ║
# ║    T2 fetch advances the mirror to new remote commits                     ║
# ║    T3 a poisoned partial mirror dir is recovered (recreate)               ║
# ║    T4 THE INCIDENT: transient fetch failure + armed clone failure —       ║
# ║        a fetch RETRY must recover with NO recreate (the legacy logic      ║
# ║        recreated, hit the failing clone and died exit 128)                ║
# ║    T5 persistent clone failure → nonzero exit after exactly               ║
# ║        MIRROR_CLONE_ATTEMPTS logged attempts, ::error marker, no          ║
# ║        partial dir left behind                                            ║
# ║    T6 a recreated mirror records the blob:none filter (gh-1477            ║
# ║        precedent — blobless mirror shrinks the flake window ~60 min→min)  ║
# ║    T7 fetch-retry exhaustion falls back to a successful recreate          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Run from anywhere:  bash scripts/update_git_mirror_selftest.sh
# Legacy replay:      bash scripts/update_git_mirror_selftest.sh --legacy
#   --legacy runs the incident scenarios against the PRE-FIX inline
#   workflow logic (embedded below, verbatim behavior of the old
#   build-macos.yml step): every scenario PASSES iff the legacy logic
#   FAILS the contract — i.e. the bug is reproduced. Zero legacy failures
#   means the repro is broken.

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root, any cwd
MODE="${1:-}"
SCRIPT="scripts/update_git_mirror.sh"
if [ "$MODE" != "--legacy" ] && [ ! -f "$SCRIPT" ]; then
  echo "❌ $SCRIPT missing — run this selftest from the repo root" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Resolve the REAL git binary — NOT a PATH wrapper. This runner prepends a
# git-push-guard shim to PATH; exec-ing it from OUR shim would ping-pong
# (the wrapper re-resolves `git` via PATH back into the shim) and spin.
# `command -v -p` resolves against the system default PATH.
REAL_GIT="$(command -v -p git 2>/dev/null || true)"
if [ -z "$REAL_GIT" ]; then REAL_GIT="$(command -v git)"; fi

pass=0
fail=0
ok()   { pass=$((pass + 1)); echo "✅ $1"; }
bad()  { fail=$((fail + 1)); echo "❌ $1" >&2; }
label_legacy() { [ "$MODE" = "--legacy" ] && echo "legacy" || echo "script"; }

# ── pre-fix inline logic (the bug), verbatim from the old workflow step ────
legacy_update_mirror() {
  local url="$1" mirror="$2"
  if [ ! -d "$mirror" ]; then
    git clone --mirror "$url" "$mirror"
  else
    if ! git -C "$mirror" fetch origin 2>/dev/null; then
      echo "Fetch failed — recreating mirror: $mirror"
      rm -rf "$mirror"
      git clone --mirror "$url" "$mirror"
    fi
  fi
}

update_mirror() {
  if [ "$MODE" = "--legacy" ]; then
    legacy_update_mirror "$@"
  else
    bash "$SCRIPT" "$@"
  fi
}

# ── fault-injecting git shim: fails the first N fetch/clone calls with ─────
# ── the incident's error signature, then delegates to the real git ─────────
make_shim() {
  local dir="$1" fail_fetch="$2" fail_clone="$3"
  mkdir -p "$dir"
  echo "$fail_fetch" > "$dir/fetch_left"
  echo "$fail_clone" > "$dir/clone_left"
  cat > "$dir/git" <<SHIM
#!/usr/bin/env bash
REAL_GIT="$REAL_GIT"
LEFT="$(cd "$dir" && pwd)"
sub=""; skip=0
for a in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  case "\$a" in
    -c|-C) skip=1 ;;
    -*) ;;
    *) sub="\$a"; break ;;
  esac
done
case "\$sub" in
  fetch)
    if [ "\$(cat "\$LEFT/fetch_left")" -gt 0 ]; then
      echo \$(( \$(cat "\$LEFT/fetch_left") - 1 )) > "\$LEFT/fetch_left"
      echo "error: 2931 bytes of body are still expected" >&2
      echo "fetch-pack: unexpected disconnect while reading sideband packet" >&2
      exit 128
    fi ;;
  clone)
    if [ "\$(cat "\$LEFT/clone_left")" -gt 0 ]; then
      echo \$(( \$(cat "\$LEFT/clone_left") - 1 )) > "\$LEFT/clone_left"
      echo "error: 2931 bytes of body are still expected" >&2
      echo "fatal: early EOF" >&2
      exit 128
    fi ;;
esac
exec "\$REAL_GIT" "\$@"
SHIM
  chmod +x "$dir/git"
}

use_shim() {  # $1 = shim dir ("" = restore real git)
  if [ -n "$1" ]; then PATH="$1:$REAL_PATH"; else PATH="$REAL_PATH"; fi
}

# ── fixture: a local bare "origin" ──────────────────────────────────────────
make_fixture() {
  local d="$1"
  git init -q "$d/work"
  git -C "$d/work" config user.email t@example.com
  git -C "$d/work" config user.name t
  echo one > "$d/work/file.txt"
  git -C "$d/work" add .
  git -C "$d/work" commit -qm one
  git clone -q --bare "$d/work" "$d/remote.git"
}

advance_fixture() {  # $1 = fixture root — one more commit on the remote
  git -C "$1/work" commit -qm "two-$RANDOM" --allow-empty
  git -C "$1/work" push -q "$1/remote.git" HEAD
}

mirror_head() { git -C "$1" log --oneline -1 2>/dev/null | head -1; }

export REAL_PATH="$PATH"
export MIRROR_RETRY_SLEEP=0

# ══ T1: fresh clone creates a working mirror ════════════════════════════════
t1() {
  local d="$WORK/t1"; mkdir -p "$d"; make_fixture "$d"
  local out rc
  out=$(update_mirror "file://$d/remote.git" "$d/mirror.git" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$(mirror_head "$d/mirror.git")" ]; then
    ok "T1 fresh clone creates a working mirror ($(label_legacy))"
  else
    bad "T1 fresh clone FAILED ($(label_legacy)): rc=$rc — $out"
  fi
}

# ══ T2: fetch advances the mirror to new remote commits ═════════════════════
t2() {
  local d="$WORK/t2"; mkdir -p "$d"; make_fixture "$d"
  update_mirror "file://$d/remote.git" "$d/mirror.git" >/dev/null 2>&1
  local before after
  before=$(mirror_head "$d/mirror.git")
  advance_fixture "$d"
  local out rc
  out=$(update_mirror "file://$d/remote.git" "$d/mirror.git" 2>&1); rc=$?
  after=$(mirror_head "$d/mirror.git")
  if [ "$rc" -eq 0 ] && [ "$before" != "$after" ]; then
    ok "T2 fetch advances the mirror ($(label_legacy))"
  else
    bad "T2 fetch update FAILED ($(label_legacy)): rc=$rc before='$before' after='$after' — $out"
  fi
}

# ══ T3: poisoned partial dir is recovered ═══════════════════════════════════
t3() {
  local d="$WORK/t3"; mkdir -p "$d"; make_fixture "$d"
  mkdir -p "$d/mirror.git"          # partial dir left by a killed clone
  echo garbage > "$d/mirror.git/HEAD"
  local out rc
  out=$(update_mirror "file://$d/remote.git" "$d/mirror.git" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$(mirror_head "$d/mirror.git")" ]; then
    ok "T3 poisoned partial dir recovered ($(label_legacy))"
  else
    bad "T3 poisoned-dir recovery FAILED ($(label_legacy)): rc=$rc — $out"
  fi
}

# ══ T4: THE INCIDENT — transient fetch failure, clone armed to fail ═════════
# The old logic must NOT pass here: it swallowed the fetch error, recreated
# and died on the failing clone (run 38855793382, exit 128). The fixed
# script must recover via a fetch RETRY with NO recreate at all.
t4() {
  local d="$WORK/t4"; mkdir -p "$d"; make_fixture "$d"
  update_mirror "file://$d/remote.git" "$d/mirror.git" >/dev/null 2>&1
  local before
  before=$(mirror_head "$d/mirror.git")
  make_shim "$d/shim" 1 1   # fetch fails once; a clone WOULD fail once
  use_shim "$d/shim"
  local out rc
  out=$(update_mirror "file://$d/remote.git" "$d/mirror.git" 2>&1); rc=$?
  use_shim ""
  if [ "$MODE" = "--legacy" ]; then
    if [ "$rc" -ne 0 ]; then
      ok "L1 legacy died on the incident (rc=$rc) — repro confirmed"
    else
      bad "L1 legacy unexpectedly SURVIVED the incident — repro is broken"
    fi
    if echo "$out" | grep -q "recreating"; then
      ok "L2 legacy recreated on the first fetch hiccup (the expensive path)"
    else
      bad "L2 legacy did not recreate — repro shape changed"
    fi
  else
    if [ "$rc" -eq 0 ] && [ "$(mirror_head "$d/mirror.git")" = "$before" ] \
       && ! echo "$out" | grep -q "recreate"; then
      ok "T4 incident recovered via fetch retry — no recreate attempted"
    else
      bad "T4 incident NOT recovered: rc=$rc — $out"
    fi
  fi
}

# ══ T5: persistent clone failure → bounded attempts, ::error, clean dir ═════
t5() {
  local d="$WORK/t5"; mkdir -p "$d"
  local out rc
  out=$(MIRROR_CLONE_ATTEMPTS=2 update_mirror "file://$d/nope.git" "$d/mirror.git" 2>&1); rc=$?
  local attempts
  attempts=$(echo "$out" | grep -c "recreate attempt [0-9]*/2" || true)
  if [ "$MODE" = "--legacy" ]; then
    if [ "$rc" -ne 0 ] && [ "$attempts" -eq 0 ]; then
      ok "L3 legacy: single-shot clone (0 retry attempts logged) — repro confirmed"
    else
      bad "L3 legacy retry shape changed (rc=$rc attempts=$attempts)"
    fi
  else
    if [ "$rc" -ne 0 ] && [ "$attempts" -eq 2 ] \
       && echo "$out" | grep -q "::error::" && [ ! -d "$d/mirror.git" ]; then
      ok "T5 persistent clone failure: exactly $attempts recreate attempts, ::error::, no partial dir"
    else
      bad "T5 persistent clone failure contract broken: rc=$rc attempts=$attempts — $out"
    fi
  fi
}

# ══ T6: recreated mirror records the blob:none filter ═══════════════════════
t6() {
  if [ "$MODE" = "--legacy" ]; then
    ok "L4 legacy has no blobless recreate — the hour-long transfer window stands"
    return 0
  fi
  local d="$WORK/t6"; mkdir -p "$d"; make_fixture "$d"
  mkdir -p "$d/mirror.git"; echo garbage > "$d/mirror.git/HEAD"   # force recreate
  local out rc flt
  out=$(update_mirror "file://$d/remote.git" "$d/mirror.git" 2>&1); rc=$?
  flt=$(git -C "$d/mirror.git" config --get remote.origin.partialclonefilter 2>/dev/null || true)
  if [ "$rc" -eq 0 ] && [ "$flt" = "blob:none" ]; then
    ok "T6 recreated mirror records blob:none (blobless; degraded no-op on local fixtures, honored on GitHub)"
  else
    bad "T6 blobless recreate broken: rc=$rc filter='$flt' — $out"
  fi
}

# ══ T7: fetch-retry exhaustion falls back to a successful recreate ══════════
t7() {
  if [ "$MODE" = "--legacy" ]; then return 0; fi   # legacy parity: recreates on first fetch failure (T4/L2)
  local d="$WORK/t7"; mkdir -p "$d"; make_fixture "$d"
  update_mirror "file://$d/remote.git" "$d/mirror.git" >/dev/null 2>&1
  make_shim "$d/shim" 99 0   # every fetch fails; clones fine
  use_shim "$d/shim"
  local out rc
  out=$(MIRROR_FETCH_ATTEMPTS=2 update_mirror "file://$d/remote.git" "$d/mirror.git" 2>&1); rc=$?
  use_shim ""
  if [ "$rc" -eq 0 ] && [ -n "$(mirror_head "$d/mirror.git")" ] \
     && echo "$out" | grep -q "recreate"; then
    ok "T7 fetch exhaustion falls back to recreate — mirror usable again"
  else
    bad "T7 recreate fallback FAILED: rc=$rc — $out"
  fi
}

echo "── gh-1644 update_git_mirror self-test (mode: ${MODE:-script}) ──"
if [ "$MODE" = "--legacy" ]; then
  t4; t5; t6
else
  t1; t2; t3; t4; t5; t6; t7
fi

echo ""
if [ "$fail" -gt 0 ]; then
  echo "❌ SELF-TEST FAILED: $pass passed, $fail failed" >&2
  exit 1
fi
echo "✅ SELF-TEST PASSED: $pass scenarios"
[ "$MODE" = "--legacy" ] \
  && echo "   (legacy mode: every pass = the pre-fix bug reproduced)" \
  || echo "   (the mirror-update contract of gh-1644 holds)"
exit 0
