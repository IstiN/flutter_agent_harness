// gh-1937 — the daily macOS legs failed (run 40637547009, 2026-10-28):
// `gh-1865 fail-fast: the macOS provisioning profile (Fa - MacOS) does not
// contain the imported signing certificate (profile cert serials: — ...)`
// on a VALID profile (the same step had just printed `Profile: Fa - MacOS /
// UUID: a32a… / team: YP9HC3USZ3` from the same decoded plist).
//
// Root cause: the profile-serial extractor awk was written for a multi-line
// `<data>` block. Apple's developer portal serializes each profile
// certificate as ONE line — `<data>BASE64…</data>`. On that line the opening
// rule matched, stripped only through `<data>` (leaving the trailing
// `</data>` in the buffer), hit `next`, and the closing-tag rule never fired
// — every cert blob was silently dropped, `PROFILE_SERIALS` came back EMPTY,
// and `grep -qxF "$CERT_SERIAL"` failed on every real profile. The identical
// awk lives in build-mobile.yml's `profile_contains_identity()` — the iOS leg
// would fail the same way.
//
// Behavioral guard (TDD RED before the fix): the EXACT awk program is
// extracted from both workflow files and driven through the workflows' real
// downstream pipeline (`awk | while base64 --decode | openssl x509 -serial`)
// against fixture plists in BOTH serializations:
//
//   AC1  Apple single-line `<data>BASE64</data>` (the gh-1937 shape, 2+
//        certs in the array) — every cert's serial must come out, in order.
//   AC2  multi-line wrapped `<data>` — must keep working (no regression).
//   AC3  the mismatch case keeps its teeth: a profile whose certs do NOT
//        embed the imported serial yields a serial list without it (the
//        precheck's whole purpose — loud abort, never silent pass).
@TestOn('posix')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Both workflows carry the gh-1865 fail-fast precheck (AC5 of
/// ci_cert_sha1_pin_guard_test.dart); each embeds the extractor awk inline.
final _workflowSurfaces = <String>[
  '.github/workflows/build-macos.yml',
  '.github/workflows/build-mobile.yml',
];

/// Pulls the single-quoted awk program that follows the
/// `DeveloperCertificates` anchor out of a workflow file. The program
/// contains no single quotes (only double), so the first `'` closes it.
String extractAwkProgram(String workflowPath) {
  final content = File(workflowPath).readAsStringSync();
  // The workflow's awk regex escapes the slash (`DeveloperCertificates<\/key>`).
  final anchor = content.indexOf('DeveloperCertificates');
  expect(
    anchor,
    greaterThan(-1),
    reason: '$workflowPath must carry the gh-1865 profile-serial precheck.',
  );
  final awkMarker = content.lastIndexOf("awk '", anchor);
  expect(
    awkMarker,
    greaterThan(-1),
    reason:
        '$workflowPath must extract profile cert serials with awk (the '
        'anchor sits inside the awk program, so the marker precedes it).',
  );
  final programStart = awkMarker + "awk '".length;
  final programEnd = content.indexOf("'", programStart);
  expect(
    programEnd,
    greaterThan(programStart),
    reason:
        'the awk program must be a single-quoted string with no inner '
        "single quotes (the extractor relies on that to find its end).",
  );
  return content.substring(programStart, programEnd);
}

/// A fixture plist in the Apple portal shape: every `<data>` element on ONE
/// line (the serialization the old awk dropped on the floor).
String oneLinePlist(List<String> base64Certs) {
  final data = base64Certs.map((b64) => '\t<data>$b64</data>').join('\n');
  return '<plist version="1.0">\n<dict>\n'
      '\t<key>DeveloperCertificates</key>\n\t<array>\n$data\n\t</array>\n'
      '</dict>\n</plist>\n';
}

/// A fixture plist in the wrapped shape the old awk was written for: the
/// base64 folded across lines between the tags.
String wrappedPlist(List<String> base64Certs) {
  String fold64(String s) {
    final lines = <String>[];
    for (var i = 0; i < s.length; i += 64) {
      lines.add(s.substring(i, i + 64 > s.length ? s.length : i + 64));
    }
    return lines.join('\n');
  }

  final data = base64Certs
      .map((b64) => '\t<data>\n${fold64(b64)}\n\t</data>')
      .join('\n');
  return '<plist version="1.0">\n<dict>\n'
      '\t<key>DeveloperCertificates</key>\n\t<array>\n$data\n\t</array>\n'
      '</dict>\n</plist>\n';
}

/// Stable `serial=…` output across locales, inheriting the real PATH/HOME.
Map<String, String> _env() => <String, String>{
  ...Platform.environment,
  'LC_ALL': 'C',
};

/// Generates a throwaway self-signed cert, returns (pemPath, serial).
(String, String) _generateCert(Directory dir, String cn) {
  final pem = '${dir.path}/$cn.pem';
  Process.runSync('openssl', [
    'req',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-keyout',
    '${dir.path}/$cn.key',
    '-out',
    pem,
    '-days',
    '1',
    '-nodes',
    '-subj',
    '/CN=$cn',
  ], environment: _env());
  expect(
    File(pem).existsSync(),
    isTrue,
    reason: 'openssl req must produce the fixture certificate.',
  );
  final serial =
      Process.runSync('openssl', [
            'x509',
            '-in',
            pem,
            '-noout',
            '-serial',
          ], environment: _env()).stdout
          as String;
  final value = serial.trim().replaceFirst(RegExp('^serial='), '');
  expect(value, isNotEmpty, reason: 'openssl must print the fixture serial.');
  return (pem, value);
}

String _derBase64(String pemPath) {
  final der = pemPath.replaceAll('.pem', '.der');
  Process.runSync('openssl', [
    'x509',
    '-in',
    pemPath,
    '-outform',
    'DER',
    '-out',
    der,
  ], environment: _env());
  final result = Process.runSync('base64', [
    '-w',
    '0',
    der,
  ], environment: _env());
  return (result.stdout as String).trim();
}

/// Runs the workflow's real downstream pipeline (the `| while IFS= read -r
/// der; do … done` arm, verbatim) with the extracted awk fed the profile on
/// stdin — exactly what `security cms -D -i profile | awk '<program>'` plus
/// the while loop does on the runner, minus the macOS-only `security`
/// invocation.
String runPipeline(String awkProgram, String plist) {
  final dir = Directory.systemTemp.createTempSync('profile-precheck-');
  try {
    final awkFile = File('${dir.path}/extract.awk')
      ..writeAsStringSync(awkProgram);
    final plistFile = File('${dir.path}/profile.plist')
      ..writeAsStringSync(plist);
    // The pipeline arm, verbatim from both workflows; the plist rides stdin
    // like `security cms -D`'s output does.
    final script = File('${dir.path}/pipeline.sh')
      ..writeAsStringSync('''
#!/bin/bash
set -uo pipefail
awk -f "\$1" < "\$2" | while IFS= read -r der; do
  printf '%s' "\$der" | base64 --decode 2>/dev/null \\
    | openssl x509 -inform DER -noout -serial 2>/dev/null \\
    | sed 's/^serial=//' || true
done
''');
    final result = Process.runSync(
      'bash',
      [script.path, awkFile.path, plistFile.path],
      environment: _env(),
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    return result.stdout as String;
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void main() {
  late Directory certDir;
  late String certPemA;
  late String serialA;
  late String certPemB;
  late String serialB;
  late String b64A;
  late String b64B;

  setUpAll(() {
    certDir = Directory.systemTemp.createTempSync('profile-precheck-certs-');
    (certPemA, serialA) = _generateCert(certDir, 'FixtureA');
    (certPemB, serialB) = _generateCert(certDir, 'FixtureB');
    b64A = _derBase64(certPemA);
    b64B = _derBase64(certPemB);
    expect(
      serialA,
      isNot(serialB),
      reason: 'the two fixture certs must differ (mismatch case).',
    );
  });

  tearDownAll(() => certDir.deleteSync(recursive: true));

  for (final workflow in _workflowSurfaces) {
    group(workflow, () {
      test('AC1 — Apple single-line <data> elements: the extractor yields '
          'every profile cert serial in order (gh-1937 reproduction)', () {
        final serials = runPipeline(
          extractAwkProgram(workflow),
          oneLinePlist([b64A, b64B]),
        );
        expect(
          serials.trim().split('\n'),
          [serialA, serialB],
          reason:
              'Apple provisioning profiles embed each DeveloperCertificates '
              'entry as ONE line: <data>BASE64</data>. The extractor must '
              'handle that shape — an empty/partial result makes the gh-1865 '
              'precheck abort every VALID profile (gh-1937, run 40637547009: '
              '"profile cert serials: —" while the profile itself decoded '
              'fine). Got: "$serials".',
        );
      });

      test('AC2 — multi-line wrapped <data> keeps working (no regression)', () {
        final serials = runPipeline(
          extractAwkProgram(workflow),
          wrappedPlist([b64A]),
        );
        expect(
          serials.trim().split('\n'),
          [serialA],
          reason:
              'the single-line fix must not break the wrapped serialization '
              'the extractor was originally written for. Got: "$serials".',
        );
      });

      test('AC3 — a profile without the imported cert still fails the '
          'precheck (mismatch teeth preserved)', () {
        // The precheck's whole point: a genuinely stale profile (certB
        // imported, profile embeds only certA) must produce a serial list
        // that does NOT contain the imported serial.
        final serials = runPipeline(
          extractAwkProgram(workflow),
          oneLinePlist([b64A]),
        );
        expect(
          serials.trim(),
          serialA,
          reason:
              'the extractor must still emit serials (an EMPTY list '
              'cannot prove a mismatch — it aborts valid profiles too, '
              'which is the gh-1937 bug).',
        );
        expect(
          serials.trim().split('\n'),
          isNot(contains(serialB)),
          reason:
              'a profile embedding a different cert must NOT yield the '
              'imported serial — grep -qxF then aborts the build BEFORE the '
              '~24-minute archive, the gh-1865 failure class this precheck '
              'exists for.',
        );
      });
    });
  }
}
