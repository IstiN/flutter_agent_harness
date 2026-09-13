// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/catalog_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

Map<String, Uint8List> _widgetFiles(String manifest) => {
  'manifest.json': _bytes(manifest),
  'widget.js': _bytes('(function(){})();'),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('JsAppInfo manifest i18n', () {
    test('scalar name/description keep working (backward compat)', () {
      final app = JsAppInfo.fromManifest(
        jsonDecode('{"id":"demo","name":"Demo","description":"A demo"}')
            as Map<String, Object?>,
        bundled: false,
        fallbackId: 'demo',
      );
      expect(app.name, 'Demo');
      expect(app.description, 'A demo');
      expect(app.displayName('ru'), 'Demo');
      expect(app.displayDescription('ru'), 'A demo');
    });

    test('additive nameI18n/descriptionI18n maps resolve per locale', () {
      final app = JsAppInfo.fromManifest(
        jsonDecode('''
        {
          "id": "demo",
          "name": "Demo",
          "description": "A demo",
          "nameI18n": {"ru": "Демо"},
          "descriptionI18n": {"en": "A demo", "ru": "Демонстрация"}
        }
        ''')
            as Map<String, Object?>,
        bundled: false,
        fallbackId: 'demo',
      );
      expect(app.displayName('ru'), 'Демо');
      expect(app.displayName('en'), 'Demo');
      expect(app.displayDescription('ru'), 'Демонстрация');
      // Unknown device locale: en entry wins over the scalar default.
      expect(app.displayDescription('ja'), 'A demo');
      // Legacy getters expose the default (unlocalized) values.
      expect(app.name, 'Demo');
      expect(app.description, 'A demo');
    });

    test('listApps loads ref file contents for display-time resolution',
        () async {
      final env = MemoryExecutionEnv();
      final store = AppsStore(env);
      await store.installWidget(
        id: 'i18napp',
        version: '1.0.0',
        files: {
          ..._widgetFiles('''
          {
            "id": "i18napp",
            "name": "Localized",
            "nameI18n": {"ru": "Локализовано"},
            "description": "English description",
            "descriptionI18n": {
              "ru": {"file": "./i18n/description.ru.md"}
            }
          }
          '''),
          'i18n/description.ru.md': _bytes('Русское описание'),
        },
      );
      final apps = await store.listApps();
      final app = apps.singleWhere((a) => a.id == 'i18napp');
      expect(app.displayName('ru'), 'Локализовано');
      expect(app.displayName('en'), 'Localized');
      expect(app.displayDescription('ru'), 'Русское описание');
      expect(app.displayDescription('en'), 'English description');
      expect(app.displayDescription('ja'), 'English description');
    });

    test('installWidget rejects a manifest whose ref file is missing',
        () async {
      final env = MemoryExecutionEnv();
      final store = AppsStore(env);
      expect(
        () => store.installWidget(
          id: 'broken',
          version: '1.0.0',
          files: _widgetFiles('''
          {
            "id": "broken",
            "name": "Broken",
            "descriptionI18n": {
              "ru": {"file": "./i18n/description.ru.md"}
            }
          }
          '''),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('i18n/description.ru.md'),
          ),
        ),
      );
      // Nothing half-installed.
      final apps = await store.listApps();
      expect(apps.where((a) => a.id == 'broken'), isEmpty);
    });

    test('installWidget accepts ref files present in the archive', () async {
      final env = MemoryExecutionEnv();
      final store = AppsStore(env);
      await store.installWidget(
        id: 'ok',
        version: '1.0.0',
        files: {
          ..._widgetFiles('''
          {
            "id": "ok",
            "name": "OK",
            "descriptionI18n": {"ru": {"file": "./i18n/ru.md"}}
          }
          '''),
          'i18n/ru.md': _bytes('текст'),
        },
      );
      final apps = await store.listApps();
      expect(
        apps.singleWhere((a) => a.id == 'ok').displayDescription('ru'),
        'текст',
      );
    });

    test('an update keeps a ref that survives only on disk', () async {
      final env = MemoryExecutionEnv();
      final store = AppsStore(env);
      final manifest = '''
      {
        "id": "upd",
        "name": "Upd",
        "descriptionI18n": {"ru": {"file": "./i18n/ru.md"}}
      }
      ''';
      await store.installWidget(
        id: 'upd',
        version: '1.0.0',
        files: {..._widgetFiles(manifest), 'i18n/ru.md': _bytes('v1')},
      );
      // Update archive without the ref file but the manifest unchanged:
      // the on-disk copy from the previous install satisfies the ref.
      await store.installWidget(
        id: 'upd',
        version: '1.0.1',
        files: _widgetFiles(manifest),
      );
      final apps = await store.listApps();
      expect(
        apps.singleWhere((a) => a.id == 'upd').displayDescription('ru'),
        'v1',
      );
    });
  });

  group('CatalogEntry i18n', () {
    test('scalar name/description keep working', () {
      final entry = CatalogEntry.fromJson(const {
        'id': 'calc',
        'name': 'Calculator',
        'description': 'A calculator',
      });
      expect(entry.displayName('ru'), 'Calculator');
      expect(entry.displayDescription('ru'), 'A calculator');
    });

    test('additive i18n maps resolve per locale', () {
      final entry = CatalogEntry.fromJson(const {
        'id': 'calc',
        'name': 'Calculator',
        'nameI18n': {'ru': 'Калькулятор'},
        'description': 'A calculator',
        'descriptionI18n': {'ru': 'Калькулятор научный'},
      });
      expect(entry.displayName('ru'), 'Калькулятор');
      expect(entry.displayDescription('ru'), 'Калькулятор научный');
      expect(entry.displayName('ja'), 'Calculator');
      expect(entry.name, 'Calculator');
      expect(entry.description, 'A calculator');
    });
  });
}
