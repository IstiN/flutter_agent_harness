/// The bash-guard self-defense kit (gh-1763): shim script builders and the
/// per-process provisioning for `pkill` / `killall` PATH shims plus the
/// protected-pid chain of the running harness.
///
/// Why: a `bash` tool command like `pkill -f "dart "` matched (a) its own
/// `sh -c` wrapper (the raw script used to ride the wrapper argv) and (b)
/// the `fa` harness itself (or a supervisor on its ancestor chain) — the
/// session then aborted mid-run (`exit -15` on the tool call, `SIGTERM` /
/// `exit 130` on fa). The guard makes the harness chain and the invoking
/// shell exempt from the child's own broad kills while legitimate victims
/// (a stuck test runner, a background server) are still signaled.
///
/// Platform glue only — exported from `lib/io.dart`. Provisioning never
/// throws: every failure degrades to `null` (= no guard, legacy `sh -c`
/// behavior). Windows has no pkill/pgrep and keeps `cmd /c` verbatim, so
/// the guard is POSIX-only.
library;

import 'dart:io';

/// The env var carrying the protected pid set into every bash tool call
/// (space-separated): the harness pid, its ancestor chain up to init, and
/// the harness process group. The `kill()` prelude and both shims read it.
const String bashGuardPidsEnv = 'FA_PROTECTED_PIDS';

/// The guard prelude prepended to every bash tool script (POSIX):
///
/// - `set --` restores `sh -c` positional-parameter parity (`$#` = 0, empty
///   `"$@"`) — the `. "$1"` delivery otherwise leaves the script path as
///   `$1`.
/// - `kill()` filters [bashGuardPidsEnv] pids (and their `-pgid` group
///   targets) out of the arguments before invoking the real `kill`. No
///   protected hit → the call is passed through byte-identical. Every
///   construct is `set -e`/`set -u`-safe (if-chains, guarded expansions).
String bashGuardPrelude() => '''
# ── fa bash-guard (gh-1763): self-defense prelude ──────────────────────
# Restore sh -c positional-parameter parity, then keep kill() from
# signaling the harness/ancestor pids exported via $bashGuardPidsEnv.
set --
kill() {
  __fa_rest=''
  __fa_pids_left=0
  __fa_hit=0
  for __fa_a in "\$@"; do
    case "\$__fa_a" in
      ''|-|--|%*|-[A-Za-z]*)
        __fa_rest="\$__fa_rest \$__fa_a"
        ;;
      -[0-9]*)
        __fa_n="\${__fa_a#-}"
        __fa_keep=1
        for __fa_p in \${$bashGuardPidsEnv:-}; do
          if [ "\$__fa_n" = "\$__fa_p" ]; then __fa_keep=0; break; fi
        done
        if [ "\$__fa_keep" = 1 ]; then
          __fa_hit=1
        else
          __fa_rest="\$__fa_rest \$__fa_a"
        fi
        ;;
      *)
        __fa_keep=1
        for __fa_p in \${$bashGuardPidsEnv:-}; do
          if [ "\$__fa_a" = "\$__fa_p" ]; then __fa_keep=0; break; fi
        done
        if [ "\$__fa_keep" = 1 ]; then
          __fa_rest="\$__fa_rest \$__fa_a"
          __fa_pids_left=\$((__fa_pids_left + 1))
        else
          __fa_hit=1
        fi
        ;;
    esac
  done
  if [ "\$__fa_hit" = 0 ]; then
    command kill "\$@"
    return
  fi
  __fa_rc=0
  if [ "\$__fa_pids_left" -gt 0 ]; then
    # shellcheck disable=SC2086 — every surviving arg is a single word.
    command kill \$__fa_rest || __fa_rc=\$?
  fi
  echo 'fa: kill skipped protected pid(s) (gh-1763 bash-guard)' >&2
  return "\$__fa_rc"
}
''';

/// The `pkill` PATH shim: expands the match with the REAL `pgrep` (the
/// same selection engine and flags), filters the protected pids, the
/// invoking shell (`PPID`) and the shim itself, then signals the rest with
/// the requested signal (default `SIGTERM`). Selection shapes the shim
/// does not model (signal after the pattern, `-u root`, `-t tty`, `-n`,
/// `-o`, …) exec the real `pkill` — honest behavior over silent guessing.
String buildPkillShim({required String realPkill, required String realPgrep}) =>
    r'''#!/bin/sh
# fa bash-guard shim for pkill (gh-1763): never signals the harness or its
# ancestor chain, the invoking shell, or itself.
set -u
FA_REAL_PKILL='__FA_REAL_PKILL__'
FA_REAL_PGREP='__FA_REAL_PGREP__'

sig=''
sel=''
# Flags that would corrupt the victim set if they reached pgrep (c = count
# mode prints a number the loop would read as a pid, v = negated match)
# never enter the guarded path — the real pkill decides.
for a in "$@"; do
  case "$a" in
    -[a-zA-Z]*)
      fa_body="${a#-}"
      case "$fa_body" in
        [0-9]*|[Ss][Ii][Gg]*|[A-Z]*) continue ;;
      esac
      fa_rest="$fa_body"
      while [ -n "$fa_rest" ]; do
        fa_c="${fa_rest%"${fa_rest#?}"}"
        case "$fa_c" in
          [cv]) exec "$FA_REAL_PKILL" "$@" ;;
        esac
        fa_rest="${fa_rest#?}"
      done
      ;;
  esac
done
while [ $# -gt 0 ]; do
  case "$1" in
    --signal) sig="${2-}"; shift 2 ;;
    --signal=*) sig="${1#--signal=}"; shift ;;
    --) shift; break ;;
    -[0-9]*) sig="$1"; shift ;;
    -[Ss][Ii][Gg][A-Za-z]*|-[A-Z][A-Z]*) sig="$1"; shift ;;
    -*) sel="$sel $1"; shift ;;
    *) break ;;
  esac
done
# Exactly one operand (the pattern) must remain; anything else — unknown
# flags interleaved with it, extra operands — is the real pkill's call.
if [ "$#" -ne 1 ]; then
  exec "$FA_REAL_PKILL" "$@"
fi

# The selection flags ride along: pgrep shares pkill's selection engine.
pids=$("$FA_REAL_PGREP" $sel "$@" 2>/dev/null)
rc=$?
if [ "$rc" -ge 2 ]; then
  # pgrep rejected the selection (a flag it does not share): the real
  # pkill decides, semantics stay honest.
  exec "$FA_REAL_PKILL" "$@"
fi
[ "$rc" -eq 0 ] || exit 1
# pgrep -l rows are "pid name" — keep the pid column.
pids=$(printf '%s\n' "$pids" | cut -d' ' -f1)

self=$$
parent="${PPID:-}"
out=0
for p in $pids; do
  case " ${FA_PROTECTED_PIDS:-} " in *" $p "*) continue ;; esac
  if [ "$p" = "$parent" ] || [ "$p" = "$self" ]; then continue; fi
  if [ -n "$sig" ]; then
    kill "$sig" "$p" 2>/dev/null && out=1
  else
    kill -TERM "$p" 2>/dev/null && out=1
  fi
done
[ "$out" -eq 1 ] && exit 0
exit 1
'''
        .replaceAll('__FA_REAL_PKILL__', realPkill)
        .replaceAll('__FA_REAL_PGREP__', realPgrep);

/// The `killall` PATH shim: exact comm-name match via the real
/// `pgrep -x` (killall semantics), same exclusion set as [buildPkillShim].
/// Any flag the shim does not model (`-i`, `-q`, `-u`, `-o`, `-y`, …)
/// execs the real `killall`.
String buildKillallShim({
  required String realKillall,
  required String realPgrep,
}) => r'''#!/bin/sh
# fa bash-guard shim for killall (gh-1763): never signals the harness or
# its ancestor chain, the invoking shell, or itself.
set -u
FA_REAL_KILLALL='__FA_REAL_KILLALL__'
FA_REAL_PGREP='__FA_REAL_PGREP__'

sig=''
names=''
while [ $# -gt 0 ]; do
  case "$1" in
    --signal) sig="${2-}"; shift 2 ;;
    --signal=*) sig="${1#--signal=}"; shift ;;
    -[0-9]*) sig="$1"; shift ;;
    -[Ss][Ii][Gg][A-Za-z]*|-[A-Z][A-Z]*) sig="$1"; shift ;;
    -*) exec "$FA_REAL_KILLALL" "$@" ;;
    *) names="$names $1"; shift ;;
  esac
done
[ -n "$names" ] || exec "$FA_REAL_KILLALL" "$@"

self=$$
parent="${PPID:-}"
out=0
for n in $names; do
  pids=$("$FA_REAL_PGREP" -x "$n" 2>/dev/null) || continue
  for p in $pids; do
    case " ${FA_PROTECTED_PIDS:-} " in *" $p "*) continue ;; esac
    if [ "$p" = "$parent" ] || [ "$p" = "$self" ]; then continue; fi
    if [ -n "$sig" ]; then
      kill "$sig" "$p" 2>/dev/null && out=1
    else
      kill -TERM "$p" 2>/dev/null && out=1
    fi
  done
done
[ "$out" -eq 1 ] && exit 0
exit 1
'''
    .replaceAll('__FA_REAL_KILLALL__', realKillall)
    .replaceAll('__FA_REAL_PGREP__', realPgrep);

/// The per-process bash guard: a private temp dir holding the PATH shims
/// and the protected pid set injected into every bash tool call. [shimDir]
/// is null when no shim applied (pkill/killall/pgrep missing on the host) —
/// the pid set still arms the `kill()` prelude.
final class BashGuardProvision {
  /// Creates the provision. Never throws on the caller side: provisioning
  /// failures degrade to a null provision instead.
  const BashGuardProvision({required this.shimDir, required this.protectedPids});

  /// Private temp dir (0700) with the executable `pkill`/`killall` shims;
  /// prepended to PATH. Null when no shim applies.
  final String? shimDir;

  /// The protected pids: the harness pid, its ancestor chain up to init,
  /// and the harness process group.
  final List<int> protectedPids;

  /// The env/PATH overlay for a bash tool spawn: [bashGuardPidsEnv] plus
  /// the shim dir at the head of PATH (in front of any inherited or
  /// widened PATH, so the shims always win).
  Map<String, String> environmentOverlay() {
    final overlay = <String, String>{
      bashGuardPidsEnv: protectedPids.join(' '),
    };
    final dir = shimDir;
    if (dir != null) {
      overlay['FA_GUARD_SHIM_DIR'] = dir;
    }
    return overlay;
  }
}

/// Provisions the guard once per process. POSIX only — null on Windows and
/// on any failure (never throws).
Future<BashGuardProvision?> provisionBashGuard() async {
  if (Platform.isWindows) return null;
  try {
    final pids = await _protectedPidChain();
    final realPgrep = await _resolveTool('pgrep');
    final shims = <String, String>{};
    final realPkill = await _resolveTool('pkill');
    if (realPkill != null && realPgrep != null) {
      shims['pkill'] = buildPkillShim(realPkill: realPkill, realPgrep: realPgrep);
    }
    final realKillall = await _resolveTool('killall');
    if (realKillall != null && realPgrep != null) {
      shims['killall'] = buildKillallShim(
        realKillall: realKillall,
        realPgrep: realPgrep,
      );
    }
    String? shimDir;
    if (shims.isNotEmpty) {
      final dir = await Directory.systemTemp.createTemp('fa_sh_guard_');
      for (final entry in shims.entries) {
        final file = File('${dir.path}/${entry.key}');
        await file.writeAsString(entry.value);
        await Process.run('chmod', <String>['700', file.path]);
      }
      shimDir = dir.path;
    }
    return BashGuardProvision(shimDir: shimDir, protectedPids: pids);
  } on Object {
    return null;
  }
}

/// The harness pid + ancestor chain (up to, but excluding, init) + the
/// harness process group. Best-effort: a failing `ps` probe still yields
/// the own pid, so the prelude always has something to protect.
Future<List<int>> _protectedPidChain() async {
  final chain = <int>{pid};
  try {
    final ps = await Process.run('ps', <String>['-ax', '-o', 'pid=,ppid=']);
    final parentOf = <int, int>{};
    for (final line in (ps.stdout as String).split('\n')) {
      final cols = line.trim().split(RegExp(r'\s+'));
      if (cols.length < 2) continue;
      final p = int.tryParse(cols[0]);
      final pp = int.tryParse(cols[1]);
      if (p != null && pp != null) parentOf[p] = pp;
    }
    var current = pid;
    while (chain.length < 64) {
      final parent = parentOf[current];
      if (parent == null || parent <= 1) break;
      if (!chain.add(parent)) break;
      current = parent;
    }
    final pg = await Process.run(
      'ps',
      <String>['-o', 'pgid=', '-p', '$pid'],
    );
    final group = int.tryParse((pg.stdout as String).trim());
    if (group != null && group > 1) chain.add(group);
  } on Object {
    // The own pid already protects the harness itself.
  }
  return chain.toList();
}

/// Resolves a tool through the host PATH (before the shim dir exists, so
/// this finds the real binary). Null when absent.
Future<String?> _resolveTool(String name) async {
  try {
    final result = await Process.run('sh', <String>[
      '-c',
      'command -v $name',
    ]);
    if (result.exitCode != 0) return null;
    final path = (result.stdout as String).trim();
    return path.isEmpty ? null : path;
  } on Object {
    return null;
  }
}
