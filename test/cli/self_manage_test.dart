// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import '../../bin/self_manage.dart';

/// Provenance fixtures for the fake release `v9.9.9`: a throwaway RSA key
/// (generated once with host openssl for this suite), a tar.gz holding
/// `bundle/bin/fa` = `new-binary`, a zip holding
/// `Fa.app/Contents/MacOS/Fa` = `new-zip-binary`, and a SHA256SUMS listing
/// every prebuilt asset name, signed with the key (RSA PKCS#1 v1.5
/// SHA-256). Static data — nothing is signed at test time.

/// The test signing key's public half: the `pem:` injection target.
const _testPem = '-----BEGIN PUBLIC KEY-----\n'
    'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA0oDyFPqAfPdV6/EXT7Sa\n'
    '/lkqlJUA1chgVeOv3HAPMfOZR5203eS8ObjYEI38WtJHTV8hGYqCHBzv7iJHz1+b\n'
    'dYf4ky1wpsza5zIsIERmPvGTkJhCeqYfOY7NauOQ9S+6oJDsUn2U4c2/3w6nv7jl\n'
    'vgsKjoeXSvVOJSHtZ2YtLFVWxq9fIBi+Amc3+XDHEaN3UrfbSeh6/ZdRA1Pn2uYJ\n'
    '5lnnOsJCfmsY3MqdDc0EArFdYmaisPeQdtRQcqtF4yuCfKVNajBBnPF92SXnuUqp\n'
    'BqUtNuMpPeYoD9Fre/GqwOHIpAIDx04eAV/stIXIp0+2gNpdjn7qOJboKiW6bO7w\n'
    'mQIDAQAB\n'
    '-----END PUBLIC KEY-----';

const _tarGzDigest =
    'c79e4ee9e0c680a983b24c91d6fc7bff74a1b1f1e439d5a85a80caff6e64e917';
const _zipDigest =
    '1b83aa76a0ce4017f7be6c7cc7bfec2b5f3db1ebb629ff435fc83d75176819eb';

/// The signed SHA256SUMS of release `v9.9.9` (every prebuilt asset name,
/// byte-identical to what [_fixtureSig] signs).
final _fixtureSums =
    [
      'fa-test.tar.gz',
      'fa-macos-arm64.tar.gz',
      'fa-macos-x64.tar.gz',
      'fa-linux-x64.tar.gz',
      'fa-linux-arm64.tar.gz',
      'fa-windows-x64.zip',
    ].map((name) => '$_tarGzDigest  $name\n').join() +
    [
      'fa-macos-arm64-mac.zip',
      'fa-macos-x64-mac.zip',
    ].map((name) => '$_zipDigest  $name\n').join();

const _fixtureTarGzBase64 =
    'H4sIAKpExmoAA+2SzQpCIRBGfRRfIBp1Rp9HSSMIF/eH6O2TlEsFXWjhjWjO5tsM+jnHMOfD'
    'Oe5FTwDAEcl72pqgsWZDKtJWIYImJ0FpZ5WQ1LVVYx4nP5Qq/hjzNL6fK2MprZzT3rHkjxCq'
    '/3DK/f7A5/4NGfa/CQ/+k+90R9mHRVzxr/SLfwRjhIROfZ74c/85XnZFvh+u327CMAzDbMkN'
    'YLreMwAMAAA=';

const _fixtureZipBase64 =
    'UEsDBAoAAAAAAKJ+R10AAAAAAAAAAAAAAAAHABwARmEuYXBwL1VUCQADr0DGaq9Axmp1eAsA'
    'AQT1AQAABBQAAABQSwMECgAAAAAAon5HXQAAAAAAAAAAAAAAABAAHABGYS5hcHAvQ29udGVu'
    'dHMvVVQJAAOvQMZqr0DGanV4CwABBPUBAAAEFAAAAFBLAwQKAAAAAACifkddAAAAAAAAAAAA'
    'AAAAFgAcAEZhLmFwcC9Db250ZW50cy9NYWNPUy9VVAkAA69AxmqvQMZqdXgLAAEE9QEAAAQU'
    'AAAAUEsDBAoAAAAAAKJ+R11Mw0j8DgAAAA4AAAAYABwARmEuYXBwL0NvbnRlbnRzL01hY09T'
    'L0ZhVVQJAAOvQMZqr0DGanV4CwABBPUBAAAEFAAAAG5ldy16aXAtYmluYXJ5UEsBAh4DCgAA'
    'AAAAon5HXQAAAAAAAAAAAAAAAAcAGAAAAAAAAAAQAO1BAAAAAEZhLmFwcC9VVAUAA69Axmp1'
    'eAsAAQT1AQAABBQAAABQSwECHgMKAAAAAACifkddAAAAAAAAAAAAAAAAEAAYAAAAAAAAABAA'
    '7UFBAAAARmEuYXBwL0NvbnRlbnRzL1VUBQADr0DGanV4CwABBPUBAAAEFAAAAFBLAQIeAwoA'
    'AAAAAKJ+R10AAAAAAAAAAAAAAAAWABgAAAAAAAAAEADtQYsAAABGYS5hcHAvQ29udGVudHMv'
    'TWFjT1MvVVQFAAOvQMZqdXgLAAEE9QEAAAQUAAAAUEsBAh4DCgAAAAAAon5HXUzDSPwOAAAA'
    'DgAAABgAGAAAAAAAAQAAAKSB2wAAAEZhLmFwcC9Db250ZW50cy9NYWNPUy9GYVVUBQADr0DG'
    'anV4CwABBPUBAAAEFAAAAFBLBQYAAAAABAAEAF0BAAA7AQAAAAA=';

const _fixtureSigBase64 =
    'jooUSlgTVIqhxlBPo3O1acm60IG6IO/V9Q5lqSyB+I88BxcHdzzW3G8zTJDarE6eqhgNLkWT'
    'xxcfuDDpU3fhcC/NXkTtqdbPWT37N/9xejlHXC0Up8uN7buq5oRf014wyiwlfi6Hhx5hm38G'
    'erEoL43BG4FnbK1ss4h8ZRiLSg0fRe55B/EL3/A3LfqqhHsHbSkPgqap12NhztOX1031Qv4z'
    'gA7ouX5LKqD7kLZPa9rEBdQhSOtWKXlQCX1k6kRDRkupcpVsVuY7E1Mg9dx11Jny+wUzy8/H'
    'fif35jUV+DegD50JoXXR1e55DA55mrU8KfWcSJB3OR4AJFRKxcpsmg==';

List<int> get _fixtureTarGz => base64Decode(_fixtureTarGzBase64);
List<int> get _fixtureZip => base64Decode(_fixtureZipBase64);
List<int> get _fixtureSig => base64Decode(_fixtureSigBase64);

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fa_self_manage_test');
  });

  tearDown(() async {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  File fakeExe(List<int> magic) {
    final dir = Directory('${temp.path}/.pub-cache/bin')
      ..createSync(recursive: true);
    return File('${dir.path}/fa')..writeAsBytesSync(magic);
  }

  /// A client serving the fake release v9.9.9: permalink redirect,
  /// signed provenance fixtures, and the archive ([archiveBytes]).
  http.Client releaseClient({List<int>? archiveBytes}) =>
      MockClient((request) async {
        if (request.url.path.endsWith('/releases/latest')) {
          return http.Response(
            '',
            302,
            headers: {
              'location':
                  'https://github.com/IstiN/flutter_agent_harness/'
                  'releases/tag/v9.9.9',
            },
          );
        }
        if (request.url.path.endsWith('SHA256SUMS.sig')) {
          return http.Response.bytes(_fixtureSig, 200);
        }
        if (request.url.path.endsWith('SHA256SUMS')) {
          return http.Response(_fixtureSums, 200);
        }
        return http.Response.bytes(archiveBytes ?? _fixtureTarGz, 200);
      });

  /// A runProcess seam that actually extracts tar.gz archives instead of
  /// invoking the system `tar`.
  Future<ProcessResult> extractingRunProcess(
    String exe,
    List<String> args,
  ) async {
    if (exe == 'tar') {
      final destDir = args.last;
      final archiveFile = args[args.indexOf('-xzf') + 1];
      final data = File(archiveFile).readAsBytesSync();
      final decoded = TarDecoder().decodeBytes(
        GZipDecoder().decodeBytes(data),
      );
      for (final entry in decoded) {
        if (entry.isFile) {
          final parts = entry.name.split('/');
          final dest = File('$destDir/${parts.join('/')}');
          dest.parent.createSync(recursive: true);
          dest.writeAsBytesSync(entry.content as List<int>);
        }
      }
    }
    return ProcessResult(0, 0, '', '');
  }


  group('classifyInstall', () {
    test('a .dart script is a dev run', () {
      final install = classifyInstall(
        scriptPath: '/repo/bin/fah.dart',
        executablePath: '/usr/bin/dart',
      );
      expect(install.kind, InstallKind.devRun);
    });

    test('a pub-cache snapshot is a pub-global install', () {
      // Kernel snapshots are not native executables (no Mach-O/ELF/PE magic).
      final exe = fakeExe(const [0x90, 0xAB, 0xCD, 0xEF]);
      final install = classifyInstall(
        scriptPath: exe.path,
        executablePath: exe.path,
      );
      expect(install.kind, InstallKind.pubGlobal);
      expect(install.executable, exe.path);
    });

    test('a native Mach-O binary under pub-cache is a BINARY install', () {
      final exe = fakeExe(const [0xCF, 0xFA, 0xED, 0xFE]);
      final install = classifyInstall(
        scriptPath: exe.path,
        executablePath: exe.path,
      );
      // The pub activate path cannot rebuild over a native binary — the
      // release-download swap must be used instead.
      expect(install.kind, InstallKind.binary);
      expect(install.executable, exe.path);
    });

    test('a native ELF binary under pub-cache is a BINARY install', () {
      final exe = fakeExe(const [0x7F, 0x45, 0x4C, 0x46]);
      final install = classifyInstall(
        scriptPath: exe.path,
        executablePath: exe.path,
      );
      expect(install.kind, InstallKind.binary);
    });

    test('a native PE binary under pub-cache is a BINARY install', () {
      final exe = fakeExe(const [0x4D, 0x5A, 0x90, 0x00]);
      final install = classifyInstall(
        scriptPath: exe.path,
        executablePath: exe.path,
      );
      expect(install.kind, InstallKind.binary);
    });

    test('a file shorter than 4 bytes does not throw', () {
      // Regression: the magic-byte matcher must not read past EOF.
      final stub = fakeExe(const [0x0A]);
      final install = classifyInstall(
        scriptPath: stub.path,
        executablePath: stub.path,
      );
      expect(install.kind, InstallKind.pubGlobal);
    });

    test('a 2-byte MZ stub is still a PE binary', () {
      final exe = fakeExe(const [0x4D, 0x5A]);
      final install = classifyInstall(
        scriptPath: exe.path,
        executablePath: exe.path,
      );
      expect(install.kind, InstallKind.binary);
    });
  });

  group('isYesAnswer', () {
    test('y and yes are affirmative in any casing', () {
      expect(isYesAnswer('y'), isTrue);
      expect(isYesAnswer('yes'), isTrue);
      expect(isYesAnswer('Y'), isTrue);
      expect(isYesAnswer('Yes'), isTrue);
      expect(isYesAnswer(' YES '), isTrue);
    });

    test('anything else — including null and empty — is a NO', () {
      expect(isYesAnswer(null), isFalse);
      expect(isYesAnswer(''), isFalse);
      expect(isYesAnswer('n'), isFalse);
      expect(isYesAnswer('no'), isFalse);
      expect(isYesAnswer('yeah'), isFalse);
    });
  });

  group('runSelfUpdate', () {
    /// A client whose permalink request 302s to the given tag's release page.
    http.Client redirectToTag(String tag) => MockClient((request) async {
      if (request.url.host == 'github.com' &&
          request.url.path.endsWith('/releases/latest')) {
        return http.Response(
          '',
          302,
          headers: {
            'location':
                'https://github.com/IstiN/flutter_agent_harness/'
                'releases/tag/$tag',
          },
        );
      }
      return http.Response('not found', 404);
    });

    Install binaryInstall(String path) => Install(InstallKind.binary, path);

    test('a dev run is refused', () async {
      final code = await runSelfUpdate(
        currentVersion: '0.1.0',
        detectInstall: () => const Install(InstallKind.devRun, 'bin/fah.dart'),
      );
      expect(code, 1);
    });

    test('already up to date returns 0 without downloading', () async {
      final client = redirectToTag('v0.1.0');
      final code = await runSelfUpdate(
        currentVersion: '0.1.0',
        detectInstall: () => binaryInstall('${temp.path}/fa'),
        newClient: () => client,
      );
      expect(code, 0);
    });

    test('unreachable GitHub (API fallback fails) returns 1', () async {
      final client = MockClient((request) async {
        if (request.url.host == 'github.com') {
          return http.Response('', 200); // no location header
        }
        return http.Response('rate limited', 403);
      });
      final code = await runSelfUpdate(
        currentVersion: '0.1.0',
        detectInstall: () => binaryInstall('${temp.path}/fa'),
        newClient: () => client,
      );
      expect(code, 1);
    });

    test('binary update downloads and swaps the executable', () async {
      final target = File('${temp.path}/fa')..writeAsStringSync('old');
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/releases/latest')) {
          return http.Response(
            '',
            302,
            headers: {
              'location':
                  'https://github.com/IstiN/flutter_agent_harness/'
                  'releases/tag/v9.9.9',
            },
          );
        }
        if (request.url.path.endsWith('SHA256SUMS.sig')) {
          return http.Response.bytes(_fixtureSig, 200);
        }
        if (request.url.path.endsWith('SHA256SUMS')) {
          return http.Response(_fixtureSums, 200);
        }
        return http.Response.bytes(_fixtureTarGz, 200);
      });
      final processes = <List<String>>[];
      final code = await runSelfUpdate(
        currentVersion: '0.1.0',
        detectInstall: () => binaryInstall(target.path),
        newClient: () => client,
        pem: _testPem,
        runProcess: (exe, args) async {
          processes.add([exe, ...args]);
          if (exe == 'tar') {
            // Actually extract into the CWD passed as last arg.
            final destDir = args.last;
            final archiveFile = args[args.indexOf('-xzf') + 1];
            final data = File(archiveFile).readAsBytesSync();
            final decoded = TarDecoder().decodeBytes(
              GZipDecoder().decodeBytes(data),
            );
            for (final entry in decoded) {
              if (entry.isFile) {
                final parts = entry.name.split('/');
                final dest = File('$destDir/${parts.join('/')}');
                dest.parent.createSync(recursive: true);
                dest.writeAsBytesSync(entry.content as List<int>);
              }
            }
          }
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(code, 0);
      expect(target.readAsStringSync(), 'new-binary');
      expect(File('${target.path}.new').existsSync(), isFalse);
      if (!Platform.isWindows) {
        expect(processes, [
          ['tar', '-xzf', anything, '-C', anything],
          ['chmod', '+x', target.path],
        ]);
      }
    });

    test('a failed download returns 1 and keeps the old binary', () async {
      final target = File('${temp.path}/fa')..writeAsStringSync('old');
      final client = MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          return http.Response('{"tag_name": "v9.9.9"}', 200);
        }
        if (request.url.path.endsWith('/releases/latest')) {
          // No location header: exercise the JSON API fallback.
          return http.Response('', 200);
        }
        return http.Response('gone', 404);
      });
      final code = await runSelfUpdate(
        currentVersion: '0.1.0',
        detectInstall: () => binaryInstall(target.path),
        newClient: () => client,
      );
      expect(code, 1);
      expect(target.readAsStringSync(), 'old');
    });

    test(
      'pub-global update reactivates, rebuilding a stale snapshot',
      () async {
        final processes = <List<String>>[];
        final code = await runSelfUpdate(
          currentVersion: '0.1.0',
          detectInstall: () =>
              const Install(InstallKind.pubGlobal, '/home/.pub-cache/bin/fa'),
          newClient: () => redirectToTag('v9.9.9'),
          runProcess: (exe, args) async {
            processes.add(args);
            final listOut = args.contains('list')
                ? 'flutter_agent_harness 0.2.0'
                : '';
            return ProcessResult(0, 0, listOut, '');
          },
        );
        expect(code, 0);
        // The 0.2.0 spec is newer than the running 0.1.0: deactivate first.
        expect(processes[0], ['pub', 'global', 'list']);
        expect(processes[1], [
          'pub',
          'global',
          'deactivate',
          'flutter_agent_harness',
        ]);
        expect(processes[2], [
          'pub',
          'global',
          'activate',
          'flutter_agent_harness',
        ]);
      },
    );

    test(
      'pub-global update without a stale snapshot skips deactivate',
      () async {
        final processes = <List<String>>[];
        final code = await runSelfUpdate(
          currentVersion: '0.1.0',
          detectInstall: () =>
              const Install(InstallKind.pubGlobal, '/home/.pub-cache/bin/fa'),
          newClient: () => redirectToTag('v9.9.9'),
          runProcess: (exe, args) async {
            processes.add(args);
            final listOut = args.contains('list')
                ? 'flutter_agent_harness 0.1.0'
                : '';
            return ProcessResult(0, 0, listOut, '');
          },
        );
        expect(code, 0);
        expect(processes.length, 2);
        expect(processes[1], [
          'pub',
          'global',
          'activate',
          'flutter_agent_harness',
        ]);
      },
    );
  });

  group('runSelfUninstall', () {
    test('a dev run is refused', () async {
      final code = await runSelfUninstall(
        detectInstall: () => const Install(InstallKind.devRun, 'bin/fah.dart'),
      );
      expect(code, 1);
    });

    test('declining the confirmation aborts', () async {
      final code = await runSelfUninstall(
        detectInstall: () => Install(InstallKind.binary, '${temp.path}/fa'),
        confirm: (question) async => false,
      );
      expect(code, 1);
    });

    test('pub-global uninstall deactivates via pub', () async {
      final processes = <List<String>>[];
      final code = await runSelfUninstall(
        detectInstall: () =>
            const Install(InstallKind.pubGlobal, '/home/.pub-cache/bin/fa'),
        confirm: (question) async => true,
        runProcess: (exe, args) async {
          processes.add(args);
          return ProcessResult(0, 0, '', '');
        },
        environment: const {},
      );
      expect(code, 0);
      expect(processes, [
        ['pub', 'global', 'deactivate', 'flutter_agent_harness'],
      ]);
    });

    test(
      'binary uninstall removes the executable and a confirmed data dir',
      () async {
        final exe = File('${temp.path}/fa')..writeAsStringSync('bin');
        final home = Directory('${temp.path}/home')..createSync();
        final dataDir = Directory('${home.path}/.fah')..createSync();
        File('${dataDir.path}/config.yaml').writeAsStringSync('x');
        final code = await runSelfUninstall(
          detectInstall: () => Install(InstallKind.binary, exe.path),
          confirm: (question) async => true,
          environment: {'HOME': home.path},
        );
        expect(code, 0);
        expect(exe.existsSync(), isFalse);
        expect(dataDir.existsSync(), isFalse);
      },
    );

    test('binary uninstall keeps the data dir when declined', () async {
      final exe = File('${temp.path}/fa')..writeAsStringSync('bin');
      final home = Directory('${temp.path}/home')..createSync();
      final dataDir = Directory('${home.path}/.fah')..createSync();
      var asks = 0;
      final code = await runSelfUninstall(
        detectInstall: () => Install(InstallKind.binary, exe.path),
        confirm: (question) async => asks++ == 0,
        environment: {'HOME': home.path},
      );
      expect(code, 0);
      expect(exe.existsSync(), isFalse);
      expect(dataDir.existsSync(), isTrue);
    });

    test('no data dir means no second confirmation', () async {
      final exe = File('${temp.path}/fa')..writeAsStringSync('bin');
      final home = Directory('${temp.path}/home')..createSync();
      var asks = 0;
      final code = await runSelfUninstall(
        detectInstall: () => Install(InstallKind.binary, exe.path),
        confirm: (question) async {
          asks++;
          return true;
        },
        environment: {'HOME': home.path},
      );
      expect(code, 0);
      expect(asks, 1);
    });
  });

  group('extractArchive', () {
    test('extracts a zip with nested directories', () async {
      final tmp = await Directory.systemTemp.createTemp('fa_extract_zip');
      try {
        final archive = Archive()
          ..addFile(ArchiveFile.bytes('bundle/bin/fa', utf8.encode('exe')))
          ..addFile(
            ArchiveFile.bytes('bundle/lib/libfa.dylib', utf8.encode('lib')),
          );
        final zipBytes = ZipEncoder().encode(archive);

        final error = await extractArchive(
          zipBytes,
          'fa-test.zip',
          tmp,
          (_, _) async => ProcessResult(0, 0, '', ''),
        );
        expect(error, isNull);
        expect(File('${tmp.path}/bundle/bin/fa').readAsStringSync(), 'exe');
        expect(
          File('${tmp.path}/bundle/lib/libfa.dylib').readAsStringSync(),
          'lib',
        );
      } finally {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      }
    });

    test('skips directory entries in a zip', () async {
      final tmp = await Directory.systemTemp.createTemp('fa_extract_zip_dir');
      try {
        // Archive with only directory entries (isFile = false).
        final archive = Archive()..addFile(ArchiveFile('dir/', 0, []));
        final zipBytes = ZipEncoder().encode(archive);

        final error = await extractArchive(
          zipBytes,
          'test.zip',
          tmp,
          (_, _) async => ProcessResult(0, 0, '', ''),
        );
        expect(error, isNull);
      } finally {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      }
    });

    test('returns error for unknown archive format', () async {
      final tmp = await Directory.systemTemp.createTemp('fa_extract_unknown');
      try {
        final error = await extractArchive(
          [0, 1, 2],
          'archive.rar',
          tmp,
          (_, _) async => ProcessResult(0, 0, '', ''),
        );
        expect(error, 'unknown archive format: archive.rar');
      } finally {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      }
    });
  });

  group('fallbackZipUpdate', () {
    test('extracts and swaps the macOS binary from a zip asset', () async {
      final target = File('${temp.path}/fa')..writeAsStringSync('old');
      final client = MockClient((request) async {
        if (request.url.path.endsWith('SHA256SUMS.sig')) {
          return http.Response.bytes(_fixtureSig, 200);
        }
        if (request.url.path.endsWith('SHA256SUMS')) {
          return http.Response(_fixtureSums, 200);
        }
        if (request.url.path.endsWith('fa-macos-arm64-mac.zip')) {
          return http.Response.bytes(_fixtureZip, 200);
        }
        return http.Response('not found', 404);
      });
      final processes = <List<String>>[];
      final code = await fallbackZipUpdate(
        client,
        'v9.9.9',
        'fa-macos-arm64-mac.zip',
        target.path,
        '9.9.9',
        (exe, args) async {
          processes.add([exe, ...args]);
          return ProcessResult(0, 0, '', '');
        },
        pem: _testPem,
      );
      expect(code, 0);
      expect(target.readAsStringSync(), 'new-zip-binary');
      if (!Platform.isWindows) {
        expect(processes, [
          ['chmod', '+x', target.path],
        ]);
      }
    });

    test('reports a missing binary inside the zip', () async {
      final target = File('${temp.path}/fa')..writeAsStringSync('old');
      final archive = Archive()
        ..addFile(ArchiveFile('wrong/path', 3, 'abc'.codeUnits));
      final zipBytes = ZipEncoder().encode(archive);
      final client = MockClient((request) async {
        return http.Response.bytes(zipBytes, 200);
      });
      final code = await fallbackZipUpdate(
        client,
        'v9.9.9',
        'fa-macos-arm64-mac.zip',
        target.path,
        '9.9.9',
        (exe, args) async => ProcessResult(0, 0, '', ''),
      );
      expect(code, 1);
      expect(target.readAsStringSync(), 'old');
    });

    test('reports a failed zip download', () async {
      final target = File('${temp.path}/fa')..writeAsStringSync('old');
      final client = MockClient((request) async {
        return http.Response('gone', 404);
      });
      final code = await fallbackZipUpdate(
        client,
        'v9.9.9',
        'fa-macos-arm64-mac.zip',
        target.path,
        '9.9.9',
        (exe, args) async => ProcessResult(0, 0, '', ''),
      );
      expect(code, 1);
      expect(target.readAsStringSync(), 'old');
    });
  });

  group('compareVersions', () {
    test('newer, older, and equal triples', () {
      expect(compareVersions('0.1.10', '0.1.9'), greaterThan(0));
      expect(compareVersions('0.1.9', '0.1.10'), lessThan(0));
      expect(compareVersions('0.2.0', '0.2.0'), 0);
      expect(compareVersions('v0.1.44', '0.1.44'), 0);
      expect(compareVersions('0.2', '0.1.9'), greaterThan(0));
      expect(compareVersions('0.1.10', '0.1.10.0'), 0);
    });
  });

  group('archiveNameFor', () {
    test('covers the five release platforms', () {
      expect(archiveNameFor('macos_arm64'), 'fa-macos-arm64.tar.gz');
      expect(archiveNameFor('macos_x64'), 'fa-macos-x64.tar.gz');
      expect(archiveNameFor('linux_x64'), 'fa-linux-x64.tar.gz');
      expect(archiveNameFor('linux_arm64'), 'fa-linux-arm64.tar.gz');
      expect(archiveNameFor('windows_x64'), 'fa-windows-x64.zip');
      expect(archiveNameFor('ios_arm64'), isNull);
    });
  });

  group('rsaPublicKeyFromPem', () {
    test('parses the pinned release key into a 4096-bit modulus', () {
      final key = rsaPublicKeyFromPem(kFaReleaseSigningPem);
      expect(key.n, hasLength(512));
      expect(key.e, [0x01, 0x00, 0x01]); // 65537
    });

    test('parses the test fixture key into a 2048-bit modulus', () {
      final key = rsaPublicKeyFromPem(_testPem);
      expect(key.n, hasLength(256));
      expect(key.e, [0x01, 0x00, 0x01]); // 65537
    });
  });

  group('verifyReleaseProvenance', () {
    http.Client signedReleaseClient() => MockClient((request) async {
      if (request.url.path.endsWith('SHA256SUMS.sig')) {
        return http.Response.bytes(_fixtureSig, 200);
      }
      if (request.url.path.endsWith('SHA256SUMS')) {
        return http.Response(_fixtureSums, 200);
      }
      return http.Response('unexpected: ${request.url}', 404);
    });

    test('a signed manifest with a matching archive verifies', () async {
      expect(
        await verifyReleaseProvenance(
          client: signedReleaseClient(),
          tag: 'v9.9.9',
          archiveName: 'fa-test.tar.gz',
          archiveBytes: _fixtureTarGz,
          pem: _testPem,
        ),
        isTrue,
      );
    });

    test('a tampered archive fails the digest comparison', () async {
      final tampered = List<int>.of(_fixtureTarGz)..[10] ^= 0x5A;
      expect(
        await verifyReleaseProvenance(
          client: signedReleaseClient(),
          tag: 'v9.9.9',
          archiveName: 'fa-test.tar.gz',
          archiveBytes: tampered,
          pem: _testPem,
        ),
        isFalse,
      );
    });

    test('a missing SHA256SUMS asset fails closed', () async {
      final client = MockClient((request) async {
        return http.Response('gone', 404);
      });
      expect(
        await verifyReleaseProvenance(
          client: client,
          tag: 'v9.9.9',
          archiveName: 'fa-test.tar.gz',
          archiveBytes: _fixtureTarGz,
          pem: _testPem,
        ),
        isFalse,
      );
    });

    test('an archive absent from the manifest fails closed', () async {
      expect(
        await verifyReleaseProvenance(
          client: signedReleaseClient(),
          tag: 'v9.9.9',
          archiveName: 'fa-unlisted.tar.gz',
          archiveBytes: _fixtureTarGz,
          pem: _testPem,
        ),
        isFalse,
      );
    });

    test('a signature from the wrong key fails closed', () async {
      // _testPem signs _fixtureSums, but the client serves the PINNED key:
      // verification against it must fail even though the digest matches.
      expect(
        await verifyReleaseProvenance(
          client: signedReleaseClient(),
          tag: 'v9.9.9',
          archiveName: 'fa-test.tar.gz',
          archiveBytes: _fixtureTarGz,
        ),
        isFalse,
      );
    });
  });

  group('applyUpdate', () {
    Install binaryInstall(String path) => Install(InstallKind.binary, path);

    /// A client serving the fake release v9.9.9: permalink redirect,
    /// signed provenance fixtures, and the archive ([archiveBytes]).
    http.Client releaseClient({List<int>? archiveBytes}) =>
        MockClient((request) async {
          if (request.url.path.endsWith('/releases/latest')) {
            return http.Response(
              '',
              302,
              headers: {
                'location':
                    'https://github.com/IstiN/flutter_agent_harness/'
                    'releases/tag/v9.9.9',
              },
            );
          }
          if (request.url.path.endsWith('SHA256SUMS.sig')) {
            return http.Response.bytes(_fixtureSig, 200);
          }
          if (request.url.path.endsWith('SHA256SUMS')) {
            return http.Response(_fixtureSums, 200);
          }
          return http.Response.bytes(archiveBytes ?? _fixtureTarGz, 200);
        });

    /// A runProcess seam that actually extracts tar.gz archives instead of
    /// invoking the system `tar`.
    Future<ProcessResult> extractingRunProcess(
      String exe,
      List<String> args,
    ) async {
      if (exe == 'tar') {
        final destDir = args.last;
        final archiveFile = args[args.indexOf('-xzf') + 1];
        final data = File(archiveFile).readAsBytesSync();
        final decoded = TarDecoder().decodeBytes(
          GZipDecoder().decodeBytes(data),
        );
        for (final entry in decoded) {
          if (entry.isFile) {
            final parts = entry.name.split('/');
            final dest = File('$destDir/${parts.join('/')}');
            dest.parent.createSync(recursive: true);
            dest.writeAsBytesSync(entry.content as List<int>);
          }
        }
      }
      return ProcessResult(0, 0, '', '');
    }

    test(
      'downloads, verifies, swaps, keeps .bak, and spawns the successor',
      () async {
        final target = File('${temp.path}/fa')..writeAsStringSync('old');
        final spawnCalls = <List<String>>[];
        final log = <String>[];
        final outcome = await applyUpdate(
          currentVersion: '0.1.0',
          launchArgs: const ['--session', 'abc'],
          statePath: '${temp.path}/update-state.json',
          detectInstall: () => binaryInstall(target.path),
          newClient: () => releaseClient(),
          runProcess: extractingRunProcess,
          spawn: (exe, args) async {
            spawnCalls.add([exe, ...args]);
            return true;
          },
          pem: _testPem,
          logLine: log.add,
        );
        expect(outcome, ApplyUpdateOutcome.applied);
        expect(target.readAsStringSync(), 'new-binary');
        expect(spawnCalls, [
          [Platform.resolvedExecutable, '--session', 'abc'],
        ]);
        expect(log, contains('fa update applied: v0.1.0 -> v9.9.9'));
        if (!Platform.isWindows) {
          expect(File('${target.path}.bak').readAsStringSync(), 'old');
        }
      },
    );

    test(
      'is up to date when the latest tag equals the running version',
      () async {
        var requests = 0;
        final client = MockClient((request) async {
          requests++;
          return http.Response(
            '',
            302,
            headers: {
              'location':
                  'https://github.com/IstiN/flutter_agent_harness/'
                  'releases/tag/v0.1.0',
            },
          );
        });
        final outcome = await applyUpdate(
          currentVersion: '0.1.0',
          launchArgs: const [],
          statePath: '${temp.path}/update-state.json',
          detectInstall: () => binaryInstall('${temp.path}/fa'),
          newClient: () => client,
          spawn: (_, _) async => fail('no successor should be spawned'),
        );
        expect(outcome, ApplyUpdateOutcome.upToDate);
        expect(requests, 1);
      },
    );

    test('a tampered archive aborts with provenanceFailed', () async {
      final target = File('${temp.path}/fa')..writeAsStringSync('old');
      final tampered = List<int>.of(_fixtureTarGz)..[20] ^= 0x5A;
      var spawned = false;
      final outcome = await applyUpdate(
        currentVersion: '0.1.0',
        launchArgs: const [],
        statePath: '${temp.path}/update-state.json',
        detectInstall: () => binaryInstall(target.path),
        newClient: () => releaseClient(archiveBytes: tampered),
        runProcess: extractingRunProcess,
        spawn: (_, _) async => spawned = true,
        pem: _testPem,
        logLine: (_) {},
      );
      expect(outcome, ApplyUpdateOutcome.provenanceFailed);
      expect(target.readAsStringSync(), 'old');
      expect(spawned, isFalse);
    });

    test('a failed archive download reports downloadFailed', () async {
      final target = File('${temp.path}/fa')..writeAsStringSync('old');
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/releases/latest')) {
          return http.Response(
            '',
            302,
            headers: {
              'location':
                  'https://github.com/IstiN/flutter_agent_harness/'
                  'releases/tag/v9.9.9',
            },
          );
        }
        return http.Response('gone', 404);
      });
      final outcome = await applyUpdate(
        currentVersion: '0.1.0',
        launchArgs: const [],
        statePath: '${temp.path}/update-state.json',
        detectInstall: () => binaryInstall(target.path),
        newClient: () => client,
        spawn: (_, _) async => fail('no successor should be spawned'),
      );
      expect(outcome, ApplyUpdateOutcome.downloadFailed);
      expect(target.readAsStringSync(), 'old');
    });

    test('a dev run is refused without touching the network', () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        return http.Response('', 500);
      });
      final outcome = await applyUpdate(
        currentVersion: '0.1.0',
        launchArgs: const [],
        statePath: '${temp.path}/update-state.json',
        detectInstall: () =>
            const Install(InstallKind.devRun, 'bin/fah.dart'),
        newClient: () => client,
      );
      expect(outcome, ApplyUpdateOutcome.refusedDevRun);
      expect(requests, 0);
    });

    test(
      'a failed restart keeps the new binary and reports restartFailed',
      () async {
        final target = File('${temp.path}/fa')..writeAsStringSync('old');
        final log = <String>[];
        final outcome = await applyUpdate(
          currentVersion: '0.1.0',
          launchArgs: const [],
          statePath: '${temp.path}/update-state.json',
          detectInstall: () => binaryInstall(target.path),
          newClient: () => releaseClient(),
          runProcess: extractingRunProcess,
          spawn: (_, _) async => false,
          pem: _testPem,
          logLine: log.add,
        );
        expect(outcome, ApplyUpdateOutcome.restartFailed);
        expect(target.readAsStringSync(), 'new-binary');
        expect(log, contains('fa update restart failed'));
      },
    );
  });

  group('spawnSuccessor', () {
    test(
      'a successor still running after the settle delay counts as started',
      () async {
        final started = await spawnSuccessor(
          launchArgs: const [],
          spawn: (exe, args) => Process.start('/bin/sleep', const ['5']),
          settleDelay: const Duration(milliseconds: 300),
        );
        expect(started, isTrue);
      },
      skip: Platform.isWindows ? 'unix-only process fixtures' : null,
    );

    test(
      'a successor that exits non-zero during the settle delay fails',
      () async {
        final started = await spawnSuccessor(
          launchArgs: const [],
          spawn: (exe, args) =>
              Process.start('/bin/sh', const ['-c', 'exit 3']),
          settleDelay: const Duration(milliseconds: 300),
        );
        expect(started, isFalse);
      },
      skip: Platform.isWindows ? 'unix-only process fixtures' : null,
    );

    test('an unspawnable successor fails without throwing', () async {
      final started = await spawnSuccessor(
        launchArgs: const [],
        spawn: (exe, args) => Process.start(
          '${temp.path}/definitely-missing-binary',
          const [],
        ),
      );
      expect(started, isFalse);
    });
  });

  group('logUpdateLine', () {
    test('appends timestamped lines to <home>/.fah/logs/fa.log', () {
      final home = '${temp.path}/home';
      logUpdateLine('first line', home: home);
      logUpdateLine('second line', home: home);
      final log = File('$home/.fah/logs/fa.log').readAsStringSync();
      expect(
        log,
        matches(
          RegExp(
            r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)? first line\n'
            r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)? second line\n$',
          ),
        ),
      );
    });

    test('never throws when the log directory cannot be created', () {
      final blocker = File('${temp.path}/blocker')..writeAsStringSync('x');
      expect(
        () => logUpdateLine('nope', home: blocker.path),
        returnsNormally,
      );
    });
  });

  group('applyUpdate pub-global branch', () {
    test(
      're-activates via dart pub, spawns the fa shim, and records state',
      () async {
        final statePath = '${temp.path}/update-state.json';
        final runCalls = <(String, List<String>)>[];
        final spawnCalls = <(String, List<String>)>[];
        final log = <String>[];
        final outcome = await applyUpdate(
          currentVersion: '1.0.522',
          launchArgs: const ['--session', 'live'],
          detectInstall: () => Install(
            InstallKind.pubGlobal,
            '${temp.path}/pub-cache/bin/fa',
          ),
          newClient: () => releaseClient(),
          runProcess: (exe, args) async {
            runCalls.add((exe, args));
            // `pub global list` reports the OLD activation; activate
            // succeeds AND resolves the release version (the honest-log
            // parse must see an advance).
            final out = args.contains('list')
                ? 'flutter_agent_harness 1.0.522'
                : 'Activated flutter_agent_harness 9.9.9.';
            return ProcessResult(0, 0, out, '');
          },
          spawn: (exe, args) async {
            spawnCalls.add((exe, args));
            return true;
          },
          pem: _testPem,
          logLine: log.add,
          statePath: statePath,
        );
        expect(outcome, ApplyUpdateOutcome.applied);
        // list + activate ran (no deactivate: pub believes an OLDER spec).
        final verbs = [
          for (final (_, args) in runCalls)
            if (args.length >= 3) args[2],
        ];
        expect(verbs, containsAll(['list', 'activate']));
        expect(
          verbs.where((v) => v == 'deactivate'),
          isEmpty,
        );
        // The successor exe is the PATH shim (never the dart VM), and the
        // original argv — with the live session — rides through.
        final (spawnExe, spawnArgs) = spawnCalls.single;
        expect(spawnExe, endsWith('fa'));
        expect(spawnArgs, containsAllInOrder(['--session', 'live']));
        expect(log, contains('fa update applied: v1.0.522 -> v9.9.9'));
        // The convergence state recorded the first attempt at v9.9.9.
        final state =
            jsonDecode(File(statePath).readAsStringSync())
                as Map<String, dynamic>;
        expect(state['tag'], 'v9.9.9');
        expect(state['attempts'], 1);
      },
    );
  });

  group('applyUpdate convergence guard', () {
    test('caps repeat attempts for the same tag at two', () async {
      final statePath = '${temp.path}/update-state.json';
      var sumsFetches = 0;
      http.Client countingClient() => MockClient((request) async {
        if (request.url.path.endsWith('SHA256SUMS')) sumsFetches++;
        if (request.url.path.endsWith('/releases/latest')) {
          return http.Response(
            '',
            302,
            headers: {
              'location':
                  'https://github.com/IstiN/flutter_agent_harness/'
                  'releases/tag/v9.9.9',
            },
          );
        }
        if (request.url.path.endsWith('SHA256SUMS.sig')) {
          return http.Response.bytes(_fixtureSig, 200);
        }
        if (request.url.path.endsWith('SHA256SUMS')) {
          return http.Response(_fixtureSums, 200);
        }
        return http.Response.bytes(_fixtureTarGz, 200);
      });
      final target = File('${temp.path}/fa')..writeAsStringSync('old');
      Install binaryInstall() => Install(InstallKind.binary, target.path);
      final common = (
        currentVersion: '1.0.522',
        detectInstall: binaryInstall,
        newClient: countingClient,
        runProcess: extractingRunProcess,
        spawn: (_, _) async => true,
        pem: _testPem,
        logLine: (String _) {},
        statePath: statePath,
      );
      expect(
        await applyUpdate(
          currentVersion: common.currentVersion,
          launchArgs: const [],
          detectInstall: common.detectInstall,
          newClient: common.newClient,
          runProcess: common.runProcess,
          spawn: common.spawn,
          pem: common.pem,
          logLine: common.logLine,
          statePath: common.statePath,
        ),
        ApplyUpdateOutcome.applied,
      );
      expect(
        await applyUpdate(
          currentVersion: common.currentVersion,
          launchArgs: const [],
          detectInstall: common.detectInstall,
          newClient: common.newClient,
          runProcess: common.runProcess,
          spawn: common.spawn,
          pem: common.pem,
          logLine: common.logLine,
          statePath: common.statePath,
        ),
        ApplyUpdateOutcome.applied,
      );
      final before = sumsFetches;
      final log = <String>[];
      expect(
        await applyUpdate(
          currentVersion: common.currentVersion,
          launchArgs: const [],
          detectInstall: common.detectInstall,
          newClient: common.newClient,
          runProcess: common.runProcess,
          spawn: common.spawn,
          pem: common.pem,
          logLine: log.add,
          statePath: common.statePath,
        ),
        ApplyUpdateOutcome.convergenceGuard,
      );
      // The guarded boot never downloaded a third archive.
      expect(sumsFetches, before);
      expect(log.join('\n'), contains('not respawning again'));
    });

    test('a moved tag resets the attempt count', () async {
      final statePath = '${temp.path}/update-state.json';
      File(
        statePath,
      ).writeAsStringSync(jsonEncode({'tag': 'v0.0.1', 'attempts': 7}));
      final target = File('${temp.path}/fa')..writeAsStringSync('old');
      final outcome = await applyUpdate(
        currentVersion: '1.0.522',
        launchArgs: const [],
        detectInstall: () => Install(InstallKind.binary, target.path),
        newClient: () => releaseClient(),
        runProcess: extractingRunProcess,
        spawn: (_, _) async => true,
        pem: _testPem,
        logLine: (_) {},
        statePath: statePath,
      );
      expect(outcome, ApplyUpdateOutcome.applied);
      final state =
          jsonDecode(File(statePath).readAsStringSync())
              as Map<String, dynamic>;
      expect(state['tag'], 'v9.9.9');
      expect(state['attempts'], 1);
    });

    test('a blackholed network aborts through the outcome matrix', () async {
      final statePath = '${temp.path}/update-state.json';
      final hung = Completer<http.Response>().future;
      final client = MockClient((request) => hung);
      final outcome = await applyUpdate(
        currentVersion: '1.0.522',
        launchArgs: const [],
        detectInstall: () => Install(InstallKind.binary, '${temp.path}/fa'),
        newClient: () => client,
        spawn: (_, _) async => fail('no successor on a network abort'),
        statePath: statePath,
        networkTimeout: const Duration(milliseconds: 120),
      );
      expect(outcome, ApplyUpdateOutcome.downloadFailed);
    });

    test('a boot that reports up to date clears the state', () async {
      final statePath = '${temp.path}/update-state.json';
      File(
        statePath,
      ).writeAsStringSync(jsonEncode({'tag': 'v0.1.0', 'attempts': 2}));
      final client = MockClient((request) async {
        return http.Response(
          '',
          302,
          headers: {
            'location':
                'https://github.com/IstiN/flutter_agent_harness/'
                'releases/tag/v0.1.0',
          },
        );
      });
      final outcome = await applyUpdate(
        currentVersion: '0.1.0',
        launchArgs: const [],
        detectInstall: () => Install(InstallKind.binary, '${temp.path}/fa'),
        newClient: () => client,
        spawn: (_, _) async => fail('no successor on the up-to-date path'),
        statePath: statePath,
      );
      expect(outcome, ApplyUpdateOutcome.upToDate);
      expect(File(statePath).existsSync(), isFalse);
    });
  });

  group('successorArgs', () {
    test('appends the live session when the argv carries none', () {
      expect(
        successorArgs(const ['-p', 'hi'], 's1'),
        const ['-p', 'hi', '--session', 's1'],
      );
    });

    test('passes the argv through unchanged without a session id', () {
      const argv = ['-p', 'hi'];
      expect(identical(successorArgs(argv, null), argv), isTrue);
    });

    test(
      'never double-flags when the argv already resumes a session',
      () {
        expect(
          successorArgs(const ['--session', 'other'], 's1'),
          const ['--session', 'other'],
        );
        expect(
          successorArgs(const ['--session=other'], 's1'),
          const ['--session=other'],
        );
      },
    );
  });
}
