// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/apps/manifest_i18n.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocalizedText.parse', () {
    test('scalar string is the default-locale fallback', () {
      final text = LocalizedText.parse('Calculator');
      expect(text.fallback, 'Calculator');
      expect(text.inline, isEmpty);
      expect(text.refs, isEmpty);
      expect(text.resolve('ru'), 'Calculator');
      expect(text.resolve(null), 'Calculator');
    });

    test('null / non-string scalar yields an empty fallback', () {
      expect(LocalizedText.parse(null).resolve('en'), '');
      expect(LocalizedText.parse(42).resolve('en'), '');
    });

    test('a Map under the legacy key is NOT localization (JSR-compat)', () {
      // The inline-map-under-"name" form would change the manifest key
      // type String -> Map and crash the strict JSR runtime parser, so
      // the host-side parser must ignore it as a scalar.
      final text = LocalizedText.parse({'en': 'Calc', 'ru': 'К'});
      expect(text.fallback, '');
      expect(text.inline, isEmpty);
    });

    test('inline i18n map parses per-locale values', () {
      final text = LocalizedText.parse('Calculator', const {
        'ru': 'Калькулятор',
        'pt-BR': 'Calculadora',
      });
      expect(text.fallback, 'Calculator');
      expect(text.inline, {'ru': 'Калькулятор', 'pt-BR': 'Calculadora'});
      expect(text.refs, isEmpty);
    });

    test('ref form parses {file} entries and normalizes paths', () {
      final text = LocalizedText.parse('A calculator.', const {
        'ru': {'file': './i18n/description.ru.md'},
        'de': {'file': 'i18n/description.de.md'},
      });
      expect(text.refs, {
        'ru': 'i18n/description.ru.md',
        'de': 'i18n/description.de.md',
      });
      expect(text.refPaths, {
        'i18n/description.ru.md',
        'i18n/description.de.md',
      });
    });

    test('inline values and file refs mix freely per locale', () {
      final text = LocalizedText.parse('A calculator.', const {
        'ru': {'file': './i18n/ru.md'},
        'de': 'Ein Taschenrechner.',
      });
      expect(text.inline, {'de': 'Ein Taschenrechner.'});
      expect(text.refs, {'ru': 'i18n/ru.md'});
    });

    test('invalid locale keys are skipped', () {
      final text = LocalizedText.parse('x', const {
        'russian': 'no',
        'e': 'no',
        'en-US-x-extra-long-subtag': 'no',
        'ru': 'да',
      });
      expect(text.inline, {'ru': 'да'});
    });

    test('unsafe ref paths are skipped', () {
      final text = LocalizedText.parse('x', const {
        'ru': {'file': '../secret.txt'},
        'de': {'file': '/etc/passwd'},
        'fr': {'file': '..\\windows\\win.ini'},
        'it': {'file': './'},
        'pt': {'file': './ok.md'},
      });
      expect(text.refs, {'pt': 'ok.md'});
    });

    test('non-string / non-map locale values are skipped', () {
      final text = LocalizedText.parse('x', const {
        'ru': 42,
        'de': true,
        'fr': {'nofile': 'x'},
        'en': 'yes',
      });
      expect(text.inline, {'en': 'yes'});
      expect(text.refs, isEmpty);
    });

    test('empty inline strings are skipped', () {
      final text = LocalizedText.parse('x', const {'ru': '   '});
      expect(text.inline, isEmpty);
    });
  });

  group('LocalizedText.resolve', () {
    final text = LocalizedText.parse('Calculator', const {
      'en': 'Calculator (en)',
      'ru': 'Калькулятор',
      'pt-BR': 'Calculadora',
    });

    test('exact tag wins', () {
      expect(text.resolve('pt-BR'), 'Calculadora');
    });

    test('language subtag matches a longer declared tag', () {
      // Declared is pt-BR; device asks for plain pt -> no exact match,
      // language candidate 'pt' != 'pt-br', so falls through to en.
      expect(text.resolve('pt'), 'Calculator (en)');
    });

    test('device language matches when declared as bare language', () {
      final t = LocalizedText.parse('x', const {'ru': 'К'});
      expect(t.resolve('ru-RU'), 'К');
    });

    test('unknown locale falls back to en, then the scalar default', () {
      expect(text.resolve('ja'), 'Calculator (en)');
      final noEn = LocalizedText.parse('Default', const {'ru': 'К'});
      expect(noEn.resolve('ja'), 'Default');
    });

    test('first declared entry is the last resort before empty', () {
      final noScalar = LocalizedText.parse(null, const {'ru': 'К'});
      expect(noScalar.resolve('ja'), 'К');
    });

    test('locale matching is case-insensitive', () {
      final t = LocalizedText.parse('x', const {'RU': 'К'});
      expect(t.resolve('ru'), 'К');
    });

    test('loaded ref content resolves; missing content falls through', () {
      final t = LocalizedText.parse('Default', const {
        'ru': {'file': './i18n/ru.md'},
      });
      expect(t.resolve('ru'), 'Default');
      final loaded = t.withContents(const {'i18n/ru.md': 'Из файла'});
      expect(loaded.resolve('ru'), 'Из файла');
      expect(loaded.resolve('de'), 'Default');
    });
  });

  group('normalizeRefPath', () {
    test('strips leading ./ segments', () {
      expect(LocalizedText.normalizeRefPath('./i18n/ru.md'), 'i18n/ru.md');
      expect(LocalizedText.normalizeRefPath('././a.md'), 'a.md');
      expect(LocalizedText.normalizeRefPath('a.md'), 'a.md');
    });

    test('rejects absolute, parent-escape and backslash paths', () {
      expect(LocalizedText.normalizeRefPath('/abs.md'), isNull);
      expect(LocalizedText.normalizeRefPath('../up.md'), isNull);
      expect(LocalizedText.normalizeRefPath('a/../b.md'), isNull);
      expect(LocalizedText.normalizeRefPath('a\\b.md'), isNull);
      expect(LocalizedText.normalizeRefPath('   '), isNull);
    });
  });

  group('JSR compatibility guard', () {
    // The JSR runtime parses manifests with strict casts
    // (`raw['name'] as String?`); changing an existing key's TYPE makes
    // the whole manifest fall back to defaults (folder-name title,
    // wrench icon, network=true). i18n must therefore be purely
    // ADDITIVE: `name`/`description` stay scalar strings, localization
    // lives in the new `nameI18n`/`descriptionI18n` keys, which the
    // JSR core ignores as unknown.
    test('i18n manifests keep every legacy key type untouched', () {
      final raw = jsonDecode('''
      {
        "id": "calc",
        "name": "Calculator",
        "description": "A calculator.",
        "nameI18n": {"ru": "Калькулятор"},
        "descriptionI18n": {
          "en": {"file": "./i18n/description.en.md"},
          "ru": {"file": "./i18n/description.ru.md"}
        },
        "version": "1.2.3",
        "icon": "🧮",
        "network": false,
        "allowedCommands": ["*"]
      }
      ''') as Map<String, dynamic>;

      // The exact casts the JSR runtime performs must not throw.
      expect(raw['name'] as String?, 'Calculator');
      expect(raw['description'] as String?, 'A calculator.');
      expect(raw['version'] as String?, '1.2.3');
      expect(raw['icon'] as String?, '🧮');
      expect(raw['network'] as bool?, isFalse);
      expect(List<String>.from(raw['allowedCommands'] as List), ['*']);

      // The additive keys are maps the JSR core ignores, and the host
      // parser reads them.
      expect(raw['nameI18n'], isA<Map<String, dynamic>>());
      expect(raw['descriptionI18n'], isA<Map<String, dynamic>>());
      final name = LocalizedText.parse(raw['name'], raw['nameI18n']);
      expect(name.resolve('ru'), 'Калькулятор');
      expect(name.resolve('en'), 'Calculator');
      final description =
          LocalizedText.parse(raw['description'], raw['descriptionI18n']);
      expect(description.refPaths, {
        'i18n/description.en.md',
        'i18n/description.ru.md',
      });
    });

    test('a legacy scalar-only manifest parses identically to before', () {
      final raw = jsonDecode('{"id":"a","name":"A","description":"d"}')
          as Map<String, dynamic>;
      final name = LocalizedText.parse(raw['name'], raw['nameI18n']);
      expect(name.resolve('ru'), 'A');
      expect(name.refPaths, isEmpty);
    });
  });
}
