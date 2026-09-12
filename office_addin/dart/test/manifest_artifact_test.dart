// Committed-artifact tests (issue #89): the validator must accept the
// REAL prod manifest, and the taskpane/support pages must carry the
// markers the manifest and boot flow promise.
//
// `dart test` runs suites with the package root as cwd (verified), so
// office_addin/ artifacts sit one level up from office_addin/dart/.
import 'dart:io';

import 'package:test/test.dart';

import 'package:fa_office_agent/src/manifest.dart';

String _artifact(String pathInOfficeAddin) =>
    File('../$pathInOfficeAddin').readAsStringSync();

void main() {
  test('validator accepts the committed prod manifest', () {
    final report = validateOutlookManifest(_artifact('manifest/outlook.xml'));
    expect(report.issues, isEmpty);
  });

  test('committed manifest carries the Monarch command surfaces (#143)', () {
    final xml = _artifact('manifest/outlook.xml');
    expect(xml, contains('VersionOverridesV1_0'));
    expect(xml, contains('MessageReadCommandSurface'));
    // Compose parity: the classic ItemEdit form has an override twin.
    expect(xml, contains('MessageComposeCommandSurface'));
    expect(xml, contains('xsi:type="ShowTaskpane"'));
  });

  test('every icon the manifest references is committed', () {
    final xml = _artifact('manifest/outlook.xml');
    final icons = RegExp(r'icons/(fa-\d+\.png)')
        .allMatches(xml)
        .map((m) => m.group(1)!)
        .toSet();
    expect(icons, containsAll(['fa-16.png', 'fa-32.png', 'fa-80.png']));
    for (final icon in icons) {
      expect(File('../icons/$icon').existsSync(), isTrue, reason: icon);
    }
  });

  test(
    'taskpane page is the app redirect shim — no bootstrap agent surface',
    () {
      // Issue #182: the manifest points at app/index.html (the Flutter
      // app); the committed web/index.html is ONLY a redirect for cached
      // pre-1.2 manifests. The #94 bootstrap surface (office_agent.js,
      // the fake provider's chat, the EVENTS dump) must be gone, not
      // hidden (AC1).
      final html = _artifact('web/index.html');
      expect(html, contains('app/index.html'));
      expect(html, isNot(contains('office_agent.js')));
      expect(html, isNot(contains('fa-events')));
      expect(html, isNot(contains('fa-transcript')));
      final manifest = _artifact('manifest/outlook.xml');
      expect(manifest, contains('https://fa1.dev/outlook/app/index.html'));
      expect(manifest, contains('<Version>1.2.0.0</Version>'));
    },
  );

  test('privacy and support pages exist, are non-trivial and mention fa', () {
    for (final page in ['web/privacy.html', 'web/support.html']) {
      final html = _artifact(page);
      expect(html.length, greaterThan(200), reason: page);
      expect(html.toLowerCase(), contains('fa'), reason: page);
    }
  });
}
