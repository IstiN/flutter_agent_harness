// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import '../../bin/self_manage.dart';

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
      // Build a tar.gz containing bundle/bin/fa with the new binary content.
      final newBinaryBytes = utf8.encode('new-binary');
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('bundle/bin/fa', newBinaryBytes));
      final tarGzBytes = GZipEncoder().encode(TarEncoder().encode(archive));
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
        return http.Response.bytes(tarGzBytes, 200);
      });
      final processes = <List<String>>[];
      final code = await runSelfUpdate(
        currentVersion: '0.1.0',
        detectInstall: () => binaryInstall(target.path),
        newClient: () => client,
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

  group('fallbackZipUpdate', () {
    List<int> zipWithBinary(List<int> binary) {
      final archive = Archive()
        ..addFile(
          ArchiveFile('Fa.app/Contents/MacOS/Fa', binary.length, binary),
        );
      return ZipEncoder().encode(archive);
    }

    test('extracts and swaps the macOS binary from a zip asset', () async {
      final target = File('${temp.path}/fa')..writeAsStringSync('old');
      final binary = 'new-zip-binary'.codeUnits;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('fa-macos-arm64-mac.zip')) {
          return http.Response.bytes(zipWithBinary(binary), 200);
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
}
