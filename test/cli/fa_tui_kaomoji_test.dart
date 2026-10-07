// The busy row's kaomoji thinking indicator (issue #1374): the eight
// two-tone faces, the fixed face zone, the ~0.9 s random-swap cadence,
// the brand palette, the ASCII fallback below the fixed-layout width,
// and the shipped herdr busy_row contract that keys on the face glyphs.
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

  String coloredBusyRowOf(FaTuiModel m, {String marker = '· run'}) => m
      .view()
      .content
      .split('\n')
      .firstWhere((line) => line.replaceAll(ansi, '').contains(marker));

  test(
    'AC2: the busy row renders the face two-tone — eyes teal, mouth blue',
    () {
      // `o_<`: eye o, mouth _, eye <.
      final row = coloredBusyRowOf(faceModel(4));
      expect(
        row,
        contains('\x1b[38;2;96;208;208mo\x1b[0m'),
        reason: 'eye teal',
      );
      expect(
        row,
        contains('\x1b[38;2;112;160;224m_\x1b[0m'),
        reason: 'mouth blue',
      );
      expect(
        row,
        contains('\x1b[38;2;96;208;208m<\x1b[0m'),
        reason: 'eye teal',
      );
      // The stripped row keeps the plain face text in the face zone.
      expect(busyRowOf(faceModel(4)), startsWith('o_< '));
    },
  );

  test('the face zone is fixed: every face keeps the label at column 5', () {
    for (var i = 0; i < kKaomojiFaces.length; i++) {
      final row = busyRowOf(faceModel(i));
      expect(
        row.indexOf('Working…'),
        5,
        reason: 'face $i (${row.substring(0, 5)}) must not move the label',
      );
      expect(row.length, 80, reason: 'face $i pads to the terminal width');
    }
    // Widest face needs no zone pad; 3-cell faces pad with one space.
    expect(busyRowOf(faceModel(7)), startsWith('o_o? W'));
    expect(busyRowOf(faceModel(2)), startsWith('o_o  W'));
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
    'narrow terminal: below kKaomojiAsciiMinWidth the ASCII set renders',
    () {
      // Face 6 `¬_¬` falls back to `-_/` (mouth = the tilted stroke).
      final narrow = faceModel(6, width: kKaomojiAsciiMinWidth - 1);
      final row = busyRowOf(narrow, marker: 'Working…');
      expect(row, contains('-_/'), reason: row);
      expect(row, isNot(contains('¬')), reason: row);
      expect(
        coloredBusyRowOf(narrow, marker: 'Working…'),
        contains('\x1b[38;2;112;160;224m/'),
        reason: 'the fallback mouth stays blue',
      );
      // At the boundary the unicode face renders again.
      expect(
        busyRowOf(
          faceModel(6, width: kKaomojiAsciiMinWidth),
          marker: 'Working…',
        ),
        contains('¬_¬'),
      );
      // Face 5 `◕‿◕` falls back to `^.^`.
      expect(
        busyRowOf(
          faceModel(5, width: kKaomojiAsciiMinWidth - 1),
          marker: 'Working…',
        ),
        contains('^.^'),
      );
    },
  );

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
    expect(busyRowOf(m), startsWith('>_< '), reason: 'face 3 renders >_<');
  });

  test('the pin clamps out-of-range values into the face set', () {
    FaTuiModel.kaomojiFacePinOverride = 99;
    addTearDown(() => FaTuiModel.kaomojiFacePinOverride = null);
    var m = model();
    m = m.update(BusyMsg(true, source: 'run')).$1 as FaTuiModel;
    expect(m.kaomojiFace, 7);
    expect(
      coloredBusyRowOf(m),
      contains('\x1b[38;2;112;160;224m?'),
      reason: 'face 7 = o_o? — the curious mouth stays blue',
    );
  });

  test('herdr contract: every face matches the shipped busy_row regex', () {
    // The manifest is the canonical fa-side source of herdr's upstream
    // detection rule (issue #818) — the busy_row rule keys on the face
    // glyphs, so a face-set change must ship with it.
    final toml = File('docs/integrations/herdr/fa.toml').readAsStringSync();
    final busyRule = toml
        .split('[[rules]]')
        .firstWhere((b) => b.contains('id = "busy_row"'));
    final facePattern = RegExp(
      r"line_regex = \['(.+?)', ",
    ).firstMatch(busyRule)!.group(1)!;
    final faceRe = RegExp(facePattern);

    const faces = [
      '>_o', '-_-', 'o_o', '>_<', 'o_<', '◕‿◕', '¬_¬', 'o_o?',
      // ASCII fallbacks.
      '^.^', '-_/',
    ];
    for (final face in faces) {
      expect(
        faceRe.hasMatch('$face  Working…                12s · run'),
        isTrue,
        reason: 'face "$face" must match the manifest busy_row rule',
      );
    }
    // The retired braille spinner must NOT match — old screens are not
    // live fa panes.
    expect(faceRe.hasMatch('⠋ Working…      3s'), isFalse);
  });
}
