// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:typed_data';

import 'package:fa/services/theme_packs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for the pack validator (issue #169): schema strictness,
/// the security screen (traversal/URL/size/extension), and the WCAG
/// contrast warnings. The zip-level screening has its own tests in
/// `theme_pack_store_test.dart`.
void main() {
  Uint8List png(int size) => Uint8List.fromList(List.filled(size, 0x89));

  group('schema', () {
    test('a minimal valid pack parses into a spec with slug id', () {
      final result = validateThemePack({
        'name': 'Forest Walk',
        'version': '1.2.0',
        'colors': {
          'dark': {'accent': '#2E7D32'},
        },
      }, const {});
      final spec = result.spec;
      expect(spec, isNotNull);
      expect(spec!.id, 'forest-walk');
      expect(spec.name, 'Forest Walk');
      expect(spec.version, '1.2.0');
      expect(spec.dark!.accent, const Color(0xFF2E7D32));
      expect(spec.light, isNull);
      expect(spec.wallpaper, isNull);
      expect(result.reasons, isEmpty);
      expect(result.warnings, isEmpty);
    });

    test('#RRGGBBAA keeps its alpha byte — no silent data loss', () {
      final result = validateThemePack({
        'name': 'Glass',
        'version': '1.0.0',
        'colors': {
          'dark': {'accent': '#2E7D3280'},
        },
      }, const {});
      final spec = result.spec;
      expect(spec, isNotNull, reason: result.reasons.join('\n'));
      expect(spec!.dark!.accent, const Color(0x802E7D32));
    });

    test('unknown top-level key rejects the pack', () {
      final result = validateThemePack({
        'name': 'X',
        'version': '1.0.0',
        'scripts': 'nope',
      }, const {});
      expect(result.spec, isNull);
      expect(result.reasons.single, contains('unknown theme.json keys'));
      expect(result.reasons.single, contains('scripts'));
    });

    test('non-semver version rejects; #RRGGBBAA parses', () {
      final bad = validateThemePack({
        'name': 'X',
        'version': '1.0',
        'colors': {
          'dark': {'accent': '#2E7D32FF'},
        },
      }, const {});
      expect(bad.spec, isNull);
      expect(bad.reasons.single, contains('major.minor.patch'));
    });

    test('unknown color slot and malformed hex reject with the slot named', () {
      final result = validateThemePack({
        'name': 'X',
        'version': '1.0.0',
        'colors': {
          'dark': {'accent': 'green', 'sparkle': '#FFFFFF'},
        },
      }, const {});
      expect(result.spec, isNull);
      expect(
        result.reasons.join('\n'),
        allOf(
          contains('unknown colors.dark keys: sparkle'),
          contains('accent'),
        ),
      );
    });
  });

  group('security', () {
    Map<String, Object?> packWithWallpaper(String asset) => {
      'name': 'X',
      'version': '1.0.0',
      'wallpaper': {'asset': asset},
    };

    test('path traversal in the asset name rejects', () {
      final result = validateThemePack(packWithWallpaper('../evil.png'), {
        '../evil.png': png(10),
      });
      expect(result.spec, isNull);
      expect(result.reasons.join('\n'), contains('no paths, no URLs'));
    });

    test('remote URL as the asset name rejects', () {
      final result = validateThemePack(
        packWithWallpaper('https://evil.example/x.png'),
        const {},
      );
      expect(result.spec, isNull);
      expect(result.reasons.join('\n'), contains('no paths, no URLs'));
    });

    test('a non-image asset (code) rejects at the name screen', () {
      final result = validateThemePack(packWithWallpaper('run.js'), {
        'run.js': Uint8List.fromList([1, 2, 3]),
      });
      expect(result.spec, isNull);
      // The name screen runs first (only png/jpg/jpeg/webp names are even
      // admissible), so executable payloads never reach extension checks.
      expect(result.reasons.join('\n'), contains('bundled file name'));
    });

    test('an asset above the 8 MB cap rejects', () {
      final result = validateThemePack(packWithWallpaper('big.png'), {
        'big.png': png(maxWallpaperBytes + 1),
      });
      expect(result.spec, isNull);
      expect(result.reasons.join('\n'), contains('(max 8 MB)'));
    });

    test('an undeclared extra file rejects the whole pack', () {
      final result = validateThemePack(
        {
          'name': 'X',
          'version': '1.0.0',
          'colors': {
            'dark': {'accent': '#2E7D32'},
          },
        },
        {
          'payload.js': Uint8List.fromList([1]), // a stray sibling must reject
        },
      );
      expect(result.spec, isNull);
      expect(result.reasons.join('\n'), contains('unexpected file in pack'));
    });

    test('the declared asset missing from the pack rejects', () {
      final result = validateThemePack(packWithWallpaper('gone.png'), const {});
      expect(result.spec, isNull);
      expect(result.reasons.join('\n'), contains('missing from the pack'));
    });
  });

  group('accessibility', () {
    test('a text/background pair below 4.5:1 warns but installs', () {
      final result = validateThemePack({
        'name': 'Low Contrast',
        'version': '1.0.0',
        'colors': {
          'dark': {'background': '#777777', 'text': '#888888'},
        },
      }, const {});
      expect(result.spec, isNotNull);
      expect(result.warnings, isNotEmpty);
      expect(result.warnings.first, contains('text on background'));
      expect(result.warnings.first, contains('WCAG AA'));
    });

    test('a readable palette produces no warnings', () {
      final result = validateThemePack({
        'name': 'Readable',
        'version': '1.0.0',
        'colors': {
          'dark': {'background': '#111111', 'text': '#F5F5F5'},
        },
      }, const {});
      expect(result.spec, isNotNull);
      expect(result.warnings, isEmpty);
    });
  });
  group('themePackIdFor', () {
    test('slugs names and collapses non-ASCII', () {
      expect(themePackIdFor('Forest Walk 2!'), 'forest-walk-2');
      expect(themePackIdFor('Тёмная'), isNotEmpty); // non-ASCII → 'theme'
      expect(themePackIdFor('???'), 'theme');
    });
  });

  /// One firing fixture per rule in [themePackRules] (issue #484 AC3):
  /// every rule must reject a crafted bad pack with its own reason, and
  /// the tripwire above fails when a rule is added without a fixture.
  group('rules', () {
    test('tripwire: every rule has a firing fixture in this group', () {
      expect(themePackRules.length, 12);
    });

    test('name rule: blank and oversized names reject', () {
      for (final name in ['', ' ', 'x' * 65]) {
        final result = validateThemePack({
          'name': name,
          'version': '1.0.0',
        }, const {});
        expect(result.spec, isNull);
        expect(
          result.reasons.single,
          'name must be a non-empty string (≤ 64 chars)',
        );
      }
      final ok = validateThemePack({
        'name': 'x' * 64,
        'version': '1.0.0',
      }, const {});
      expect(ok.spec, isNotNull, reason: ok.reasons.join('\n'));
    });

    test(
      'colors shape rule: non-object, empty, and unknown variants reject',
      () {
        Map<String, Object?> pack(Object? colors) => {
          'name': 'X',
          'version': '1.0.0',
          'colors': colors,
        };
        for (final colors in ['dark', <String, Object?>{}]) {
          final result = validateThemePack(pack(colors), const {});
          expect(result.spec, isNull);
          expect(
            result.reasons.single,
            'colors must be an object with dark and/or light variants',
          );
        }
        final unknown = validateThemePack(
          pack({'purple': <String, Object?>{}}),
          const {},
        );
        expect(unknown.reasons.single, 'unknown color variants: purple');
      },
    );

    test('colors variants rule: null variants report the missing pair', () {
      final result = validateThemePack(const {
        'name': 'X',
        'version': '1.0.0',
        'colors': {'dark': null, 'light': null},
      }, const {});
      expect(
        result.reasons.single,
        'colors needs at least one of dark or light',
      );
    });

    test('variant parse: a non-object variant and an empty variant reject', () {
      Map<String, Object?> pack(Object? dark) => {
        'name': 'X',
        'version': '1.0.0',
        'colors': {'dark': dark},
      };
      final notObject = validateThemePack(pack('nope'), const {});
      expect(notObject.reasons.single, 'colors.dark must be an object');
      final empty = validateThemePack(pack(const {'accent': null}), const {});
      expect(empty.reasons.single, 'colors.dark sets no colors');
    });

    test('typography rule: shape, unknown keys, and bad families reject', () {
      Map<String, Object?> pack(Object? typography) => {
        'name': 'X',
        'version': '1.0.0',
        'typography': typography,
      };
      final notObject = validateThemePack(pack(4), const {});
      expect(notObject.reasons.single, 'typography must be an object');
      final unknownKey = validateThemePack(
        pack(const {'fontFamily': 'JetBrains Mono', 'weight': 700}),
        const {},
      );
      expect(unknownKey.reasons.single, 'unknown typography keys: weight');
      final badFamily = validateThemePack(
        pack(const {'fontFamily': 'Zapf Dingbats!'}),
        const {},
      );
      expect(
        badFamily.reasons.single,
        'typography.fontFamily must be a plain font name',
      );
      final ok = validateThemePack(
        pack(const {'fontFamily': 'JetBrains Mono'}),
        const {},
      );
      expect(ok.spec!.fontFamily, 'JetBrains Mono');
      expect(ok.reasons, isEmpty);
    });

    test('wallpaper shape rule: non-object and unknown keys reject', () {
      Map<String, Object?> pack(Object? wallpaper) => {
        'name': 'X',
        'version': '1.0.0',
        'wallpaper': wallpaper,
      };
      final notObject = validateThemePack(pack(true), const {});
      expect(notObject.reasons.single, 'wallpaper must be an object');
      final unknownKey = validateThemePack(
        pack(const {'asset': 'bg.png', 'parallax': 1}),
        {'bg.png': png(10)},
      );
      expect(unknownKey.reasons.single, 'unknown wallpaper keys: parallax');
    });

    test('wallpaper fit and opacity rules reject out-of-range values', () {
      Map<String, Object?> pack(Map<String, Object?> wallpaper) => {
        'name': 'X',
        'version': '1.0.0',
        'wallpaper': wallpaper,
      };
      final badFit = validateThemePack(
        pack(const {'asset': 'bg.png', 'fit': 'diagonal'}),
        {'bg.png': png(10)},
      );
      expect(
        badFit.reasons.single,
        'wallpaper.fit must be one of: '
        'cover, contain, fill, fitWidth, fitHeight, none, scaleDown',
      );
      for (final opacity in [Object(), 1.5, 'high']) {
        final badOpacity = validateThemePack(
          pack({'asset': 'bg.png', 'opacity': opacity}),
          {'bg.png': png(10)},
        );
        expect(
          badOpacity.reasons.single,
          'wallpaper.opacity must be a number between 0 and 1',
        );
      }
    });

    test('wallpaper build rule: declared fit and opacity land in the spec', () {
      Map<String, Object?> packWithWallpaper(String asset) => {
        'name': 'X',
        'version': '1.0.0',
        'wallpaper': {'asset': asset},
      };
      final result = validateThemePack(
        const {
          'name': 'X',
          'version': '1.0.0',
          'wallpaper': {'asset': 'bg.png', 'fit': 'contain', 'opacity': 0.5},
        },
        {'bg.png': png(10)},
      );
      expect(result.spec!.wallpaper!.fit, BoxFit.contain);
      expect(result.spec!.wallpaper!.opacity, 0.5);
      final defaults = validateThemePack(packWithWallpaper('bg.png'), {
        'bg.png': png(10),
      });
      expect(defaults.spec!.wallpaper!.fit, BoxFit.cover);
      expect(defaults.spec!.wallpaper!.opacity, 1);
    });
  });
}
