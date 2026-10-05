// REG guard for the gh-1000 rework CI breakage family: a merge of main
// into the feature branch resolved `bin/fah.dart` and
// `lib/src/cli/session_commands.dart` as TAKE-OURS, silently deleting
// main's boot wiring (wire-serve interception #1103, the jsr pass-through
// gh-1033, session rotation warnings gh-1077, the provider-timeout env
// override #1036, gh-1059 boot diagnostics, the fresh-install wizard #969,
// the quota feed #823, skill toggles #1151, the gh-968 resume parity
// budget + mailbox-prefix projection, and the #964 authHeader restore).
// Nothing failed to COMPILE — the dropped call sites went away together
// with their imports — so `dart analyze` stayed green and the break only
// surfaced as red CI legs (and a `fa wire-serve --stdio` that answered
// "unknown argument: --stdio").
//
// Hermetic source grep (no PTY, no network), runs in the DEFAULT suite so
// the pre-commit fast gate enforces it: every boot-wiring symbol that the
// lib/bin layers provide for the executable MUST be referenced from the
// executable's main. A future rename updates the guard in the same commit
// — a drop is never silent again.
import 'dart:io';

import 'package:test/test.dart';

/// Each entry: file → symbols whose ONLY reason to exist is the bin main
/// wiring (or, for the `part of agent_cli.dart` session extension, the
/// resume glue main-side boot mirrors). The comment names the feature so
/// an intentional removal updates this list knowingly.
const _requiredReferences = <String, List<String>>{
  // gh-1232: the executable's library — `bin/fah.dart` plus the bin/
  // part files it declares. The check concatenates them (see
  // _executableSource), so a symbol is pinned no matter which of them
  // it lives in; a symbol leaving the executable library entirely is
  // still a violation.
  'bin/fah.dart': [
    // `fa wire-serve` interception (issue #1103).
    'splitWireServeArgs',
    // `fa jsr …` pass-through (gh-1033).
    'runJsrCliCommand',
    // Session segment rotation warnings on stderr (gh-1077).
    'onRotationWarning',
    // FA_PROVIDER_TIMEOUT_SECONDS env override fold-in (issue #1036).
    'applyProviderTimeoutEnvOverride',
    // Boot key diagnostics — every read logged / nothing-resolved warning
    // (gh-1059).
    'secureKeyBootDiagnostics',
    // Fresh-install guided add-provider wizard (issue #969).
    'freshInstallProviderState',
    // Provider quota badge + queue quota feed rebind (issue #823).
    'attachProviderQueueQuotaFeed',
    // Global per-skill toggles (`skills:` section, issue #1151).
    'skillToggles',
    // gh-1198: the --stream-thinking flag > output.streamThinking config
    // resolution wired into the run config.
    'resolveStreamThinking',
  ],
  'lib/src/cli/session_commands.dart': [
    // gh-968 (AC-R3): resume prices the FIRST request (parity budget).
    'resumeParityBudget',
    // gh-968: the messaging section's mailbox prefix is projected at
    // resume, before mailbox-prefix sync runs in boot order.
    '_assignMailboxPrefix',
    // Issue #964: a restored endpoint's saved authHeader survives.
    'authHeaderForBaseUrl',
  ],
};

/// gh-1232: `bin/fah.dart` was split into `part`/`part of` files under
/// `bin/` (the executable library is the primary file PLUS its part
/// files). The guard pins symbols to the whole executable library: the
/// primary source and every `part '...';` it declares, concatenated.
String _executableSource() {
  final primary = File('bin/fah.dart').readAsStringSync();
  final buffer = StringBuffer(primary);
  for (final match in RegExp(
    "^part '(fah_[^']+\\.dart)';",
    multiLine: true,
  ).allMatches(primary)) {
    buffer.write('\n${File('bin/${match[1]}').readAsStringSync()}');
  }
  return buffer.toString();
}

void main() {
  test('bin main keeps every boot-wiring symbol (gh-1000 rework reg)', () {
    final violations = <String>[];
    _requiredReferences.forEach((path, symbols) {
      if (path == 'bin/fah.dart') {
        // The executable library: primary + its bin/ part files.
        final source = _executableSource();
        for (final symbol in symbols) {
          if (!source.contains(symbol)) {
            violations.add('$path: no reference to `$symbol`');
          }
        }
        return;
      }
      final file = File(path);
      if (!file.existsSync()) {
        violations.add('$path: FILE MISSING');
        return;
      }
      final source = file.readAsStringSync();
      for (final symbol in symbols) {
        if (!source.contains(symbol)) {
          violations.add('$path: no reference to `$symbol`');
        }
      }
    });
    expect(
      violations,
      isEmpty,
      reason: '''
A boot-wiring symbol disappeared from the executable's main. This is the
gh-1000-rework failure shape: a take-ours merge resolution deletes main's
call sites together with their imports, analyze stays green, and the
feature dies silently (wire-serve, jsr, rotation warnings, timeout env
override, boot diagnostics, fresh-install wizard, quota feed, skill
toggles, resume parity). If the symbol moved INTENTIONALLY, update
_requiredReferences in the same commit — never delete the reference
without a replacement wiring.
''',
    );
  });
}
