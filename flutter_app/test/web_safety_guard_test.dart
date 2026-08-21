/// Guardrail: no web-compiled file may touch `dart:io` `Platform.*` without
/// a `kIsWeb` guard first. On the web, `Platform.isX` throws
/// `UnsupportedError` at RUNTIME (the import itself compiles), so a missing
/// guard turns into a dead tap with an "Uncaught Error" in the console —
/// see the CodeMie/ChatGPT SSO crash fixed in d946041.
///
/// Rule: a `lib/**.dart` file that references `Platform.is` outside comments
/// must also reference `kIsWeb`, UNLESS it is
///  - an `*_io.dart` conditional-import variant (never compiled for web), or
///  - selected via a conditional import (`dart.library.html`/`dart.library.io`
///    marker in its imports), or
///  - listed in [_exempt] below with a reason.
///
/// Pure Dart (dart:io directory scan, no widget pumping): runs under both
/// `dart test` and `flutter test`.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Files that legitimately touch `Platform.is` without a kIsWeb guard, and
/// why they can never run on the web.
const _exempt = <String, String>{
  // Example entry shape:
  // 'lib/services/foo.dart': 'behind the fah/foo MethodChannel stub pair —
  //   the web stub is selected by conditional import, this file never
  //   compiles for web.',
};

void main() {
  test('web safety: every Platform.is usage is kIsWeb-guarded', () {
    final violations = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('.g.dart')) continue;
      if (entity.path.endsWith('_io.dart')) continue;
      if (_exempt.containsKey(entity.path)) continue;
      final lines = entity.readAsLinesSync();
      final source = lines
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      if (!source.contains('Platform.is')) continue;
      if (source.contains('kIsWeb')) continue;
      if (source.contains('dart.library.html') ||
          source.contains('dart.library.io')) {
        continue;
      }
      violations.add(entity.path);
    }
    expect(
      violations,
      isEmpty,
      reason:
          'Files touching dart:io Platform without a kIsWeb guard '
          '(crashes at runtime on the web). Add `if (kIsWeb) …` before the '
          'Platform access, make the file an _io conditional variant, or '
          'exempt it in test/web_safety_guard_test.dart with a reason:\n'
          '${violations.join('\n')}',
    );
  });
}
