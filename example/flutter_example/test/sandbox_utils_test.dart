// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Host coverage for the small-utils sandbox builtins shared by both
/// shells: `tree`, `file`, `xz -d`/`bzip2 -d` (+ `unxz`/`bunzip2`),
/// `base64`, and the `md5sum`/`sha*sum` checksums (all implemented in
/// `sandbox_builtins.dart`). On the host they run through the pure-Dart
/// [MemoryShell]; the iOS WASM shell serves tree/file/xz/bzip2 from the
/// same code and gets base64 plus the checksums from uutils coreutils.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_agent_example/memory_shell.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  Future<void> writeBytes(String path, List<int> bytes) async {
    final written = await env.writeBinaryFile(path, Uint8List.fromList(bytes));
    expect(written.isOk, isTrue, reason: written.errorOrNull.toString());
  }

  group('tree', () {
    setUp(() async {
      await run('mkdir -p /t/a /t/c');
      await run('echo nested > /t/a/nested.txt');
      await run('echo b > /t/b.txt');
    });

    test('draws classic characters, sorted entries, and the summary', () async {
      final r = await run('tree /t');
      expect(r.exitCode, 0, reason: r.stderr);
      expect(
        r.stdout,
        '/t\n'
        '├── a\n'
        '│   └── nested.txt\n'
        '├── b.txt\n'
        '└── c\n'
        '\n'
        '2 directories, 2 files\n',
      );
    });

    test('defaults to the current directory', () async {
      final r = await run('cd /t/a && tree');
      expect(r.stdout, '.\n└── nested.txt\n\n0 directories, 1 file\n');
    });

    test('-L limits the descent depth (separate and combined forms)', () async {
      final shallow = await run('tree -L 1 /t');
      expect(
        shallow.stdout,
        '/t\n├── a\n├── b.txt\n└── c\n\n2 directories, 1 file\n',
      );
      final combined = await run('tree -L2 /t');
      expect(combined.stdout, contains('nested.txt'));
    });

    test('hides dotfiles unless -a is given', () async {
      await run('echo secret > /t/.hidden');
      var r = await run('tree /t');
      expect(r.stdout, isNot(contains('.hidden')));
      expect(r.stdout, contains('2 directories, 2 files'));
      r = await run('tree -a /t');
      expect(r.stdout, contains('├── .hidden\n'));
      expect(r.stdout, contains('2 directories, 3 files'));
    });

    test('a file operand prints itself', () async {
      final r = await run('tree /t/b.txt');
      expect(r.stdout, '/t/b.txt\n\n0 directories, 1 file\n');
    });

    test('missing path exits 1, bad usage exits 2', () async {
      var r = await run('tree /nope');
      expect(r.exitCode, 1);
      expect(r.stderr, contains('tree: /nope: No such file or directory'));
      r = await run('tree -L x /t');
      expect(r.exitCode, 2);
      expect(r.stderr, contains('tree: Invalid level'));
      r = await run('tree -Z /t');
      expect(r.exitCode, 2);
      r = await run('tree /t /t');
      expect(r.exitCode, 2);
    });
  });

  group('file', () {
    test('detects the sandbox binary formats by magic bytes', () async {
      await writeBytes('/x.wasm', [0x00, 0x61, 0x73, 0x6d, 0x01, 0, 0, 0]);
      await writeBytes('/x.zip', [0x50, 0x4b, 0x03, 0x04, 0x14, 0x00]);
      await writeBytes('/x.gz', [0x1f, 0x8b, 0x08, 0x00]);
      await writeBytes('/x.xz', [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]);
      await writeBytes('/x.bz2', 'BZh9'.codeUnits);
      await writeBytes('/x.png', [
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
      ]);
      await writeBytes('/x.jpg', [0xff, 0xd8, 0xff, 0xe0]);
      await writeBytes('/x.gif', 'GIF89a'.codeUnits);
      await writeBytes('/x.webp', [
        ...'RIFF'.codeUnits,
        0,
        0,
        0,
        0,
        ...'WEBP'.codeUnits,
      ]);
      await writeBytes('/x.pdf', '%PDF-1.7'.codeUnits);
      await writeBytes('/x.db', 'SQLite format 3\x00'.codeUnits);
      final tar = List<int>.filled(512, 0)
        ..setRange(257, 262, 'ustar'.codeUnits);
      await writeBytes('/x.tar', tar);
      await writeBytes('/x.elf', [0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01]);
      await writeBytes('/x.macho', [0xfe, 0xed, 0xfa, 0xcf]);
      await writeBytes('/x.bin', [0x00, 0x01, 0x02, 0x03]);

      final r = await run(
        'file /x.wasm /x.zip /x.gz /x.xz /x.bz2 /x.png /x.jpg /x.gif '
        '/x.webp /x.pdf /x.db /x.tar /x.elf /x.macho /x.bin',
      );
      expect(r.exitCode, 0, reason: r.stderr);
      expect(
        r.stdout,
        '/x.wasm: WebAssembly (wasm) binary module version 0x1 (MVP)\n'
        '/x.zip: Zip archive data\n'
        '/x.gz: gzip compressed data\n'
        '/x.xz: XZ compressed data\n'
        '/x.bz2: bzip2 compressed data, block size = 900k\n'
        '/x.png: PNG image data\n'
        '/x.jpg: JPEG image data\n'
        '/x.gif: GIF image data, version 89a\n'
        '/x.webp: RIFF (little-endian) data, Web/P image\n'
        '/x.pdf: PDF document\n'
        '/x.db: SQLite 3.x database\n'
        '/x.tar: POSIX tar archive\n'
        '/x.elf: ELF 64-bit LSB executable\n'
        '/x.macho: Mach-O 64-bit executable\n'
        '/x.bin: data\n',
      );
    });

    test('classifies text and empty files, reports missing ones', () async {
      await run('echo plain ascii > /t.txt');
      await writeBytes('/utf8.txt', utf8.encode('héllo wörld\n'));
      await run('touch /blank');
      var r = await run('file /t.txt /utf8.txt /blank');
      expect(r.exitCode, 0, reason: r.stderr);
      expect(
        r.stdout,
        '/t.txt: ASCII text\n'
        '/utf8.txt: UTF-8 Unicode text\n'
        '/blank: empty\n',
      );

      r = await run('file /t.txt /nope');
      expect(r.exitCode, 1);
      expect(r.stdout, contains('/t.txt: ASCII text'));
      expect(
        r.stdout,
        contains("/nope: cannot open '/nope' (No such file or directory)"),
      );

      r = await run('file');
      expect(r.exitCode, 2);
    });
  });

  group('xz/bzip2 -d', () {
    final payload = 'hello compressed world\n' * 5;

    test('xz -d decodes to a sibling file and removes the original', () async {
      await writeBytes('/p.txt.xz', XZEncoder().encode(utf8.encode(payload)));
      final r = await run('xz -d /p.txt.xz');
      expect(r.exitCode, 0, reason: r.stderr);
      expect((await run('cat /p.txt')).stdout, payload);
      expect((await run('ls /')).stdout, isNot(contains('p.txt.xz')));
    });

    test('unxz alias, -k keeps the original, -c streams to stdout', () async {
      await writeBytes('/k.txt.xz', XZEncoder().encode(utf8.encode(payload)));
      var r = await run('unxz -k /k.txt.xz');
      expect(r.exitCode, 0, reason: r.stderr);
      expect((await run('ls /')).stdout, contains('k.txt.xz'));
      expect((await run('cat /k.txt')).stdout, payload);

      r = await run('xz -dc /k.txt.xz');
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, payload);

      // -c skips the suffix check.
      await run('cp /k.txt.xz /k.bin');
      r = await run('xz -dc /k.bin');
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, payload);
    });

    test('xz usage and format errors', () async {
      await run('echo not compressed > /g.xz');
      var r = await run('xz -d /g.xz');
      expect(r.exitCode, 1);
      expect(r.stderr, contains('xz: /g.xz: not in xz format'));

      r = await run('xz /g.xz');
      expect(r.exitCode, 2);
      expect(r.stderr, contains('compression is not supported'));

      r = await run('xz -d');
      expect(r.exitCode, 1);
      expect(r.stderr, contains('xz: missing operand'));

      r = await run('xz -d /missing.xz');
      expect(r.exitCode, 1);
      expect(r.stderr, contains('No such file or directory'));

      await run('cp /g.xz /g.bin');
      r = await run('xz -d /g.bin');
      expect(r.exitCode, 1);
      expect(r.stderr, contains('unknown suffix'));
    });

    test('bzip2 -d and bunzip2 round-trip through package:archive', () async {
      await writeBytes(
        '/b.txt.bz2',
        BZip2Encoder().encode(utf8.encode(payload)),
      );
      var r = await run('bzip2 -d /b.txt.bz2');
      expect(r.exitCode, 0, reason: r.stderr);
      expect((await run('cat /b.txt')).stdout, payload);

      await writeBytes(
        '/b2.txt.bz2',
        BZip2Encoder().encode(utf8.encode(payload)),
      );
      r = await run('bunzip2 /b2.txt.bz2');
      expect(r.exitCode, 0, reason: r.stderr);
      expect((await run('cat /b2.txt')).stdout, payload);
      expect((await run('ls /')).stdout, isNot(contains('b2.txt.bz2')));

      await run('echo junk > /j.bz2');
      r = await run('bzip2 -d /j.bz2');
      expect(r.exitCode, 1);
      expect(r.stderr, contains('bzip2: /j.bz2: not in bzip2 format'));

      await writeBytes(
        '/c.txt.bz2',
        BZip2Encoder().encode(utf8.encode(payload)),
      );
      r = await run('bzip2 -dc /c.txt.bz2');
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, payload);
    });
  });

  group('base64', () {
    test('encodes stdin and decodes with -d', () async {
      var r = await run("printf 'hello' | base64");
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, 'aGVsbG8=\n');

      r = await run("printf 'aGVsbG8=' | base64 -d");
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, 'hello');

      // Whitespace in the encoded input is tolerated.
      r = await run("printf 'aGVs\\nbG8=\\n' | base64 --decode");
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, 'hello');
    });

    test('wraps at 76 columns by default, -w 0 disables wrapping', () async {
      // 60 bytes encode to 80 base64 characters -> two lines at 76/4.
      await writeBytes('/sixty.bin', List<int>.filled(60, 0x61));
      var r = await run('base64 /sixty.bin');
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, '${'YWFh' * 19}\nYWFh\n');

      r = await run('base64 -w 0 /sixty.bin');
      expect(r.stdout, '${'YWFh' * 20}\n');

      await writeBytes('/bad.b64', utf8.encode('not base64 !!!\n'));
      r = await run('base64 -d /bad.b64');
      expect(r.exitCode, 1);
      expect(r.stderr, contains('base64: invalid input'));
    });

    test('round-trips a file through encode and decode', () async {
      await run('echo round trip > /rt.txt');
      var r = await run('base64 /rt.txt | base64 -d');
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, 'round trip\n');

      r = await run('base64 /missing');
      expect(r.exitCode, 1);
      expect(r.stderr, contains('No such file or directory'));

      r = await run('base64 /rt.txt /rt.txt');
      expect(r.exitCode, 2);
      expect(r.stderr, contains('extra operand'));
    });
  });

  group('md5sum/sha*sum', () {
    test('known vectors over stdin and files', () async {
      const vectors = {
        'md5sum': '900150983cd24fb0d6963f7d28e17f72',
        'sha1sum': 'a9993e364706816aba3e25717850c26c9cd0d89d',
        'sha224sum': '23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7',
        'sha256sum':
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        'sha384sum':
            'cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed'
            '8086072ba1e7cc2358baeca134c825a7',
        'sha512sum':
            'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a'
            '2192992a274fc1a836ba3c23a3feebbd'
            '454d4423643ce80e2a9ac94fa54ca49f',
      };
      for (final entry in vectors.entries) {
        final r = await run("printf 'abc' | ${entry.key}");
        expect(r.exitCode, 0, reason: '${entry.key}: ${r.stderr}');
        expect(r.stdout, '${entry.value}  -\n');
      }

      await run("printf 'abc' > /abc.txt");
      final r = await run('sha256sum /abc.txt');
      expect(r.stdout, '${vectors['sha256sum']}  /abc.txt\n');

      final empty = await run("printf '' | md5sum");
      expect(empty.stdout, 'd41d8cd98f00b204e9800998ecf8427e  -\n');
    });

    test('multiple operands, missing files, and usage errors', () async {
      await run("printf 'abc' > /a.txt && printf 'abc' > /b.txt");
      var r = await run('md5sum /a.txt /b.txt');
      expect(r.exitCode, 0, reason: r.stderr);
      expect(
        r.stdout,
        '900150983cd24fb0d6963f7d28e17f72  /a.txt\n'
        '900150983cd24fb0d6963f7d28e17f72  /b.txt\n',
      );

      r = await run('md5sum /a.txt /nope');
      expect(r.exitCode, 1);
      expect(r.stdout, contains('900150983cd24fb0d6963f7d28e17f72  /a.txt'));
      expect(r.stderr, contains('md5sum: /nope: No such file or directory'));

      r = await run('sha256sum -z');
      expect(r.exitCode, 2);
    });
  });
}
