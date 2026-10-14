// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/app_storage.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// gh-1614 UT: the shared app-storage resolver. One helper resolves every
/// `apps/<id>/…` path for listing AND reading — the table pins the exact
/// shapes (VM and web compile the same pure Dart, so the resolution is
/// host-independent by construction; the parity requirement is that no
/// branch anywhere consults the host platform).
void main() {
  group('AppStorage id validation (gh-1614 AC4)', () {
    const valid = [
      '2048',
      'ab',
      'my-app',
      'a0',
      '0-0',
      'english-teacher',
      'axxxxxxxxxxxxxxxxxxxxxxxxxxxxxxb', // 32 chars — the upper bound
    ];
    for (final id in valid) {
      test('accepts "$id"', () => expect(AppStorage.isValidId(id), isTrue));
    }
    const invalid = [
      '', // empty
      '..', // traversal
      '../x', // traversal
      'a/../b', // embedded traversal
      'a/..', // trailing traversal
      '/absolute', // absolute
      'apps/../evil', // namespace escape through the root
      'a_b', // underscore
      'My-App', // uppercase
      'приложение', // unicode
      'a b', // space
      'a.b', // dot
      '.hidden', // dot-file
      '-abc', // leading dash
      'a/b', // separator
      'a\\b', // windows separator
      'axxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxb', // 33 chars — over the bound
    ];
    for (final id in invalid) {
      test('rejects "$id"', () => expect(AppStorage.isValidId(id), isFalse));
    }
  });

  group('AppStorage path resolution (gh-1614 I1)', () {
    test('appDir resolves under the single namespace root', () {
      expect(AppStorage.appDir('2048'), 'apps/2048');
      expect(AppStorage.tryAppDir('2048'), 'apps/2048');
    });

    test('manifest and entry paths derive from the same root', () {
      expect(AppStorage.manifestPath('2048'), 'apps/2048/manifest.json');
      expect(AppStorage.entryPath('2048'), 'apps/2048/widget.js');
      expect(
        AppStorage.entryPath('2048', 'widget_tile.js'),
        'apps/2048/widget_tile.js',
      );
    });

    test('appFile allows subdirectory file names inside the app dir', () {
      expect(AppStorage.appFile('2048', 'game/main.js'), 'apps/2048/game/main.js');
      expect(AppStorage.appFile('2048', 'icon.svg'), 'apps/2048/icon.svg');
    });

    test('appDir throws naming the id and the rule for a traversal id', () {
      expect(
        () => AppStorage.appDir('../evil'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('../evil'),
          ),
        ),
      );
      expect(() => AppStorage.appDir('/abs'), throwsA(isA<ArgumentError>()));
      // The message names the namespace root, so the failure is honest
      // about what it protects (gh-1614 I3).
      expect(
        () => AppStorage.appDir('..'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('apps/'),
          ),
        ),
      );
    });

    test('tryAppDir answers null (never throws) for a hostile id', () {
      expect(AppStorage.tryAppDir('../evil'), isNull);
      expect(AppStorage.tryAppDir(''), isNull);
      expect(AppStorage.tryAppDir('/etc'), isNull);
    });

    test('appFile rejects file names that leave the app dir', () {
      for (final hostile in [
        '../stolen.json',
        '/etc/passwd',
        '..',
        '.',
        'a/../..',
        'a\\b',
        '',
        'game/../../x.js',
      ]) {
        expect(
          () => AppStorage.appFile('2048', hostile),
          throwsA(isA<ArgumentError>()),
          reason: 'appFile(2048, "$hostile") must be rejected',
        );
      }
    });

    test('resolution is a pure host-independent table (VM/web parity)', () {
      // The same inputs resolve to the same outputs regardless of any
      // platform channel — pin the table so no host branch can sneak in.
      const ids = ['2048', 'english-teacher', 'xy'];
      for (final id in ids) {
        expect(AppStorage.appDir(id), 'apps/$id');
        expect(AppStorage.manifestPath(id), 'apps/$id/manifest.json');
        expect(AppStorage.entryPath(id), 'apps/$id/widget.js');
      }
    });
  });

  group('single-namespace wiring (gh-1614 REG-1: root resolution)', () {
    test('JsAppInfo resolves dir/manifest/entry through AppStorage', () {
      final app = JsAppInfo.fromManifest(
        const {'id': '2048', 'name': '2048'},
        bundled: false,
        fallbackId: '2048',
      );
      expect(app.dir, AppStorage.appDir('2048'));
      expect(app.manifestPath, AppStorage.manifestPath('2048'));
      expect(app.widgetPath, AppStorage.entryPath('2048'));
    });

    test('a hostile manifest id cannot steer reads out of the app dir', () {
      // The storage dir name is the namespace identity: a manifest declaring
      // a divergent or hostile id must not move the tile to another root
      // (the gh-1614 listed-but-unreadable shape).
      final app = JsAppInfo.fromManifest(
        const {'id': '../evil', 'name': 'Evil'},
        bundled: false,
        fallbackId: '2048',
      );
      expect(app.id, '2048');
      expect(app.dir, 'apps/2048');
    });

    test('a divergent manifest id falls back to the storage dir name', () {
      final app = JsAppInfo.fromManifest(
        const {'id': 'other-name', 'name': 'Other'},
        bundled: false,
        fallbackId: '2048',
      );
      expect(app.id, '2048');
      expect(app.widgetPath, 'apps/2048/widget.js');
    });
  });
}
