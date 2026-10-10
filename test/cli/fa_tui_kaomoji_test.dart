// The busy row's kaomoji thinking indicator (issue #1374): the eight
// two-tone faces and the ~0.9 s random-swap cadence — MODEL-SIDE state
// only since gh-1446: the TUI busy row renders plain text (no face, no
// spinner; motion lives in the status-line brand zone), so the face
// machinery stays alive as state + the app/web hosts keep rendering the
// shared set (lib/src/kaomoji_faces.dart).
//
// All randomness routes through the `kaomojiPick` constructor seam —
// no test depends on [math.Random] sequence.
library;

import 'dart:io';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';

import 'package:test/test.dart';

void main() {
  final ansi = RegExp(r'\x1b\[[0-9;?]*[A-Za-z]');

  FaTuiCallbacks callbacks() => FaTuiCallbacks(
    onSubmit: (_, {images = const []}) async {},
    onModelSelected: (_) async {},
    buildSlashMenu: (_) => const [],
    buildModelMenu: (_, _) => const [],
    statusLine: () => '',
    prompt: '',
  );

  FaTuiModel model({int width = 80, int Function(int max)? pick}) => FaTuiModel(
    callbacks: callbacks(),
    isExited: () => false,
    termWidth: width,
    kaomojiPick: pick,
  );

  /// A busy model pinned to face [face] (deterministic frames).
  FaTuiModel faceModel(int face, {int width = 80}) {
    var m = model(width: width, pick: (_) => face);
    m = m.update(BusyMsg(true, source: 'run')).$1 as FaTuiModel;
    return m.copyWith(kaomojiFace: face);
  }

  String busyRowOf(FaTuiModel m, {String marker = '· run'}) => m
      .view()
      .content
      .split('\n')
      .map((line) => line.replaceAll(ansi, ''))
      .firstWhere((line) => line.contains(marker));

  test('gh-1446 AC4: the busy row carries NO face in any cell', () {
    // The row is plain text at column 0 — the face index is inert state.
    for (var i = 0; i < kKaomojiFaces.length; i++) {
      final row = busyRowOf(faceModel(i));
      expect(row, startsWith('Working…'), reason: 'face $i: $row');
      expect(row.length, 80, reason: 'face $i pads to the terminal width');
      for (final f in kKaomojiFaces) {
        expect(
          row.contains(f.text),
          isFalse,
          reason: 'face $i renders face text "${f.text}": $row',
        );
      }
    }
  });

  test('gh-1446 AC4: the row renders single-color dim chrome', () {
    final raw = faceModel(4)
        .view()
        .content
        .split('\n')
        .firstWhere((line) => line.replaceAll(ansi, '').contains('· run'));
    final sgrs = RegExp(r'\x1b\[[0-9;]*m').allMatches(raw).toSet();
    // A single dim wrapper pair (open + reset) — no two-tone face palette
    // (teal 96;208;208 / blue 112;160;224 retired with the face render).
    expect(sgrs.map((m) => m.group(0)).toSet(), {
      '\x1b[2m',
      '\x1b[0m',
    }, reason: raw);
    expect(raw, isNot(contains('38;2;96;208;208')), reason: raw);
    expect(raw, isNot(contains('38;2;112;160;224')), reason: raw);
  });

  test('AC2: the face swaps every kKaomojiSwapTicks ticks, never in place', () {
    // Scripted picker: initial pick 3, then swaps take 5, then 1.
    final picks = [3, 5, 1];
    var m = model(
      pick: (max) {
        // Busy start picks among all 8; a swap picks among the other 7.
        expect(max, anyOf(7, 8));
        return picks.removeAt(0) % max;
      },
    );
    m = m.update(BusyMsg(true, source: 'run')).$1 as FaTuiModel;
    expect(m.kaomojiFace, 3, reason: 'busy start opens on a random face');

    for (var tick = 1; tick <= 2 * kKaomojiSwapTicks; tick++) {
      m = m.update(SpinnerTickMsg()).$1 as FaTuiModel;
      if (tick % kKaomojiSwapTicks != 0) {
        expect(
          m.kaomojiFace,
          tick <= kKaomojiSwapTicks ? 3 : 6,
          reason: 'tick $tick: no swap before the cadence boundary',
        );
      }
    }
    // tick 9: raw 5 >= 3 → 6. tick 18: raw 1 < 6 → 1.
    expect(m.kaomojiFace, 1);
  });

  test('the swap never lands back on the showing face', () {
    var m = model(pick: (_) => 0); // always raw 0
    m = m.update(BusyMsg(true, source: 'run')).$1 as FaTuiModel;
    expect(m.kaomojiFace, 0);
    for (var i = 0; i < kKaomojiSwapTicks; i++) {
      m = m.update(SpinnerTickMsg()).$1 as FaTuiModel;
    }
    expect(m.kaomojiFace, 1, reason: 'raw 0 with current 0 skips to 1');
  });

  test(
    'AC4: an idle tick animates nothing — the chain dies with the phase',
    () {
      var m = faceModel(2);
      m = m.update(BusyMsg(false, source: 'run')).$1 as FaTuiModel;
      final result = m.update(SpinnerTickMsg());
      expect(result.$2, isNull, reason: 'no tick chain while idle');
      expect(identical(result.$1, m), isTrue, reason: 'no face mutation');
      expect((result.$1 as FaTuiModel).kaomojiFace, 2);
    },
  );

  test('FA_KAOMOJI_FACE pin: deterministic frames — the face never swaps', () {
    FaTuiModel.kaomojiFacePinOverride = 3;
    addTearDown(() => FaTuiModel.kaomojiFacePinOverride = null);
    // No injected picker: the DEFAULT picker honors the pin (that is the
    // out-of-process seam the cli_visual pipeline renders fixtures with).
    var m = model();
    m = m.update(BusyMsg(true, source: 'run')).$1 as FaTuiModel;
    expect(m.kaomojiFace, 3, reason: 'busy start opens on the pinned face');
    for (var i = 0; i < 3 * kKaomojiSwapTicks; i++) {
      m = m.update(SpinnerTickMsg()).$1 as FaTuiModel;
    }
    expect(
      m.kaomojiFace,
      3,
      reason: 'the pin freezes the face across swap boundaries',
    );
    expect(
      busyRowOf(m),
      startsWith('Working…'),
      reason: 'the pinned face stays inert state — the row is faceless',
    );
  });

  test('the pin clamps out-of-range values into the face set', () {
    FaTuiModel.kaomojiFacePinOverride = 99;
    addTearDown(() => FaTuiModel.kaomojiFacePinOverride = null);
    var m = model();
    m = m.update(BusyMsg(true, source: 'run')).$1 as FaTuiModel;
    expect(m.kaomojiFace, 7);
  });

  test('herdr contract: the busy_row rule matches the LIVE row shape', () {
    // The manifest is the canonical fa-side source of herdr's upstream
    // detection rule (issue #818) — gh-1446 rekeyed it on the label +
    // elapsed cells (the face prefix retired), so the LIVE painter bytes
    // must match it (the same bytes the committed fixtures carry).
    final toml = File('docs/integrations/herdr/fa.toml').readAsStringSync();
    final busyRule = toml
        .split('[[rules]]')
        .firstWhere((b) => b.contains('id = "busy_row"'));
    final openerRe = RegExp(
      RegExp(r"line_regex = \['(.+?)', ").firstMatch(busyRule)!.group(1)!,
    );
    final closerRe = RegExp(
      RegExp(r"', '(.+?)'\]").firstMatch(busyRule)!.group(1)!,
    );
    final live = busyRowOf(faceModel(0));
    expect(openerRe.hasMatch(live), isTrue, reason: live);
    expect(closerRe.hasMatch(live), isTrue, reason: live);
    // Phase labels match too — the harness-authored capitalized-… shape.
    final phased = busyRowOf(
      faceModel(0).copyWith(busyPhase: 'Compacting context…'),
    );
    expect(openerRe.hasMatch(phased), isTrue, reason: phased);
    // A transcript QUOTE with no elapsed cell never matches both.
    expect(closerRe.hasMatch('the log said Working… and moved on'), isFalse);
  });
}
