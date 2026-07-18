// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Host-side tests for pip-lite (`sandbox_pip.dart`): argument parsing,
/// wheel tag parsing/selection, PyPI JSON resolution against canned
/// MockClient responses, install/unzip into a fake sandbox filesystem, and
/// the micropip orchestration used by the web shell (with a fake python
/// runner, so no browser and no network).
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_agent_example/memory_shell.dart';
import 'package:flutter_agent_example/sandbox_pip.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('parsePipSpec', () {
    test('parses name, pinned, and dash-shorthand specs', () {
      expect(parsePipSpec('six')?.name, 'six');
      expect(parsePipSpec('six')?.version, isNull);
      expect(parsePipSpec('six==1.16.0')?.version, '1.16.0');
      expect(parsePipSpec('six-1.16.0')?.name, 'six');
      expect(parsePipSpec('six-1.16.0')?.version, '1.16.0');
      // A trailing dash segment that does not look like a version stays
      // part of the package name.
      expect(parsePipSpec('python-dateutil')?.name, 'python-dateutil');
      expect(parsePipSpec('python-dateutil')?.version, isNull);
      expect(parsePipSpec('typing_extensions')?.name, 'typing_extensions');
    });

    test('rejects invalid specs', () {
      expect(parsePipSpec(''), isNull);
      expect(parsePipSpec('==1.0'), isNull);
      expect(parsePipSpec('six=='), isNull);
      expect(parsePipSpec('six==1.0!'), isNotNull); // PEP 440 epoch is fine
      expect(parsePipSpec('-six'), isNull);
      expect(parsePipSpec('si x'), isNull);
      expect(parsePipSpec('six==1."0'), isNull);
    });
  });

  group('parsePipArgs', () {
    test('no args and help flags map to help', () {
      expect(parsePipArgs(const []).subcommand, PipSubcommand.help);
      expect(parsePipArgs(const ['--help']).subcommand, PipSubcommand.help);
      expect(parsePipArgs(const ['help']).subcommand, PipSubcommand.help);
      expect(
        parsePipArgs(const ['--version']).subcommand,
        PipSubcommand.version,
      );
    });

    test('unknown command is a usage error', () {
      final parsed = parsePipArgs(const ['frobnicate']);
      expect(parsed.usageError, contains('unknown command'));
    });

    test('install validates operands', () {
      expect(parsePipArgs(const ['install']).usageError, contains('requires'));
      expect(
        parsePipArgs(const ['install', '--verbose']).usageError,
        contains('no such option'),
      );
      expect(
        parsePipArgs(const ['install', '<<bad>>']).usageError,
        contains('invalid requirement'),
      );
      final ok = parsePipArgs(const ['install', 'six', 'requests==2.31.0']);
      expect(ok.usageError, isNull);
      expect(ok.specs.map((s) => s.toString()), ['six', 'requests==2.31.0']);
    });

    test('list takes no arguments', () {
      expect(parsePipArgs(const ['list']).usageError, isNull);
      expect(parsePipArgs(const ['list', 'six']).usageError, isNotNull);
    });

    test('show takes exactly one package', () {
      expect(parsePipArgs(const ['show']).usageError, isNotNull);
      expect(
        parsePipArgs(const ['show', 'six', 'mypkg']).usageError,
        isNotNull,
      );
      expect(parsePipArgs(const ['show', 'six']).usageError, isNull);
    });

    test('uninstall accepts -y and multiple packages', () {
      final parsed = parsePipArgs(const ['uninstall', '-y', 'six', 'mypkg']);
      expect(parsed.usageError, isNull);
      expect(parsed.specs.map((s) => s.name), ['six', 'mypkg']);
    });
  });

  group('parseWheelFilename', () {
    test('parses tags and pure-python detection', () {
      final pure = parseWheelFilename(
        'requests-2.31.0-py3-none-any.whl',
        'https://x/requests-2.31.0-py3-none-any.whl',
      )!;
      expect(pure.pythonTag, 'py3');
      expect(pure.abiTag, 'none');
      expect(pure.platformTag, 'any');
      expect(pure.isPurePython, isTrue);

      expect(
        parseWheelFilename('six-1.16.0-py2.py3-none-any.whl', '')!.isPurePython,
        isTrue,
      );
      // Build tag between version and python tag.
      expect(
        parseWheelFilename('pkg-1.0-1-py3-none-any.whl', '')!.isPurePython,
        isTrue,
      );
      final binary = parseWheelFilename(
        'numpy-1.26.0-cp312-cp312-manylinux_2_17_x86_64.whl',
        '',
      )!;
      expect(binary.isPurePython, isFalse);
    });

    test('rejects non-wheel filenames', () {
      expect(parseWheelFilename('pkg-1.0.tar.gz', ''), isNull);
      expect(parseWheelFilename('pkg.whl', ''), isNull);
    });
  });

  group('resolvePipWheel', () {
    http.Client pypiClient(Map<String, http.Response Function()> routes) {
      return MockClient((request) async {
        final handler = routes[request.url.toString()];
        if (handler == null) return http.Response('not found', 404);
        return handler();
      });
    }

    test('picks the pure wheel and reports the resolved version', () async {
      final client = pypiClient({
        'https://pypi.org/pypi/six/json': () => http.Response(
          jsonEncode({
            'info': {'name': 'six', 'version': '1.16.0'},
            'urls': [
              {
                'filename': 'six-1.16.0.tar.gz',
                'url': 'https://files.pythonhosted.org/six-1.16.0.tar.gz',
                'packagetype': 'sdist',
              },
              {
                'filename': 'six-1.16.0-py2.py3-none-any.whl',
                'url':
                    'https://files.pythonhosted.org/six-1.16.0-py2.py3-none-any.whl',
                'packagetype': 'bdist_wheel',
              },
            ],
          }),
          200,
        ),
      });
      final resolution = await resolvePipWheel(
        client,
        const PipPackageSpec('six'),
      );
      expect(resolution.error, isNull);
      expect(resolution.version, '1.16.0');
      expect(resolution.wheel!.filename, 'six-1.16.0-py2.py3-none-any.whl');
    });

    test('prefers py3-none-any over other pure tags', () async {
      final client = pypiClient({
        'https://pypi.org/pypi/pkg/json': () => http.Response(
          jsonEncode({
            'info': {'name': 'pkg', 'version': '2.0'},
            'urls': [
              {
                'filename': 'pkg-2.0-py39-none-any.whl',
                'url':
                    'https://files.pythonhosted.org/pkg-2.0-py39-none-any.whl',
                'packagetype': 'bdist_wheel',
              },
              {
                'filename': 'pkg-2.0-py3-none-any.whl',
                'url':
                    'https://files.pythonhosted.org/pkg-2.0-py3-none-any.whl',
                'packagetype': 'bdist_wheel',
              },
            ],
          }),
          200,
        ),
      });
      final resolution = await resolvePipWheel(
        client,
        const PipPackageSpec('pkg'),
      );
      expect(resolution.wheel!.filename, 'pkg-2.0-py3-none-any.whl');
    });

    test('pinned versions query the version URL', () async {
      final client = pypiClient({
        'https://pypi.org/pypi/six/1.15.0/json': () => http.Response(
          jsonEncode({
            'info': {'name': 'six', 'version': '1.15.0'},
            'urls': [
              {
                'filename': 'six-1.15.0-py2.py3-none-any.whl',
                'url':
                    'https://files.pythonhosted.org/six-1.15.0-py2.py3-none-any.whl',
                'packagetype': 'bdist_wheel',
              },
            ],
          }),
          200,
        ),
      });
      final resolution = await resolvePipWheel(
        client,
        const PipPackageSpec('six', '1.15.0'),
      );
      expect(resolution.error, isNull);
      expect(resolution.wheel!.filename, contains('1.15.0'));
    });

    test('binary-only package is refused with a clear message', () async {
      final client = pypiClient({
        'https://pypi.org/pypi/grpcio/json': () => http.Response(
          jsonEncode({
            'info': {'name': 'grpcio', 'version': '1.60.0'},
            'urls': [
              {
                'filename':
                    'grpcio-1.60.0-cp312-cp312-manylinux_2_17_x86_64.whl',
                'url':
                    'https://files.pythonhosted.org/grpcio-1.60.0-cp312-cp312-manylinux_2_17_x86_64.whl',
                'packagetype': 'bdist_wheel',
              },
            ],
          }),
          200,
        ),
      });
      final resolution = await resolvePipWheel(
        client,
        const PipPackageSpec('grpcio'),
      );
      expect(resolution.wheel, isNull);
      expect(resolution.error, contains('no pure-Python wheel'));
      expect(resolution.error, contains('manylinux'));
    });

    test('unknown package reports "from versions: none"', () async {
      final client = pypiClient({});
      final resolution = await resolvePipWheel(
        client,
        const PipPackageSpec('nosuchpkg'),
      );
      expect(resolution.error, contains('Could not find a version'));
      expect(resolution.error, contains('from versions: none'));
    });

    test('unknown pinned version lists the available versions', () async {
      final client = pypiClient({
        'https://pypi.org/pypi/six/json': () => http.Response(
          jsonEncode({
            'info': {'name': 'six'},
            'releases': {'1.0': [], '1.16.0': []},
          }),
          200,
        ),
      });
      final resolution = await resolvePipWheel(
        client,
        const PipPackageSpec('six', '9.9.9'),
      );
      expect(resolution.error, contains('six==9.9.9'));
      expect(resolution.error, contains('1.16.0'));
    });

    test('transport failure surfaces as an error message', () async {
      final client = MockClient((request) async => throw StateError('boom'));
      final resolution = await resolvePipWheel(
        client,
        const PipPackageSpec('six'),
      );
      expect(resolution.error, contains('Could not reach PyPI'));
    });
  });

  group('SandboxPipBuiltins', () {
    const sitePackages = '/usr/local/lib/python3.14/site-packages';

    late Map<String, List<int>> files;
    late Set<String> dirs;

    String parentOf(String path) =>
        path.substring(0, path.lastIndexOf('/')).isEmpty
        ? '/'
        : path.substring(0, path.lastIndexOf('/'));

    SandboxPipBuiltins pipFor(http.Client client) {
      return SandboxPipBuiltins(
        httpClient: client,
        sitePackagesPath: sitePackages,
        writeBinaryFile: (path, bytes) async {
          files[path] = bytes;
          var dir = parentOf(path);
          while (dir != '/') {
            dirs.add(dir);
            dir = parentOf(dir);
          }
        },
        listDirectory: (path) async {
          if (!dirs.contains(path) && path != '/') return null;
          final seen = <String>{};
          final entries = <({String name, bool isDirectory})>[];
          void add(String child, bool isDir) {
            final rest = child.substring(path.length + 1);
            final name = rest.split('/').first;
            if (name.isEmpty || !seen.add(name)) return;
            entries.add((name: name, isDirectory: isDir || rest.contains('/')));
          }

          for (final dir in dirs) {
            if (dir != path && parentOf(dir) == path) add(dir, true);
          }
          for (final file in files.keys) {
            if (parentOf(file) == path) add(file, false);
          }
          return entries;
        },
        readTextFile: (path) async {
          final bytes = files[path];
          return bytes == null ? null : utf8.decode(bytes);
        },
        removeFile: (path) async {
          files.remove(path);
        },
        removeDirectory: (path) async {
          files.removeWhere((key, _) => key.startsWith('$path/'));
          dirs.removeWhere((dir) => dir == path || dir.startsWith('$path/'));
        },
      );
    }

    List<int> buildWheel(Map<String, String> entries) {
      final archive = Archive();
      entries.forEach((name, content) {
        final bytes = utf8.encode(content);
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      });
      return ZipEncoder().encode(archive);
    }

    String pypiJson({
      required String name,
      required String version,
      required List<Map<String, String>> urls,
    }) {
      return jsonEncode({
        'info': {'name': name, 'version': version},
        'urls': [
          for (final file in urls)
            {
              'filename': file['filename'],
              'url': file['url'],
              'packagetype': file['packagetype'] ?? 'bdist_wheel',
            },
        ],
      });
    }

    late List<int> wheelBytes;
    late http.Client client;

    setUp(() {
      files = {};
      dirs = {'/usr/local/lib/python3.14/site-packages'};
      wheelBytes = buildWheel({
        'mypkg/__init__.py': 'VALUE = 42\n',
        'mypkg-1.0.dist-info/METADATA':
            'Metadata-Version: 2.1\n'
            'Name: mypkg\n'
            'Version: 1.0\n'
            'Summary: A test package\n'
            'Author: FAH\n'
            'License: MIT\n'
            'Requires-Dist: six (>=1.0)\n',
        'mypkg-1.0.dist-info/RECORD':
            'mypkg/__init__.py,sha256=abc,11\n'
            'mypkg-1.0.dist-info/METADATA,sha256=def,120\n'
            'mypkg-1.0.dist-info/RECORD,,\n',
        // Must be skipped: path traversal and .data payload.
        '../evil.py': 'raise SystemError\n',
        'mypkg-1.0.data/scripts/run': '#!/bin/sh\n',
      });
      client = MockClient((request) async {
        switch (request.url.toString()) {
          case 'https://pypi.org/pypi/mypkg/json':
            return http.Response(
              pypiJson(
                name: 'mypkg',
                version: '1.0',
                urls: [
                  {
                    'filename': 'mypkg-1.0-py3-none-any.whl',
                    'url':
                        'https://files.pythonhosted.org/mypkg-1.0-py3-none-any.whl',
                  },
                  {
                    'filename': 'mypkg-1.0.tar.gz',
                    'url': 'https://files.pythonhosted.org/mypkg-1.0.tar.gz',
                    'packagetype': 'sdist',
                  },
                ],
              ),
              200,
            );
          case 'https://files.pythonhosted.org/mypkg-1.0-py3-none-any.whl':
            return http.Response.bytes(wheelBytes, 200);
          case 'https://pypi.org/pypi/grpcio/json':
            return http.Response(
              pypiJson(
                name: 'grpcio',
                version: '1.60.0',
                urls: [
                  {
                    'filename':
                        'grpcio-1.60.0-cp312-cp312-manylinux_2_17_x86_64.whl',
                    'url': 'https://files.pythonhosted.org/grpcio.whl',
                  },
                ],
              ),
              200,
            );
        }
        return http.Response('not found', 404);
      });
    });

    test('usage errors exit 2; help/version exit 0', () async {
      final pip = pipFor(client);
      var r = await pip.run(const []);
      expect(r.exitCode, 0);
      expect(utf8.decode(r.stdout), contains('Usage: pip'));

      r = await pip.run(const ['--version']);
      expect(r.exitCode, 0);
      expect(utf8.decode(r.stdout), contains('pip'));

      r = await pip.run(const ['frobnicate']);
      expect(r.exitCode, 2);
      expect(utf8.decode(r.stderr), contains('unknown command'));

      r = await pip.run(const ['install']);
      expect(r.exitCode, 2);
    });

    test('install unzips the wheel into site-packages', () async {
      final pip = pipFor(client);
      final r = await pip.run(const ['install', 'mypkg']);
      expect(r.exitCode, 0, reason: utf8.decode(r.stderr));
      expect(utf8.decode(r.stdout), 'Successfully installed mypkg-1.0\n');
      expect(
        utf8.decode(files['$sitePackages/mypkg/__init__.py']!),
        'VALUE = 42\n',
      );
      expect(
        files.containsKey('$sitePackages/mypkg-1.0.dist-info/METADATA'),
        isTrue,
      );
      // Traversal and .data entries were skipped.
      expect(files.keys.any((p) => p.contains('evil')), isFalse);
      expect(files.keys.any((p) => p.contains('.data')), isFalse);
    });

    test('binary-only package is refused with exit 1', () async {
      final pip = pipFor(client);
      final r = await pip.run(const ['install', 'grpcio']);
      expect(r.exitCode, 1);
      expect(utf8.decode(r.stderr), contains('no pure-Python wheel'));
      expect(files, isEmpty);
    });

    test('unknown package exits 1 with the pip-style message', () async {
      final pip = pipFor(client);
      final r = await pip.run(const ['install', 'nosuchpkg']);
      expect(r.exitCode, 1);
      expect(utf8.decode(r.stderr), contains('Could not find a version'));
    });

    test('list prints installed dists from dist-info dirs', () async {
      final pip = pipFor(client);
      var r = await pip.run(const ['list']);
      expect(r.exitCode, 0);
      expect(utf8.decode(r.stdout), 'Package Version\n------- -------\n');

      await pip.run(const ['install', 'mypkg']);
      r = await pip.run(const ['list']);
      final out = utf8.decode(r.stdout);
      expect(out, contains('Package'));
      expect(out, contains('mypkg'));
      expect(out, contains('1.0'));
    });

    test('show prints METADATA fields', () async {
      final pip = pipFor(client);
      await pip.run(const ['install', 'mypkg']);
      final r = await pip.run(const ['show', 'mypkg']);
      expect(r.exitCode, 0);
      final out = utf8.decode(r.stdout);
      expect(out, contains('Name: mypkg'));
      expect(out, contains('Version: 1.0'));
      expect(out, contains('Summary: A test package'));
      expect(out, contains('Location: $sitePackages'));
      expect(out, contains('Requires: six'));

      final missing = await pip.run(const ['show', 'nosuchpkg']);
      expect(missing.exitCode, 0);
      expect(utf8.decode(missing.stderr), contains('not found'));
    });

    test('uninstall removes the package and its dist-info', () async {
      final pip = pipFor(client);
      await pip.run(const ['install', 'mypkg']);
      final r = await pip.run(const ['uninstall', 'mypkg']);
      expect(r.exitCode, 0);
      expect(utf8.decode(r.stdout), contains('Successfully uninstalled'));
      expect(files.keys.any((p) => p.contains('mypkg')), isFalse);
      final list = await pip.run(const ['list']);
      expect(utf8.decode(list.stdout), isNot(contains('mypkg')));

      final again = await pip.run(const ['uninstall', 'mypkg']);
      expect(again.exitCode, 0);
      expect(utf8.decode(again.stdout), contains('not installed'));
    });
  });

  group('runMicropipPip (web orchestration)', () {
    test('help/version/usage errors never touch the runner', () async {
      var called = false;
      Future<({String stdout, String stderr, String? error})> runner(
        String code,
      ) async {
        called = true;
        return (stdout: '', stderr: '', error: null);
      }

      var r = await runMicropipPip(const [], runner);
      expect(r.exitCode, 0);
      expect(r.stdout, contains('Usage: pip'));

      r = await runMicropipPip(const ['--version'], runner);
      expect(r.exitCode, 0);
      expect(r.stdout, contains('micropip'));

      r = await runMicropipPip(const ['frobnicate'], runner);
      expect(r.exitCode, 2);
      expect(r.stderr, contains('unknown command'));

      expect(called, isFalse);
    });

    test('install generates a micropip snippet and formats success', () async {
      String? code;
      final r = await runMicropipPip(const ['install', 'requests==2.31.0'], (
        c,
      ) async {
        code = c;
        return (
          stdout: 'PIPVER:{"requests":"2.31.0"}',
          stderr: '',
          error: null,
        );
      });
      expect(code, contains('await micropip.install(["requests==2.31.0"])'));
      expect(code, contains('importlib.metadata'));
      expect(r.exitCode, 0);
      expect(r.stdout, 'Successfully installed requests-2.31.0\n');
    });

    test(
      'binary wheel refusal from micropip is surfaced with a hint',
      () async {
        final r = await runMicropipPip(const ['install', 'grpcio'], (
          code,
        ) async {
          return (
            stdout: '',
            stderr: '',
            error:
                "PythonError: ValueError: Couldn't find a pure Python 3 wheel "
                "for 'grpcio'",
          );
        });
        expect(r.exitCode, 1);
        expect(r.stderr, contains("Couldn't find a pure Python 3 wheel"));
        expect(r.stderr, contains('pure-Python wheels'));
      },
    );

    test('list formats the micropip.list() JSON as a table', () async {
      final r = await runMicropipPip(const ['list'], (code) async {
        expect(code, contains('micropip.list()'));
        return (
          stdout: 'PIPLIST:{"six":"1.16.0","requests":"2.31.0"}',
          stderr: '',
          error: null,
        );
      });
      expect(r.exitCode, 0);
      expect(r.stdout, contains('Package'));
      expect(r.stdout, contains('requests'));
      expect(r.stdout, contains('2.31.0'));
      // Sorted case-insensitively: requests before six.
      expect(r.stdout.indexOf('requests'), lessThan(r.stdout.indexOf('six')));
    });

    test('show formats metadata and maps not-found to a warning', () async {
      var r = await runMicropipPip(const ['show', 'six'], (code) async {
        expect(code, contains('_fahpip_md.metadata("six")'));
        return (
          stdout:
              'PIPSHOW:{"Name":"six","Version":"1.16.0","Summary":"s",'
              '"Home-page":"","Author":"","License":"MIT"}',
          stderr: '',
          error: null,
        );
      });
      expect(r.exitCode, 0);
      expect(r.stdout, contains('Name: six'));
      expect(r.stdout, contains('License: MIT'));
      expect(r.stdout, isNot(contains('Home-page')));

      r = await runMicropipPip(const ['show', 'nosuchpkg'], (code) async {
        return (stdout: '', stderr: '', error: 'SystemExit: PIP_NOT_FOUND');
      });
      expect(r.exitCode, 0);
      expect(r.stderr, contains('not found'));
    });

    test('uninstall handles installed and missing packages', () async {
      var r = await runMicropipPip(const ['uninstall', 'six'], (code) async {
        expect(code, contains('micropip.uninstall(_fahpip_names)'));
        return (
          stdout: 'PIPUNINSTALLED:{"six":"1.16.0"}',
          stderr: '',
          error: null,
        );
      });
      expect(r.exitCode, 0);
      expect(r.stdout, 'Successfully uninstalled six-1.16.0\n');

      r = await runMicropipPip(const ['uninstall', 'six'], (code) async {
        return (stdout: 'PIPMISSING:six', stderr: '', error: null);
      });
      expect(r.exitCode, 0);
      expect(r.stdout, contains('not installed'));
    });
  });

  group('MemoryShell pip on the host (stub interpreters)', () {
    late MemoryExecutionEnv env;

    setUp(() {
      final shell = MemoryShell();
      env = MemoryExecutionEnv(cwd: '/', shell: shell);
      shell.attach(env);
    });

    Future<ShellExecResult> run(String command) async {
      final result = await env.exec(command);
      expect(result.isOk, isTrue, reason: result.errorOrNull.toString());
      return result.valueOrNull!;
    }

    test('which finds pip/pip3 but execution is unavailable off-web', () async {
      var r = await run('which pip');
      expect(r.exitCode, 0);
      expect(r.stdout, '/bin/pip\n');
      r = await run('which pip3');
      expect(r.exitCode, 0);

      r = await run('pip install six');
      expect(r.exitCode, 127);
      expect(r.stderr, contains('command not found'));
    });
  });
}
