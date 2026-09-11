// Committed-artifact tests (issue #89): the validator must accept the
// REAL prod manifest, and the taskpane/support pages must carry the
// markers the manifest and boot flow promise.
//
// `dart test` runs suites with the package root as cwd (verified), so
// office_addin/ artifacts sit one level up from office_addin/dart/.
import 'dart:io';

import 'package:test/test.dart';

import '../src/manifest.dart';

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
    'index.html wires the Office.js CDN, the agent bundle and the boot banner',
    () {
      final html = _artifact('web/index.html');
      expect(
        html,
        contains('https://appsforoffice.microsoft.com/lib/1/hosted/office.js'),
      );
      expect(html, contains('office_agent.js'));
      expect(html, contains('fa-office-unavailable'));
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
