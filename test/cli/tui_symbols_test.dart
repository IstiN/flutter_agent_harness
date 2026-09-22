// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Unit tests for the TUI symbol presets (issue #804): the three omp-keyed
/// glyph tables stay key-compatible, the ascii preset never emits a
/// non-ASCII (let alone nerd/PUA) glyph, and the controller seam switches
/// presets.
library;

import 'package:dart_tui/src/msg.dart' show ColorProfile;
import 'package:flutter_agent_harness/src/cli/tui_theme.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    FaThemeController.instance
      ..reset()
      ..profile = ColorProfile.trueColor;
  });

  group('symbol presets (issue #804)', () {
    test('the catalog carries the three omp preset names', () {
      expect(kTuiSymbolPresets.keys, unorderedEquals(['unicode', 'nerd', 'ascii']));
      expect(kTuiSymbolsUnicode.name, 'unicode');
      expect(kTuiSymbolsNerd.name, 'nerd');
      expect(kTuiSymbolsAscii.name, 'ascii');
    });

    test('all presets expose the identical omp key set', () {
      final keys = kTuiSymbolsUnicode.glyphs.keys.toSet();
      expect(keys, isNotEmpty);
      expect(kTuiSymbolsNerd.glyphs.keys.toSet(), keys,
          reason: 'a preset missing a key would silently render empty');
      expect(kTuiSymbolsAscii.glyphs.keys.toSet(), keys);
    });

    test('the ascii preset never emits a non-ASCII code point', () {
      for (final entry in kTuiSymbolsAscii.glyphs.entries) {
        for (final rune in entry.value.runes) {
          expect(
            rune,
            lessThan(0x80),
            reason: 'ascii preset ${entry.key} carries U+${rune.toRadixString(16)}',
          );
        }
      }
      for (final frame in [
        ...kTuiSymbolsAscii.statusSpinner,
        ...kTuiSymbolsAscii.activitySpinner,
      ]) {
        for (final rune in frame.runes) {
          expect(rune, lessThan(0x80), reason: 'ascii spinner frame "$frame"');
        }
      }
    });

    test('the unicode and nerd presets carry the omp glyph families', () {
      // Powerline caps are PUA in unicode/nerd and plain ASCII in ascii.
      int maxRune(Iterable<String> values) => values
          .expand((value) => value.runes)
          .reduce((a, b) => a > b ? a : b);
      expect(maxRune(kTuiSymbolsUnicode.glyphs.values), greaterThan(0x2500));
      expect(maxRune(kTuiSymbolsNerd.glyphs.values), greaterThan(0xe000),
          reason: 'the nerd preset exists to carry PUA glyphs');
      // Spinner rings: braille activity loader shared by unicode/nerd.
      expect(kTuiSymbolsUnicode.activitySpinner, isNotEmpty);
      expect(kTuiSymbolsUnicode.statusSpinner.length, greaterThan(1));
      expect(
        kTuiSymbolsNerd.statusSpinner,
        isNot(equals(kTuiSymbolsUnicode.statusSpinner)),
        reason: 'omp swaps the nerd status ring to a PUA clock set',
      );
    });

    test('glyph() resolves known keys and asserts unknown ones', () {
      expect(
        kTuiSymbolsAscii.glyph('status.success'),
        kTuiSymbolsAscii.glyphs['status.success'],
      );
      expect(
        () => kTuiSymbolsUnicode.glyph('definitely.not.a.key'),
        throwsA(anything),
        reason: 'a typoed key must fail loudly in debug, not render empty',
      );
    });

    test('the controller seam switches presets and serves glyphs', () {
      final controller = FaThemeController.instance;
      expect(controller.sym('sep.dot'), kTuiSymbolsUnicode.glyphs['sep.dot']);
      expect(controller.switchSymbols('nerd'), isTrue);
      expect(controller.sym('sep.dot'), kTuiSymbolsNerd.glyphs['sep.dot']);
      expect(controller.symbols.name, 'nerd');
      expect(controller.switchSymbols('ascii'), isTrue);
      expect(controller.sym('sep.dot'), kTuiSymbolsAscii.glyphs['sep.dot']);
      expect(controller.switchSymbols('emoji'), isFalse,
          reason: 'unknown presets are rejected, session preset unchanged');
      expect(controller.symbols.name, 'ascii');
    });
  });
}
