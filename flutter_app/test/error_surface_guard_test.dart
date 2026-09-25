// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Issue #869 REG guard: the shared error-surface module
/// (`packages/fa_ui/lib/src/widgets/snackbars.dart`) is the ONLY place in
/// either host that may build a SnackBar, and the chat error bubble must
/// carry the copy affordance — so a new error surface without one-tap copy
/// fails this gate instead of shipping screenshot-bait.
void main() {
  // `flutter test` runs with CWD = flutter_app; `dart test` may differ —
  // anchor every path on the discovered repo root.
  final repo = () {
    var dir = Directory.current;
    while (dir.path != dir.parent.path) {
      if (File('${dir.path}/packages/fa_ui/pubspec.yaml').existsSync()) {
        return dir.path;
      }
      dir = dir.parent;
    }
    throw StateError('repo root with packages/fa_ui not found');
  }();
  final owner = '$repo/packages/fa_ui/lib/src/widgets/snackbars.dart';

  Iterable<String> dartFiles(String dir) => Directory(dir)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .map((f) => f.path.replaceAll('\\', '/'));

  group('error surface guard (issue #869 AC4)', () {
    test('SnackBar construction only happens in the shared module', () {
      final offenders = <String>[];
      for (final path in dartFiles('$repo/flutter_app/lib')) {
        final source = File(path).readAsStringSync();
        if (source.contains('SnackBar(') || source.contains('showSnackBar(')) {
          offenders.add(path);
        }
      }
      final faUiLib = '$repo/packages/fa_ui/lib';
      for (final path in dartFiles(faUiLib)) {
        if (path.endsWith(owner)) continue;
        final source = File(path).readAsStringSync();
        if (source.contains('SnackBar(') || source.contains('showSnackBar(')) {
          offenders.add(
            'packages/fa_ui/lib/${path.substring(faUiLib.length + 1)}',
          );
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'Every SnackBar must be built by the shared module ($owner): '
            'use showFahErrorSnack (errors — carries the copy affordance) or '
            'showFahSnack (informational). Found raw construction in:\n'
            '${offenders.join('\n')}',
      );
    });

    test('the shared error snack always carries the copy affordance', () {
      final source = File(owner).readAsStringSync();
      expect(
        source,
        contains('FahErrorCopyButton('),
        reason: 'the affordance widget itself lives in the shared module',
      );
      // The error helper routes its content through the affordance: the
      // copy button must sit inside showFahErrorSnack's own SnackBar.
      final helper = source.indexOf('void showFahErrorSnack(');
      expect(helper, greaterThanOrEqualTo(0));
      final nextHelper = source.indexOf('void showFahSnack(', helper);
      final helperBody = source.substring(
        helper,
        nextHelper == -1 ? source.length : nextHelper,
      );
      expect(helperBody, contains('SnackBar('));
      expect(
        helperBody,
        contains('FahErrorCopyButton('),
        reason:
            'showFahErrorSnack must build the copy affordance into '
            'every error snack',
      );
    });

    test('the chat error bubbles reference the copy affordance', () {
      final banner = File(
        '$repo/packages/fa_ui/lib/src/chat/fa_chat_screen.dart',
      ).readAsStringSync();
      expect(
        banner,
        contains('FahErrorCopyButton('),
        reason:
            'the chat provider-error banner (and the auth-expired '
            'variant) must expose one-tap copy',
      );
    });
  });
}
