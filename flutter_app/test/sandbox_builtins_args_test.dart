// Table-driven tests for the sandbox builtin parsers and golden fixtures
// for the builtin semantics (issue #480). The parsers are pure and pinned
// arg-by-arg; the executors run against in-memory fakes so no real
// network or filesystem is touched.
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:fa/sandbox/sandbox_builtins.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The exact stdin/stdout/error contract every table row asserts.
void _expectError(SandboxBuiltinResult r, String message, int exitCode) {
  expect(utf8.decode(r.stderr), message);
  expect(r.exitCode, exitCode);
}

SandboxBuiltins _builtins({
  http.Client? httpClient,
  Map<String, List<int>> files = const {},
  Future<List<SandboxDirEntry>?> Function(String)? lister,
  SandboxDnsQuery? dnsQuery,
}) {
  return SandboxBuiltins(
    httpClient: httpClient,
    readTextFile: (path) async =>
        files[path] == null ? null : utf8.decode(files[path]!),
    writeBinaryFile: (path, bytes) async => files[path] = bytes,
    readBinaryFile: (path) async => files[path],
    listDirectory: lister,
    removeFile: (path) async => files.remove(path),
    makeDirectory: (path) async {},
    dnsQuery: dnsQuery,
  );
}

void main() {
  group('curl parser (parseCurlArgs + curlArgsFromWget)', () {
    test('flags parse to their fields', () {
      final p = SandboxBuiltins.parseCurlArgs([
        '-s', '-X', 'PUT', '-H', 'A: b', '--header', 'C: d',
        '-d', 'x=1', '--data-binary', 'raw', '--data-raw', '@lit',
        '-o', 'out.bin', '-L', 'https://e.example',
      ]);
      expect(p.url, 'https://e.example');
      expect(p.method, 'PUT');
      expect(p.explicitMethod, isTrue);
      expect(p.headers, {'A': 'b', 'C': 'd'});
      expect(p.dataArgs, hasLength(3));
      expect(p.outputFile, 'out.bin');
      expect(p.silent, isTrue);
      expect(p.followRedirects, isTrue);
    });
    test('data @file expands, @- is stdin, raw keeps @ literal', () {
      final p = SandboxBuiltins.parseCurlArgs(['-d', '@/f', 'u']);
      expect(p.dataArgs.single, ('@/f', true));
      final q = SandboxBuiltins.parseCurlArgs(['--data-raw', '@x', 'u']);
      expect(q.dataArgs.single, ('@x', false));
    });
    test('wget translation table', () {
      expect(
        SandboxBuiltins.curlArgsFromWget(['-q', '-O', 'f.bin', 'u']),
        ['-s', '-o', 'f.bin', 'u'],
      );
      expect(
        SandboxBuiltins.curlArgsFromWget(['--output-document=f', 'u']),
        ['-o', 'f', 'u'],
      );
      expect(
        SandboxBuiltins.curlArgsFromWget(['--no-check-certificate', 'u']),
        ['u'],
      );
      // A dangling -O drops the flag (a missing value).
      expect(SandboxBuiltins.curlArgsFromWget(['-O']), isEmpty);
    });
  });

  group('curl executor goldens', () {
    test('--version and --help short-circuit', () async {
      final b = _builtins();
      final v = await b.curl(['--version']);
      expect(utf8.decode(v.stdout), contains('curl 8.5.0'));
      expect(v.exitCode, 0);
      final h = await b.curl(['-h']);
      expect(utf8.decode(h.stdout), contains('Usage: curl'));
    });
    test('no URL is a usage error; bad URL exits 3', () async {
      final b = _builtins();
      _expectError(await b.curl([]), 'curl: no URL specified\n', 2);
      _expectError(await b.curl(['://bad']), 'curl: invalid URL\n', 3);
    });
    test('data implies POST unless -X is explicit; -o writes the file',
        () async {
      final methods = <String>[];
      final bodies = <String>[];
      final files = <String, List<int>>{};
      final b = SandboxBuiltins(
        httpClient: MockClient((request) async {
          methods.add(request.method);
          bodies.add(request.body);
          return http.Response('payload', 200);
        }),
        readTextFile: (_) async => null,
        writeBinaryFile: (path, bytes) async => files[path] = bytes,
      );
      final r = await b.curl(['-s', '-d', 'a=1', 'https://e.example']);
      expect(methods.single, 'POST');
      expect(bodies.single, 'a=1');
      expect(r.exitCode, 0);
      expect(r.stderr, isEmpty); // silent
      expect(utf8.decode(r.stdout), 'payload');

      final r2 = await b.curl([
        '-X', 'GET', '-d', 'a=1', '-o', 'out.bin', 'https://e.example',
      ]);
      expect(methods.last, 'GET');
      expect(utf8.decode(files['out.bin']!), 'payload');
      expect(utf8.decode(r2.stdout), isEmpty);
    });
    test('transport failure maps to exit 7 with the error', () async {
      final b = _builtins(
        httpClient: MockClient((request) async => throw Exception('x501')),
      );
      final r = await b.curl(['https://e.example']);
      expect(r.exitCode, 7);
      expect(utf8.decode(r.stderr), contains('curl: (7)'));
    });
  });

  group('diff parser (parseDiffArgs)', () {
    test('flag table', () {
      final d = SandboxBuiltins.parseDiffArgs(['-q', '-N', 'a', 'b']);
      expect(d.brief, isTrue);
      expect(d.newFile, isTrue);
      expect(d.context, 3);
      expect(d.operands, ['a', 'b']);
      expect(d.error, isNull);
    });
    test('-U context widths', () {
      expect(SandboxBuiltins.parseDiffArgs(['-U5', 'a', 'b']).context, 5);
      expect(SandboxBuiltins.parseDiffArgs(['-U', '7', 'a', 'b']).context, 7);
      final e = SandboxBuiltins.parseDiffArgs(['-Ux', 'a', 'b']);
      _expectError(e.error!, "diff: invalid context length 'x'\n", 2);
    });
    test('error table', () {
      _expectError(
        SandboxBuiltins.parseDiffArgs(['-Z']).error!,
        "diff: invalid option -- 'Z'\n",
        2,
      );
      _expectError(
        SandboxBuiltins.parseDiffArgs(['a']).error!,
        'diff: expected two file operands\n',
        2,
      );
    });
  });

  group('diff executor goldens', () {
    test('unified diff golden with context and headers', () async {
      final b = _builtins(
        files: {
          'a.txt': utf8.encode('one\ntwo\nthree\n'),
          'b.txt': utf8.encode('one\nTWO\nthree\n'),
        },
      );
      final r = await b.diff(['-u', 'a.txt', 'b.txt']);
      expect(r.exitCode, 1);
      expect(
        utf8.decode(r.stdout),
        '--- a.txt\n+++ b.txt\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n',
      );
    });
    test('identical files: empty output, exit 0; -q reports differ',
        () async {
      final b = _builtins(files: {
        'a.txt': utf8.encode('x\n'),
        'b.txt': utf8.encode('x\n'),
        'c.txt': utf8.encode('y\n'),
      });
      final same = await b.diff(['a.txt', 'b.txt']);
      expect(same.exitCode, 0);
      expect(same.stdout, isEmpty);
      final brief = await b.diff(['-q', 'a.txt', 'c.txt']);
      expect(
        utf8.decode(brief.stdout),
        'Files a.txt and c.txt differ\n',
      );
    });
    test('--new-file treats a missing file as empty', () async {
      final b = _builtins(files: {'b.txt': utf8.encode('new\n')});
      final r = await b.diff(['-N', 'a.txt', 'b.txt']);
      expect(r.exitCode, 1);
      expect(utf8.decode(r.stdout), contains('+new\n'));
    });
    test('missing operand without -N is an error', () async {
      final b = _builtins();
      _expectError(
        await b.diff(['nope.txt', 'b.txt']),
        'diff: nope.txt: No such file or directory\n',
        2,
      );
    });
    test('no-newline marker survives the round trip', () async {
      final b = _builtins(files: {
        'a.txt': utf8.encode('x'),
        'b.txt': utf8.encode('x\n'),
      });
      final r = await b.diff(['a.txt', 'b.txt']);
      expect(utf8.decode(r.stdout), contains('\\ No newline at end of file'));
    });
  });

  group('patch parser (parsePatchArgs)', () {
    test('flag table', () {
      final (error, p) = SandboxBuiltins.parsePatchArgs([
        '-p', '2', '--strip=1', '-i', 'p.diff', '--input=q.diff',
        '-p3', 'target',
      ]);
      expect(error, isNull);
      expect(p!.strip, 3); // last -p wins
      expect(p.patchFile, 'q.diff');
      expect(p.target, 'target');
    });
    test('error table', () {
      _expectError(
        SandboxBuiltins.parsePatchArgs(['-p']).$1!,
        'patch: option requires an argument -- p\n',
        2,
      );
      _expectError(
        SandboxBuiltins.parsePatchArgs(['-px']).$1!,
        "patch: invalid strip count 'x'\n",
        2,
      );
      _expectError(
        SandboxBuiltins.parsePatchArgs(['--frob']).$1!,
        "patch: unrecognized option '--frob'\n",
        2,
      );
      _expectError(
        SandboxBuiltins.parsePatchArgs(['a', 'b', 'c']).$1!,
        'patch: too many file arguments\n',
        2,
      );
    });
  });

  group('patch executor goldens', () {
    const patchText = '--- a.txt\n+++ b.txt\n@@ -1,3 +1,3 @@\n one\n-two\n'
        '+TWO\n three\n';
    test('applies a clean patch from stdin and writes the target', () async {
      final files = {
        'a.txt': utf8.encode('one\ntwo\nthree\n'),
      };
      final b = _builtins(files: files);
      final r = await b.patch(['a.txt'], stdin: patchText);
      expect(r.exitCode, 0, reason: utf8.decode(r.stderr));
      expect(utf8.decode(r.stdout), 'patching file a.txt\n');
      expect(utf8.decode(files['a.txt']!), 'one\nTWO\nthree\n');
    });
    test('-i reads the patch file; -p strips path components', () async {
      final files = {
        'dir/a.txt': utf8.encode('one\ntwo\nthree\n'),
        'p.diff': utf8.encode(
          '--- x/dir/a.txt\n+++ y/dir/a.txt\n@@ -1,3 +1,3 @@\n one\n-two\n'
          '+TWO\n three\n',
        ),
      };
      final b = _builtins(files: files);
      final r = await b.patch(['-i', 'p.diff', '-p', '1']);
      expect(r.exitCode, 0, reason: utf8.decode(r.stderr));
      expect(utf8.decode(files['dir/a.txt']!), 'one\nTWO\nthree\n');
    });
    test('a hunk that applies nowhere fails the file (exit 1, no write)',
        () async {
      final files = {'a.txt': utf8.encode('different\n')};
      final b = _builtins(files: files);
      final r = await b.patch(['a.txt'], stdin: patchText);
      expect(r.exitCode, 1);
      expect(utf8.decode(r.stderr), contains('Hunk #1 FAILED'));
      // The untouched original stays on disk.
      expect(utf8.decode(files['a.txt']!), 'different\n');
    });
    test('offset search applies a shifted hunk', () async {
      final files = {
        'a.txt': utf8.encode('lead\none\ntwo\nthree\ntrail\n'),
      };
      final b = _builtins(files: files);
      final r = await b.patch(['a.txt'], stdin: patchText);
      expect(r.exitCode, 0, reason: utf8.decode(r.stderr));
      expect(
        utf8.decode(files['a.txt']!),
        'lead\none\nTWO\nthree\ntrail\n',
      );
    });
    test('malformed patch text is a usage error', () async {
      final b = _builtins(files: {'a.txt': utf8.encode('x\n')});
      final r = await b.patch(['a.txt'], stdin: 'not a patch');
      _expectError(r, 'patch: no patch found in input\n', 2);
    });
  });

  group('jq filter (applyJqFilter)', () {
    final doc = {
      'a': {'b': 1},
      'list': [1, 2, 3],
      's': 'abcd',
    };
    test('filter table', () {
      expect(SandboxBuiltins.applyJqFilter(doc, '.'), [doc]);
      expect(SandboxBuiltins.applyJqFilter(doc, '.a.b'), [1]);
      expect(SandboxBuiltins.applyJqFilter(doc, '.list'), [
        [1, 2, 3],
      ]);
      expect(SandboxBuiltins.applyJqFilter(doc, '.list.length'), [3]);
      expect(SandboxBuiltins.applyJqFilter(doc, '.s.length'), [4]);
      expect(SandboxBuiltins.applyJqFilter(doc, '.length'), [3]);
      expect(SandboxBuiltins.applyJqFilter(doc, '.keys'), [
        ['a', 'list', 's'],
      ]);
      expect(SandboxBuiltins.applyJqFilter(doc, '.a'), [
        {'b': 1},
      ]);
      expect(SandboxBuiltins.applyJqFilter(doc, '.list[]'), [null]);
      expect(SandboxBuiltins.applyJqFilter(doc, '.missing'), [null]);
      expect(SandboxBuiltins.applyJqFilter(doc, '.missing.deep'), isEmpty);
      expect(SandboxBuiltins.applyJqFilter(1, '.length'), isEmpty);
      expect(SandboxBuiltins.applyJqFilter(1, '.keys'), isEmpty);
      expect(SandboxBuiltins.applyJqFilter(1, '.[0]'), isEmpty);
    });
  });

  group('jq builtin wiring', () {
    test('routes through applyJqFilter with -r for raw strings', () async {
      final b = _builtins(files: {'d.json': utf8.encode('{"a":"x"}')});
      final r = await b.jq(['-r', '.a', 'd.json']);
      expect(r.exitCode, 0, reason: utf8.decode(r.stderr));
      expect(utf8.decode(r.stdout), 'x\n');
    });
    test('stdin input and compact output', () async {
      final b = _builtins();
      final r = await b.jq(['-c', '.a'], stdin: '{"a":{"b":2}}');
      expect(utf8.decode(r.stdout), '{"b":2}\n');
    });
    test('missing filter or file is a usage error', () async {
      final b = _builtins();
      _expectError(await b.jq([]), 'jq: missing filter\n', 2);
      _expectError(await b.jq(['.a', 'nope.json']), 'jq: nope.json: No such file or directory\n', 2);
    });
  });

  group('tree parser (parseTreeArgs)', () {
    test('flag table', () {
      final t = SandboxBuiltins.parseTreeArgs(['-a', '-L', '2', 'root']);
      expect(t.showHidden, isTrue);
      expect(t.maxDepth, 2);
      expect(t.root, 'root');
      expect(t.early, isNull);
      expect(SandboxBuiltins.parseTreeArgs(['-L3']).maxDepth, 3);
      expect(
        SandboxBuiltins.parseTreeArgs(['--help']).early!.exitCode,
        0,
      );
      _expectError(
        SandboxBuiltins.parseTreeArgs(['-L']).early!,
        'tree: Missing argument to -L option.\n',
        2,
      );
      _expectError(
        SandboxBuiltins.parseTreeArgs(['-L0']).early!,
        'tree: Invalid level, must be greater than 0.\n',
        2,
      );
      _expectError(
        SandboxBuiltins.parseTreeArgs(['-Z']).early!,
        "tree: Invalid option - 'Z'\n",
        2,
      );
      _expectError(
        SandboxBuiltins.parseTreeArgs(['a', 'b']).early!,
        'tree: too many arguments\n',
        2,
      );
    });
  });

  group('tree executor goldens', () {
    Future<List<SandboxDirEntry>?> Function(String) lister() => (path) async {
          if (path == '.') {
            return [
              (name: '.hide', isDirectory: false),
              (name: 'dir', isDirectory: true),
              (name: 'z.txt', isDirectory: false),
            ];
          }
          if (path == './dir') {
            return [(name: 'deep', isDirectory: true)];
          }
          if (path == './dir/deep') {
            return [(name: 'leaf.txt', isDirectory: false)];
          }
          return null;
        };
    test('default listing golden', () async {
      final b = _builtins(lister: lister());
      final r = await b.tree([]);
      expect(
        utf8.decode(r.stdout),
        '.\n'
        '├── dir\n'
        '│   └── deep\n'
        '│       └── leaf.txt\n'
        '└── z.txt\n'
        '\n'
        '2 directories, 2 files\n',
      );
    });
    test('-a reveals dotfiles; -L cuts the depth; file root counts itself',
        () async {
      final b = _builtins(lister: lister());
      final hidden = await b.tree(['-a', '-L', '1']);
      expect(utf8.decode(hidden.stdout), contains('.hide'));
      final cut = await b.tree(['-L', '1']);
      expect(utf8.decode(cut.stdout), isNot(contains('deep')));

      final listerFn = lister();
      final fileRoot = _builtins(
        lister: (p) async => p == '.' ? listerFn('.') : null,
        files: {'single.txt': utf8.encode('x')},
      );
      final f = await fileRoot.tree(['single.txt']);
      expect(
        utf8.decode(f.stdout),
        'single.txt\n\n0 directories, 1 file\n',
      );
      _expectError(
        await _builtins(lister: lister()).tree(['nope']),
        'tree: nope: No such file or directory\n',
        1,
      );
    });
  });

  group('base64 parser (parseBase64Args) and wrapper', () {
    test('flag table', () {
      final b = SandboxBuiltins.parseBase64Args(['-d', '-w', '5', 'in.bin']);
      expect(b.decode, isTrue);
      expect(b.wrap, 5);
      expect(b.inputFile, 'in.bin');
      expect(SandboxBuiltins.parseBase64Args(['-w0']).wrap, 0);
      expect(SandboxBuiltins.parseBase64Args(['--wrap=9']).wrap, 9);
      _expectError(
        SandboxBuiltins.parseBase64Args(['-w']).error!,
        "base64: option requires an argument -- 'w'\n",
        2,
      );
      _expectError(
        SandboxBuiltins.parseBase64Args(['-wx']).error!,
        "base64: invalid wrap size: 'x'\n",
        2,
      );
      _expectError(
        SandboxBuiltins.parseBase64Args(['-Z']).error!,
        "base64: invalid option -- 'Z'\n",
        2,
      );
      _expectError(
        SandboxBuiltins.parseBase64Args(['a', 'b']).error!,
        "base64: extra operand 'b'\n",
        2,
      );
    });
    test('encode/decode goldens with wrapping', () async {
      final b = _builtins();
      final r = await b.base64([], stdin: 'hello fa harness\n');
      expect(utf8.decode(r.stdout), 'aGVsbG8gZmEgaGFybmVzcwo=\n');
      final d = await b.base64(
        ['-d'],
        stdin: 'aGVsbG8gZmEgaGFybmVzcwo=',
      );
      expect(utf8.decode(d.stdout), 'hello fa harness\n');
      // Decoding tolerates embedded whitespace.
      final dw = await b.base64(['-d'], stdin: 'aGVs\nbG8g');
      expect(utf8.decode(dw.stdout), startsWith('hello'));
      _expectError(await b.base64(['-d'], stdin: '!!!!'), 'base64: invalid input\n', 1);
    });
  });

  group('xz/bzip2 decompress', () {
    const xzB64 =
        '/Td6WFoAAATm1rRGAgAhARYAAAB0L+WjAQAQaGVsbG8gZmEgaGFybmVzcwoAAAAAlk8U'
        'MBky7akAASkRMgpwDh+2830BAAAAAARZWg==';
    const bz2B64 =
        'QlpoOTFBWSZTWSw6US0AAATRgAAQQAAjRZgAIAAiAGmQgGmmhG9DEMOKjlfi7kinChIF'
        'h0oloA==';
    test('xz -d replaces the file; -k keeps it; -c writes stdout', () async {
      final files = {'a.xz': base64.decode(xzB64)};
      final b = _builtins(files: files);
      final r = await b.xz(['-d', 'a.xz']);
      expect(r.exitCode, 0, reason: utf8.decode(r.stderr));
      expect(utf8.decode(files['a.xz'] ?? files['a']!), 'hello fa harness\n');
      expect(files.containsKey('a.xz'), isFalse); // original removed

      final files2 = {'a.xz': base64.decode(xzB64)};
      final b2 = _builtins(files: files2);
      await b2.xz(['-d', '-k', 'a.xz']);
      expect(files2.containsKey('a.xz'), isTrue);
      expect(utf8.decode(files2['a']!), 'hello fa harness\n');

      final b3 = _builtins(files: {'a.xz': base64.decode(xzB64)});
      final c = await b3.xz(['-dc', 'a.xz']);
      expect(utf8.decode(c.stdout), 'hello fa harness\n');
    });
    test('bzip2 -d decodes to stdout', () async {
      final b = _builtins(files: {'a.bz2': base64.decode(bz2B64)});
      final r = await b.bzip2(['-d', '-c', 'a.bz2']);
      expect(utf8.decode(r.stdout), 'hello fa harness\n');
    });
    test('error table', () async {
      final b = _builtins(
        files: {
          'a.xz': utf8.encode('nope'),
          'bogus.foo': utf8.encode('m'),
        },
      );
      _expectError(
        await b.xz(['a.xz']),
        'xz: compression is not supported in this sandbox, use xz -d to decompress\n',
        2,
      );
      _expectError(
        await b.xz(['-d']),
        'xz: missing operand\n',
        1,
      );
      _expectError(
        await b.xz(['-d', 'missing.xz']),
        'xz: missing.xz: No such file or directory\n',
        1,
      );
      _expectError(
        await b.xz(['-d', 'bogus.foo']),
        'xz: bogus.foo: unknown suffix -- ignored\n',
        1,
      );
      _expectError(
        await b.xz(['-dx', 'a.xz']),
        'xz: unsupported option -x\n',
        2,
      );
      _expectError(
        await b.xz(['--frob']),
        'xz: unsupported option --\n',
        2,
      );
      // Bad magic under a trusted suffix is "not in xz format".
      _expectError(
        await b.xz(['-d', 'a.xz']),
        'xz: a.xz: not in xz format\n',
        1,
      );
    });
  });

  group('hashsum executors', () {
    test('md5sum and sha256sum goldens', () async {
      final b = _builtins(files: {'f.txt': utf8.encode('hello\n')});
      final m = await b.hashsum('md5sum', ['f.txt']);
      expect(utf8.decode(m.stdout), 'b1946ac92492d2347c6235b4d2611184  f.txt\n');
      final s = await b.hashsum('sha256sum', ['f.txt']);
      expect(
        utf8.decode(s.stdout),
        '5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03  f.txt\n',
      );
    });
    test('stdin default and error table', () async {
      final b = _builtins(files: {'f.txt': utf8.encode('hello\n')});
      final stdinHash = await b.hashsum('md5sum', [], stdin: 'hello\n');
      expect(utf8.decode(stdinHash.stdout), contains('  -\n'));
      _expectError(
        await b.hashsum('md5sum', ['-Z']),
        "md5sum: invalid option -- 'Z'\n",
        2,
      );
      final missing = await b.hashsum('md5sum', ['nope.txt']);
      expect(missing.exitCode, 1);
      expect(utf8.decode(missing.stderr),
          'md5sum: nope.txt: No such file or directory\n');
    });
  });

  group('unzip parser and executor', () {
    test('parser flag table', () {
      final u = SandboxBuiltins.parseUnzipArgs(['-q', '-o', '-d', 'out', 'a.zip']);
      expect(u.destDir, 'out');
      expect(u.archives, ['a.zip']);
      expect(u.error, isNull);
      _expectError(
        SandboxBuiltins.parseUnzipArgs(['-Z']).error!,
        'unzip: unsupported option -Z\n',
        1,
      );
    });
    test('extracts regular files and recreates directories', () async {
      final content = utf8.encode('zip-content\n');
      final archive = Archive()
        ..addFile(ArchiveFile('z/', 0, <int>[]))
        ..addFile(ArchiveFile('z/a.txt', content.length, content));
      final zip = ZipEncoder().encode(archive);

      final files = <String, List<int>>{'a.zip': zip};
      final b = _builtins(files: files);
      final r = await b.unzip(['a.zip']);
      expect(r.exitCode, 0);
      // Entries are stored without a central directory; the decoder reads
      // local headers directly.
      expect(utf8.decode(files['./z/a.txt'] ?? const []), 'zip-content\n');
    });
    test('error table', () async {
      final b = _builtins(files: {'a.zip': utf8.encode('junk')});
      _expectError(
        await b.unzip(['-Z']),
        'unzip: unsupported option -Z\n',
        1,
      );
      _expectError(
        await b.unzip([]),
        'unzip: missing archive operand\n',
        1,
      );
      _expectError(
        await b.unzip(['missing.zip']),
        'unzip: cannot find or open missing.zip, missing.zip.zip or missing.zip.ZIP\n',
        1,
      );
      // package:archive yields an empty archive for garbage; nothing is
      // extracted and unzip exits 0.
      final junk = await b.unzip(['a.zip']);
      expect(junk.exitCode, 0);
    });
  });

  group('nslookup and dig', () {
    SandboxDnsQuery dns(List<SandboxDnsRecord> answers, {int status = 0}) =>
      (String name, String type) async => SandboxDnsResult(
            resolver: 'doh.test',
            status: status,
            // An AAAA query only returns AAAA records, so a host lookup
            // does not print the A answers twice.
            answers: type == 'AAAA'
                ? answers.where((r) => r.type == 28).toList()
                : answers,
          );

    test('nslookup host prints Name/Address blocks and CNAME lines',
        () async {
      final b = _builtins(
        dnsQuery: dns([
          SandboxDnsRecord(name: 'e.example', ttl: 300, type: 5, data: 'cname.example'),
          SandboxDnsRecord(name: 'cname.example', ttl: 60, type: 1, data: '1.2.3.4'),
        ]),
      );
      final r = await b.nslookup(['e.example']);
      expect(
        utf8.decode(r.stdout),
        'Server:  doh.test\n'
        '\n'
        'e.example canonical name = cname.example\n'
        'Name:    cname.example\n'
        'Address: 1.2.3.4\n',
      );
    });
    test('nslookup NXDOMAIN and empty answers', () async {
      final b = _builtins(dnsQuery: dns([], status: 3));
      _expectError(
        await b.nslookup(['e.example']),
        "server can't find e.example: NXDOMAIN\n",
        1,
      );
      final b2 = _builtins(dnsQuery: dns([]));
      _expectError(
        await b2.nslookup(['e.example']),
        "server can't find e.example: NOERROR\n",
        1,
      );
    });
    test('nslookup PTR branch', () async {
      final b = _builtins(
        dnsQuery: dns([
          SandboxDnsRecord(name: '4.3.2.1.in-addr.arpa', ttl: 60, type: 12, data: 'h.example'),
        ]),
      );
      final r = await b.nslookup(['1.2.3.4']);
      expect(
        utf8.decode(r.stdout),
        'Server:  doh.test\n\n4.3.2.1.in-addr.arpa name = h.example\n',
      );
    });
    test('dig parser and executor table', () async {
      expect(
        SandboxBuiltins.parseDigArgs(['-x', '1.2.3.4', 'PTR']).type,
        'PTR',
      );
      _expectError(
        SandboxBuiltins.parseDigArgs(['-Z']).error!,
        "dig: unknown option '-Z'\n",
        2,
      );
      _expectError(
        SandboxBuiltins.parseDigArgs(['-x', 'nope']).error!,
        'dig: -x expects an IPv4 address\n',
        2,
      );
      _expectError(
        SandboxBuiltins.parseDigArgs(['h', 'BOGUS']).error!,
        "dig: unknown query type 'BOGUS'\n",
        2,
      );
      final multi = SandboxBuiltins.parseDigArgs(['h', 'A', 'TXT']);
      expect(multi.error, isNull);
      expect(multi.type, 'TXT');
      _expectError(
        SandboxBuiltins.parseDigArgs([]).error!,
        'usage: dig [-x] <host> [TYPE]\n',
        2,
      );

      final b = _builtins(
        dnsQuery: dns([
          SandboxDnsRecord(name: 'e.example', ttl: 300, type: 1, data: '1.2.3.4'),
        ]),
      );
      final r = await b.dig(['e.example']);
      expect(
        utf8.decode(r.stdout),
        ';; status: NOERROR\n;; SERVER: doh.test\n\n;; ANSWER SECTION:\n'
        'e.example\t300\tIN\tA\t1.2.3.4\n',
      );
      // NXDOMAIN is still exit 0, like real dig.
      final b2 = _builtins(dnsQuery: dns([], status: 3));
      final r2 = await b2.dig(['e.example']);
      expect(r2.exitCode, 0);
      expect(utf8.decode(r2.stdout), contains(';; status: NXDOMAIN'));
    });
  });

  group('whois RDAP summary goldens', () {
    test('domain summary renders the recognized fields', () async {
      final b = _builtins(
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'objectClassName': 'domain',
              'ldhName': 'example.com',
              'handle': 'D1',
              'status': ['active'],
              'entities': [
                {
                  'roles': ['registrar'],
                  'vcardArray': [
                    'vcard',
                    [
                      ['fn', {}, 'text', 'Example Registrar'],
                    ],
                  ],
                  'publicIds': [
                    {'type': 'IANA ID', 'identifier': '999'},
                  ],
                },
              ],
              'events': [
                {'eventAction': 'registration', 'eventDate': '2020-01-01'},
              ],
              'nameservers': [
                {'ldhName': 'ns1.example.com'},
              ],
            }),
            200,
          );
        }),
      );
      final r = await b.whois(['example.com']);
      final out = utf8.decode(r.stdout);
      expect(out, contains('Domain Name: example.com\n'));
      expect(out, contains('Registry Domain ID: D1\n'));
      expect(out, contains('Domain Status: active\n'));
      expect(out, contains('Registrar: Example Registrar (IANA ID: 999)\n'));
      expect(out, contains('Creation Date: 2020-01-01\n'));
      expect(out, contains('Name Server: ns1.example.com\n'));
    });
    test('network summary and JSON fallback', () async {
      final b = _builtins(
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'objectClassName': 'ip network',
              'name': 'NET-1',
              'handle': 'N1',
              'startAddress': '1.2.3.0',
              'endAddress': '1.2.3.255',
              'country': 'US',
            }),
            200,
          );
        }),
      );
      final r = await b.whois(['1.2.3.4']);
      final out = utf8.decode(r.stdout);
      expect(out, contains('NetName: NET-1\n'));
      expect(out, contains('NetRange: 1.2.3.0 - 1.2.3.255\n'));
      expect(out, contains('Country: US\n'));

      final scalar = _builtins(
        httpClient: MockClient((request) async {
          return http.Response('["bare"]', 200);
        }),
      );
      final r2 = await scalar.whois(['weird.example']);
      expect(utf8.decode(r2.stdout), '[\n  "bare"\n]\n');
    });
  });

  group('file(1) classification goldens (_describeBytes table)', () {
    Future<String> classify(List<int> bytes) async {
      final b = _builtins(files: {'f': bytes});
      final r = await b.file(['f']);
      return utf8.decode(r.stdout).substring('f: '.length).trim();
    }

    test('magic table', () async {
      expect(await classify(const []), 'empty');
      expect(
        await classify([0x00, 0x61, 0x73, 0x6d, 1, 0, 0, 0]),
        'WebAssembly (wasm) binary module version 0x1 (MVP)',
      );
      expect(
        await classify([0x00, 0x61, 0x73, 0x6d]),
        'WebAssembly (wasm) binary module',
      );
      expect(
        await classify([0x50, 0x4b, 0x03, 0x04, 0, 0]),
        'Zip archive data',
      );
      expect(await classify([0x1f, 0x8b]), 'gzip compressed data');
      expect(
        await classify([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]),
        'XZ compressed data',
      );
      expect(
        await classify([0x42, 0x5a, 0x68, 0x39]),
        'bzip2 compressed data, block size = 900k',
      );
      expect(
        await classify([0x42, 0x5a, 0x68]),
        'bzip2 compressed data',
      );
      expect(
        await classify([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
        'PNG image data',
      );
      expect(await classify([0xff, 0xd8, 0xff, 0xe0]), 'JPEG image data');
      expect(
        await classify('GIF87a'.codeUnits),
        'GIF image data, version 87a',
      );
      expect(
        await classify('GIF89a'.codeUnits),
        'GIF image data, version 89a',
      );
      expect(
        await classify([
          ...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits,
        ]),
        'RIFF (little-endian) data, Web/P image',
      );
      expect(await classify('%PDF-1.4'.codeUnits), 'PDF document');
      expect(
        await classify('SQLite format 3\x00'.codeUnits),
        'SQLite 3.x database',
      );
      final tar = List<int>.filled(600, 0);
      for (var i = 0; i < 5; i++) {
        tar[257 + i] = 'ustar'.codeUnits[i];
      }
      expect(await classify(tar), 'POSIX tar archive');
      expect(
        await classify([0x7f, 0x45, 0x4c, 0x46, 2, 1]),
        'ELF 64-bit LSB executable',
      );
      expect(
        await classify([0x7f, 0x45, 0x4c, 0x46]),
        'ELF executable',
      );
      expect(
        await classify([0xfe, 0xed, 0xfa, 0xce]),
        'Mach-O 32-bit executable',
      );
      expect(
        await classify([0xcf, 0xfa, 0xed, 0xfe]),
        'Mach-O 64-bit executable',
      );
      expect(
        await classify([0xca, 0xfe, 0xba, 0xbe]),
        'Mach-O universal binary',
      );
      expect(await classify('plain text\n'.codeUnits), 'ASCII text');
      expect(await classify(utf8.encode('héllo\n')), 'UTF-8 Unicode text');
      expect(await classify([0x00, 0x01, 0x02]), 'data');
    });
  });
}

