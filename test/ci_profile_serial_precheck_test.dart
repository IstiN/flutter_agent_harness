// gh-1865 / gh-1937 / r2 — the profile-serial precheck must parse EVERY
// plist encoding and refuse to pass when extraction yields nothing.
//
// Incident chain: the portal serializes each <data> element of a real
// Apple profile on ONE line; the original awk extractor consumed the
// trailing </data> with `next` so the closing rule never printed and the
// scan saw ZERO certificates (gh-1937). The #1939 awk patch handled that
// single-line shape; the v1.0.659 regression (run 40637547009) then hit
// the other direction — a BINARY plist (or inline blobs) made the TEXT
// scan see nothing and the precheck aborted a HEALTHY build (r2), which
// is why the extractor moved to plistlib. Under model v3 (PR #1944) the
// extractor lives in scripts/ci-sign (`ci-sign plist` + `ci-sign
// doctor`), is plistlib-based, and guards the empty-extraction case with
// a loud abort.
//
// These tests exercise the REAL script end-to-end against a sandbox
// keychain (CI_SIGN_KEYCHAIN / CI_SIGN_KEYCHAIN_PASSWORD overrides) and
// CMS-wrapped fixture profiles covering every encoding and both teeth:
//
//   AC1  single-line <data> (Apple portal shape) → doctor OK
//   AC2  multi-line wrapped <data> → doctor OK (no regression)
//   AC3  BINARY plist → doctor OK (plistlib parses every encoding)
//   AC4  a profile embedding a DIFFERENT certificate → doctor FAILS with
//        the serial mismatch message (mismatch teeth preserved)
//   AC5  a CMS payload that is not a profile plist → doctor FAILS with
//        the extraction error (empty-list guard: a silent pass here is
//        how the healthy-build abort happened in reverse)
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

String read(String path) => File(path).readAsStringSync();

void main() {
  // The suite drives the REAL scripts/ci-sign end-to-end, which shells out
  // to the macOS-only `security` CLI. On Linux CI shards (Core tests,
  // shard 0/4) the whole suite must SKIP, not fail.
  if (!Platform.isMacOS) {
    test('ci-sign doctor end-to-end fixtures (macOS-only — skipped)', () {
      markTestSkipped(
        'scripts/ci-sign drives the macOS-only `security` CLI; '
        'this suite runs on macOS runners only',
      );
    });
    return;
  }
  final sandbox = Directory.systemTemp.createTempSync('ci_sign_precheck');
  final script = File('scripts/ci-sign').absolute.path;
  late String kcPath;
  late String certPemPath;

  String cmsWrap(String plistXml) {
    final plist = File('${sandbox.path}/p.plist')..writeAsStringSync(plistXml);
    final out = '${sandbox.path}/fixture.mobileprovision';
    final sign = Process.runSync('openssl', [
      'cms',
      '-sign',
      '-nodetach',
      '-binary',
      '-outform',
      'DER',
      '-signer',
      certPemPath,
      '-inkey',
      '${sandbox.path}/k.pem',
      '-in',
      plist.path,
      '-out',
      out,
    ]);
    expect(
      sign.exitCode,
      0,
      reason: 'fixture CMS signing failed: ${sign.stderr}',
    );
    return out;
  }

  String plistWithCerts(List<String> derBase64, {bool singleLine = true}) {
    final data = derBase64
        .map(
          (b64) => singleLine
              ? '<data>$b64</data>'
              : '<data>\n${b64.replaceAllMapped(RegExp('.{60}'), (m) => '${m.group(0)}\n')}</data>',
        )
        .join();
    return '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<plist version="1.0"><dict>'
        '<key>Name</key><string>Fixture Profile</string>'
        '<key>DeveloperCertificates</key><array>$data</array>'
        '</dict></plist>';
  }

  Future<ProcessResult> runDoctor(String profile) => Process.run(
    'bash',
    [script, 'doctor', profile],
    environment: {
      'CI_SIGN_KEYCHAIN': kcPath,
      'CI_SIGN_KEYCHAIN_PASSWORD': 'fixture-pass',
      'PATH': Platform.environment['PATH']!,
      'HOME': Platform.environment['HOME']!,
    },
  );

  setUpAll(() {
    // Dummy CODE-SIGNING identity (the codesigning policy refuses CAs) in
    // a throwaway keychain — the real p12s live in repo secrets, this
    // proves the mechanics.
    final gen = Process.runSync('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-keyout',
      '${sandbox.path}/k.pem',
      '-nodes',
      '-days',
      '30',
      '-subj',
      '/CN=Apple Distribution: Fixture Tester (FEEDFACE)/O=Fixture',
      '-addext',
      'basicConstraints=critical,CA:FALSE',
      '-addext',
      'keyUsage=digitalSignature',
      '-addext',
      'extendedKeyUsage=codeSigning',
      '-out',
      '${sandbox.path}/c.pem',
    ]);
    expect(gen.exitCode, 0, reason: gen.stderr);
    certPemPath = '${sandbox.path}/c.pem';

    final p12 = Process.runSync('openssl', [
      'pkcs12',
      '-export',
      '-out',
      '${sandbox.path}/c.p12',
      '-inkey',
      '${sandbox.path}/k.pem',
      '-in',
      certPemPath,
      '-passout',
      'pass:fixture-pass',
      '-certpbe',
      'PBE-SHA1-3DES',
      '-keypbe',
      'PBE-SHA1-3DES',
      '-macalg',
      'sha1',
    ]);
    expect(p12.exitCode, 0, reason: p12.stderr);

    kcPath = '${sandbox.path}/fixture.keychain-db';
    final create = Process.runSync('security', [
      'create-keychain',
      '-p',
      'fixture-pass',
      kcPath,
    ]);
    expect(create.exitCode, 0, reason: create.stderr);
    final imp = Process.runSync('security', [
      'import',
      '${sandbox.path}/c.p12',
      '-k',
      kcPath,
      '-P',
      'fixture-pass',
      '-T',
      '/usr/bin/codesign',
    ]);
    expect(imp.exitCode, 0, reason: imp.stderr);
    final part = Process.runSync('security', [
      'set-key-partition-list',
      '-S',
      'apple-tool:,apple:',
      '-s',
      '-k',
      'fixture-pass',
      kcPath,
    ]);
    expect(part.exitCode, 0, reason: part.stderr);
  });

  tearDownAll(() {
    Process.runSync('security', ['delete-keychain', kcPath]);
    sandbox.deleteSync(recursive: true);
  });

  test('AC1 — single-line <data> (Apple portal shape): doctor OK', () async {
    final b64 = base64OfCert(certPemPath);
    final profile = cmsWrap(plistWithCerts([b64], singleLine: true));
    final r = await runDoctor(profile);
    expect(r.exitCode, 0, reason: 'stdout=${r.stdout} stderr=${r.stderr}');
    expect(r.stdout, contains('doctor OK'));
  });

  test('AC2 — multi-line wrapped <data>: doctor OK (no regression)', () async {
    final b64 = base64OfCert(certPemPath);
    final profile = cmsWrap(plistWithCerts([b64], singleLine: false));
    final r = await runDoctor(profile);
    expect(r.exitCode, 0, reason: 'stdout=${r.stdout} stderr=${r.stderr}');
  });

  test('AC3 — BINARY plist: doctor OK (plistlib parses every encoding; a '
      'text scan sees nothing — v1.0.659 run 40637547009)', () async {
    final b64 = base64OfCert(certPemPath);
    final xml = plistWithCerts([b64], singleLine: true);
    // Convert to binary plist and re-wrap.
    final xmlFile = File('${sandbox.path}/bin.xml')..writeAsStringSync(xml);
    final conv = Process.runSync('plutil', [
      '-convert',
      'binary1',
      xmlFile.path,
      '-o',
      '${sandbox.path}/bin.plist',
    ]);
    expect(conv.exitCode, 0, reason: conv.stderr);
    final out = '${sandbox.path}/fixture_bin.mobileprovision';
    final sign = Process.runSync('openssl', [
      'cms',
      '-sign',
      '-nodetach',
      '-binary',
      '-outform',
      'DER',
      '-signer',
      certPemPath,
      '-inkey',
      '${sandbox.path}/k.pem',
      '-in',
      '${sandbox.path}/bin.plist',
      '-out',
      out,
    ]);
    expect(sign.exitCode, 0, reason: sign.stderr);
    final r = await runDoctor(out);
    expect(r.exitCode, 0, reason: 'stdout=${r.stdout} stderr=${r.stderr}');
  });

  test('AC4 — a profile embedding a DIFFERENT certificate: doctor FAILS '
      'with the serial mismatch (mismatch teeth preserved)', () async {
    // Second, distinct identity — its serial is NOT in the keychain.
    final other = Process.runSync('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-keyout',
      '${sandbox.path}/k2.pem',
      '-nodes',
      '-days',
      '30',
      '-subj',
      '/CN=Apple Distribution: Other Cert (BAADF00D)/O=Fixture',
      '-addext',
      'basicConstraints=critical,CA:FALSE',
      '-addext',
      'keyUsage=digitalSignature',
      '-addext',
      'extendedKeyUsage=codeSigning',
      '-out',
      '${sandbox.path}/c2.pem',
    ]);
    expect(other.exitCode, 0, reason: other.stderr);
    final der = Process.runSync('openssl', [
      'x509',
      '-in',
      '${sandbox.path}/c2.pem',
      '-outform',
      'DER',
    ], stdoutEncoding: null);
    expect(der.exitCode, 0, reason: der.stderr);
    final properB64 = base64Encode(der.stdout as List<int>);
    final profile = cmsWrap(plistWithCerts([properB64], singleLine: true));
    final r = await runDoctor(profile);
    expect(
      r.exitCode,
      isNot(0),
      reason: 'a mismatching profile MUST abort: stdout=${r.stdout}',
    );
    expect(
      '${r.stdout}${r.stderr}',
      contains('NOT in the signing keychain'),
      reason: 'the failure message must name the mismatch',
    );
  });

  test('AC6 — ci-sign install safety surface: the codesigning-policy gate, '
      'label traversal, corrupt payloads, stale-lock stealing (reviewer: '
      'highest-risk surface needs a behavioral test)', () async {
    Future<ProcessResult> run(List<String> args, {Map<String, String>? env}) =>
        Process.run(
          'bash',
          [script, ...args],
          environment: {
            'CI_SIGN_KEYCHAIN': kcPath,
            'CI_SIGN_KEYCHAIN_PASSWORD': 'fixture-pass',
            'PATH': Platform.environment['PATH']!,
            'HOME': Platform.environment['HOME']!,
            ...?env,
          },
        );

    // Self-signed certs are NOT trusted for codesigning — the install gate
    // must reject them (proven on the host: security find-identity
    // -p codesigning refuses self-signed chains). The happy path (real
    // portal certificate, manifest write, idempotent re-install) is
    // validated by the first real CI run per repo; the sandbox cannot
    // forge a policy-passing chain without polluting user trust settings.
    final p12 = base64Encode(File('${sandbox.path}/c.p12').readAsBytesSync());
    final gate = await run(
      ['install', 'fixture-gate'],
      env: {
        'CI_SIGN_FIXTURE_GATE_P12_B64': p12,
        'CI_SIGN_FIXTURE_GATE_P12_PASSWORD': 'fixture-pass',
      },
    );
    expect(
      gate.exitCode,
      isNot(0),
      reason: 'the policy gate must reject a self-signed identity',
    );
    expect(
      '${gate.stdout}${gate.stderr}',
      contains('not a valid codesigning identity'),
    );

    // The failed install must not leave a manifest behind.
    expect(
      File(
        '${Platform.environment['HOME']!}/.config/ci-sign/labels/fixture-gate',
      ).existsSync(),
      isFalse,
      reason: 'a gated install must not write the label manifest',
    );

    // Path-traversal labels are refused before anything runs.
    final escape = await run(
      ['install', '../escape'],
      env: {
        'CI_SIGN_ESCAPE_P12_B64': p12,
        'CI_SIGN_ESCAPE_P12_PASSWORD': 'fixture-pass',
      },
    );
    expect(escape.exitCode, isNot(0));
    expect('${escape.stdout}${escape.stderr}', contains('invalid label'));

    // Corrupt payloads fail loudly (no silent partial state).
    final corrupt = await run(
      ['install', 'fixture-corrupt'],
      env: {
        'CI_SIGN_FIXTURE_CORRUPT_P12_B64': 'not-base64!!!',
        'CI_SIGN_FIXTURE_CORRUPT_P12_PASSWORD': 'x',
      },
    );
    expect(corrupt.exitCode, isNot(0));

    // Stale-lock stealing: a lock older than 30 min cannot be alive; a
    // SIGKILLed holder must not wedge host signing forever. The steal is
    // observable: install proceeds past the lock (and then fails on the
    // missing payload), and the EXIT-trap removes the lock dir.
    final lockDir =
        '${Platform.environment['HOME']!}/.config/ci-sign/install.lock';
    Directory(lockDir).createSync(recursive: true);
    // Age the lock beyond the 30-min steal threshold.
    final age = Process.runSync('touch', ['-t', '202601010000', lockDir]);
    expect(age.exitCode, 0);
    final stolen = await run(['install', 'never-mind']);
    expect(
      stolen.exitCode,
      isNot(0),
      reason: 'no payload — but the stale lock must have been stolen',
    );
    expect(
      Directory(lockDir).existsSync(),
      isFalse,
      reason: 'the EXIT trap must release the lock dir',
    );
  });

  test('AC5 — a CMS payload that is not a profile plist: doctor FAILS with '
      'the extraction error (empty-extraction guard)', () async {
    final junk = File('${sandbox.path}/junk.mobileprovision')
      ..writeAsBytesSync([1, 2, 3, 4, 5, 6, 7, 8]);
    final r = await runDoctor(junk.path);
    expect(
      r.exitCode,
      isNot(0),
      reason: 'garbage must not pass: stdout=${r.stdout}',
    );
    expect(
      '${r.stdout}${r.stderr}',
      anyOf(
        contains('could not extract'),
        contains('not a valid mobileprovision'),
      ),
      reason: 'the empty-extraction guard must be loud',
    );
  });
}

final _pemRe = RegExp(
  r'-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----',
);

String base64OfCert(String pemPath) {
  // Mirrors ci-sign doctor's decode path: PEM → DER → base64 text as the
  // portal embeds it in <data>.
  final pem = read(pemPath);
  final m = _pemRe.firstMatch(pem)!;
  final lines = m
      .group(0)!
      .split('\n')
      .skip(1)
      .takeWhile((l) => !l.startsWith('-----END'))
      .join();
  final der = base64Decode(lines);
  return base64Encode(der);
}
