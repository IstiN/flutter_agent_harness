/// Gate-visible red-data regression pin for issue #1422 — the
/// `AC1: resume renders 1:1 with live (normalized diff empty)` flake.
///
/// The flake red-died three times (runs 37798533323, 37774628085,
/// 37802938457) at two sites inside `pty_resume_equivalence_test.dart`'s
/// AC1 PTY test:
///
/// - Signature 1 (run 37774628085): the live leg's 30 s `Background shell
///   job` banner wait timed out because every scripted bash call died
///   with `Tool error (bash): Cannot modify an unmodifiable list` — the
///   #1408 red-head sorting `layerVendor`'s CONST empty list inside
///   `redactBashCommandSecretShapes`. Fixed on main in 98ba890b8 (the
///   emptiness check precedes the sort, lib/src/approval/
///   bash_shape_redaction.dart) and pinned gate-side by
///   test/approval/bash_shape_redaction_test.dart ("null for a command
///   without any secret shape" — a no-shape command IS the
///   const-empty-list return, the exact crash path).
///
/// - Signature 2 (runs 37798533323, 37802938457): the resumed tail
///   aligned one row early. The live screen still showed the gh-1415
///   subagent status board row `✓ done pty446 … 0s – …` below the
///   settlement notice block, while the resumed boot never replays board
///   rows (terminal-first-sight: rehydrated children are history, not
///   news) — and the pre-#1420 canonicalizer treated that row as
///   transcript grammar, so the AC1 alignment window slid one row.
///   Fixed on main in 336042cfd (#1420): the `_subagentBoardRow` rule
///   classifies the board vocabulary as chrome. But the pin test
///   carrying that rule lives inside the quarantined file, and the
///   quarantine skip is PER-FILE (scripts/apply_quarantine.py drops the
///   whole path from every PR gate) — so a canonicalizer regression
///   would reach the AC1 PTY run before any gate caught it. This file
///   re-pins the rule, and the red run's full row-level alignment,
///   where every PR gate executes it. No PTY needed: everything below
///   runs the production `transcriptOf` canonicalizer on the exact
///   failed-job dump rows.
///
/// The fixtures are the failed-job dump rows verbatim (runs 37798533323
/// and 37802938457, 2026-10-08), with the live-side settled cards rebuilt
/// in the #916 band shapes the AC1 contract pins (`✔ name: detail 0s`
/// live, `✔ name: detail —` replay). Un-quarantining the PTY file still
/// requires the gh-1199 AC4 nightly repeat-run proof; this pin makes the
/// grammar side of that proof continuously gate-checked in the meantime.
@TestOn('vm')
@Tags(['integration'])
library;

import 'package:test/test.dart';

import 'pty_resume_equivalence_test.dart' as resume_eq;

/// The anchor row every single-row probe hides below: a grammar-looking
/// (`>`-prefixed) row the trailing-trim walk stops at, so the row under
/// test always reaches the chrome/canonical pass regardless of whether it
/// is itself a trim breaker.
const _anchor = '>_Fa anchor row';

/// Runs one screen row through the production canonicalizer. Returns the
/// canonical transcript form, or null when the row is chrome (dropped
/// from the AC1 comparison entirely).
String? _classify(String row) {
  final out = resume_eq.transcriptOf([row, _anchor]);
  final kept = out.where((r) => r != _anchor).toList();
  return kept.isEmpty ? null : kept.single;
}

/// The settlement notice block as the red run's two screens painted it
/// (identical on both legs — these rows replay 1:1 by contract).
const _noticeRows = [
  '│ ⚙ Background shell job sh-2-hn0vwtxwhq6jh520 finished with exit code 0.',
  '│ ⚙ Command: sleep 2 && echo bg-pinned-render',
  '│ ⚙ Log: /tmp/fa446pVLZPVV/.fah/bash_jobs/sh-2-hn0vwtxwhq6jh520.log',
  '│ ⚙ Check the result with bash_job (action: output) or by reading the log file,',
  'and act on it when the result was awaited.',
];

/// The resumed screen's transcript at the red snapshot (run 37802938457
/// failed-job dump, `resumed transcript` block) — already in canonical
/// form, which the canonicalizer must reproduce verbatim (idempotence on
/// its own output).
const _redResumeTail = [
  'run the pinned probes for four forty six',
  '>_Fa ## Plan',
  '• run pinned probes',
  '1. first step',
  '2. second step',
  'bash: echo pinned-render-1',
  'bash: sleep 2 && echo bg-pinned-render',
  'task: PTY equivalence probe; reply with the single word ok',
  '>_Fa done — the probes settled',
  ..._noticeRows,
];

/// The live screen's transcript at the red snapshot (the same dump's
/// `live transcript` block, 9 rows) — pre-#1420 this carried the board
/// row the resumed boot never paints, which is the whole flake.
const _redLiveTail = [
  'bash: sleep 2 && echo bg-pinned-render',
  'task: PTY equivalence probe; reply with the single word ok',
  '>_Fa done — the probes settled',
  ..._noticeRows,
  '✓ done pty446             0s    – reply with the single word ok',
];

void main() {
  test(
    'gh-1422 sig-2: the exact red board row is chrome, never transcript '
    'grammar',
    () {
      expect(
        _classify('✓ done pty446             0s    – reply with the single '
            'word ok'),
        isNull,
        reason:
            'the subagent board row re-entered the transcript grammar — '
            'the AC1 alignment window shifts one row again (issue #1422 '
            'signature 2: run 37802938457, location [0] off-by-one)',
      );
    },
  );

  test('gh-1422: the full subagent board vocabulary stays chrome', () {
    // The gh-1415 vocabulary is one glyph per display state; the matcher
    // accepts glyph+verb pairs as painted. Every combination must drop,
    // or a vocabulary rename silently reintroduces the sig-2 off-by-one.
    for (final glyph in ['⠿', '⏸', '✓', '✗']) {
      for (final verb in ['run', 'wait', 'done', 'fail']) {
        expect(
          _classify('$glyph $verb probe-child      1.2s    – probe task'),
          isNull,
          reason: 'board row "$glyph $verb …" leaked into the transcript',
        );
      }
    }
  });

  test('gh-1422: the settlement notice block stays transcript grammar', () {
    for (final row in _noticeRows) {
      expect(
        _classify(row),
        row,
        reason: 'a settlement notice row went chrome — the resumed tail '
            'loses rows the live tail keeps (issue #1422 failure class)',
      );
    }
  });

  test('gh-1422: settled cards canonicalize identically across the legs',
      () {
    // The #916 contract on the red scenario's exact cards: the live card
    // carries the elapsed cell, the replay card the honest `—` — both
    // must canonicalize to the same `name: detail` core or AC1's 1:1
    // equality red-dies on the card rows themselves.
    const cards = [
      [
        '✔ bash: sleep 2 && echo bg-pinned-render 0s',
        '✔ bash: sleep 2 && echo bg-pinned-render —',
      ],
      ['✔ bash: echo pinned-render-1 0.3s', '✔ bash: echo pinned-render-1 —'],
      [
        '✔ task: PTY equivalence probe; reply with the single word ok 4.1s',
        '✔ task: PTY equivalence probe; reply with the single word ok —',
      ],
    ];
    for (final pair in cards) {
      final live = _classify(pair[0]);
      expect(live, isNotNull, reason: 'live card dropped: ${pair[0]}');
      expect(
        live,
        _classify(pair[1]),
        reason: 'live/replay card cores diverged for ${pair[0]}',
      );
    }
  });

  test('gh-1422: the red live screen normalizes to the post-#1420 tail', () {
    // The live screen's tail at the red snapshot, rebuilt in the shapes
    // the band contract paints: settled cards with live elapsed cells,
    // the notice block, and the board row still on screen below it (the
    // row whose presence-vs-collapse raced the settle snapshot pre-#1420;
    // post-#1420 it is chrome and must vanish from the comparison).
    final out = resume_eq.transcriptOf(const [
      '✔ bash: sleep 2 && echo bg-pinned-render 0s',
      '✔ task: PTY equivalence probe; reply with the single word ok 4.1s',
      '>_Fa done — the probes settled',
      ..._noticeRows,
      '✓ done pty446             0s    – reply with the single word ok',
    ]);
    expect(
      out,
      _redLiveTail.sublist(0, _redLiveTail.length - 1),
      reason: 'the board row must be the ONLY row the live tail loses',
    );
  });

  test('gh-1422: the red run resumed tail is canonicalizer-idempotent', () {
    for (final row in _redResumeTail) {
      expect(
        _classify(row),
        row,
        reason: 're-canonicalizing the resumed tail mutated "$row"',
      );
    }
  });

  test('gh-1422: the red run live/resume tails align 1:1 (the AC1 window)',
      () {
    // The exact alignment assertion that red at 37798533323 and
    // 37802938457, replayed through the row classifier: the resumed tail
    // and the live tail must align on the LAST liveTail.length rows.
    // Pre-#1420 the live side carried the board row and the sides
    // mis-aligned by one row; this pin fails the moment the
    // classification regresses.
    final liveTail = <String>[];
    for (final row in _redLiveTail) {
      final canonical = _classify(row);
      if (canonical != null) liveTail.add(canonical);
    }
    final resumeTail = <String>[];
    for (final row in _redResumeTail) {
      final canonical = _classify(row);
      if (canonical != null) resumeTail.add(canonical);
    }
    expect(liveTail, hasLength(8),
        reason: 'the red live tail minus its one chrome row (the board)');
    expect(resumeTail, hasLength(_redResumeTail.length));
    expect(
      resumeTail.sublist(resumeTail.length - liveTail.length),
      liveTail,
      reason: 'the AC1 alignment failed again — the resumed window slid '
          '(issue #1422 signature 2 regression)',
    );
  });
}
