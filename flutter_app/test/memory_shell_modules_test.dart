// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Per-utility behavior tables for the memory_shell modules: the real
// coreutils man-page fixtures as table rows. Pure Dart - zero platform
// channels.

import 'package:fa/sandbox/memory_shell/awk.dart';
import 'package:fa/sandbox/memory_shell/grep.dart';
import 'package:fa/sandbox/memory_shell/interpreters.dart';
import 'package:fa/sandbox/memory_shell/pipeline.dart';
import 'package:fa/sandbox/shell_parser.dart';
import 'package:fa/sandbox/memory_shell/paths.dart';
import 'package:fa/sandbox/memory_shell/sed.dart';
import 'package:fa/sandbox/memory_shell/tar.dart';
import 'package:fa/sandbox/memory_shell/test_expr.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [TestFs] over an in-memory [MemoryFileSystem], resolving against `/`.
final class _TableFs implements TestFs {
  final MemoryFileSystem fs = MemoryFileSystem();

  @override
  Future<bool> exists(String path) async =>
      (await fs.exists(resolveSandboxPath(path, '/'))).valueOrNull ?? false;

  @override
  Future<FileInfo?> fileInfo(String path) async =>
      (await fs.fileInfo(resolveSandboxPath(path, '/'))).valueOrNull;
}

void main() {

  group('snippetOutcome (issue #568)', () {
    test('unavailable interpreters answer 127 with the not-found line', () {
      final out = snippetOutcome(
        'python3',
        (available: false, stdout: 'ignored', stderr: 'also ignored'),
      );
      expect(
        out,
        (stdout: '', stderr: 'python3: command not found\n', exitCode: 127),
      );
    });

    test('empty output stays empty and exits 0', () {
      expect(
        snippetOutcome('qjs', (available: true, stdout: '', stderr: '')),
        (stdout: '', stderr: '', exitCode: 0),
      );
    });

    test('non-empty stdout gains the terminal newline', () {
      expect(
        snippetOutcome('qjs', (available: true, stdout: 'hello', stderr: '')),
        (stdout: 'hello\n', stderr: '', exitCode: 0),
      );
      expect(
        snippetOutcome('qjs', (available: true, stdout: 'hello\n', stderr: '')),
        (stdout: 'hello\n\n', stderr: '', exitCode: 0),
        reason: 'frozen behavior: the terminator is appended unconditionally',
      );
    });

    test('non-empty stderr forces exit 1 and gains the newline', () {
      expect(
        snippetOutcome(
          'python3',
          (available: true, stdout: 'partial', stderr: 'Traceback'),
        ),
        (stdout: 'partial\n', stderr: 'Traceback\n', exitCode: 1),
      );
      expect(
        snippetOutcome('python3', (available: true, stdout: '', stderr: 'boom')),
        (stdout: '', stderr: 'boom\n', exitCode: 1),
      );
    });
  });

  group('sed', () {
    Future<String> sedRow(
      String script,
      String input, {
      bool quiet = false,
    }) async => runSed(input, [SedCommand.tryParse(script)!], quiet: quiet);

    test('s/old/new/ replaces the first match per line', () async {
      expect(await sedRow('s/a/X/', 'banana'), 'bXnana\n');
    });

    test('s/old/new/g replaces every match', () async {
      expect(await sedRow('s/a/X/g', 'banana'), 'bXnXnX\n');
    });

    test('s/// can delete matches (empty replacement)', () async {
      expect(await sedRow('s/an//g', 'banana'), 'ba\n');
    });

    test('unmatched lines pass through unchanged (auto-print)', () async {
      expect(await sedRow('s/z/X/g', 'one\ntwo\n'), 'one\ntwo\n');
    });

    test('-n with /re/p prints only matching lines', () async {
      expect(await sedRow('/two/p', 'one\ntwo\nthree\n', quiet: true), 'two\n');
    });

    test(r'$ addresses the last line', () async {
      expect(await sedRow(r'$s/3/three/', '1\n2\n3\n'), '1\n2\nthree\n');
    });

    test('numeric address selects one line', () async {
      expect(await sedRow('2s/./X/', 'a\nb\nc\n'), 'a\nX\nc\n');
    });

    test('address range substitutes across the span', () async {
      expect(await sedRow('1,2s/^/> /', 'a\nb\nc\n'), '> a\n> b\nc\n');
    });

    test('empty input yields empty output', () async {
      expect(await sedRow('s/a/X/', ''), '');
    });

    test('parse: missing script is a usage error', () {
      expect(parseSedArgs([]).error, isNotNull);
      expect(parseSedArgs(['-n']).error, isNotNull);
    });

    test('parse: -i without files is an error', () {
      expect(parseSedArgs(['-i', 's/a/b/']).error, isNotNull);
      expect(parseSedArgs(['-i', 's/a/b/', 'f.txt']).error, isNull);
    });
  });

  group('awk', () {
    String awkRow(String program, String input, {String? fieldSeparator}) {
      final parsed = parseAwkProgram(program);
      expect(parsed.error, isNull, reason: program);
      return runAwk(input, parsed.pattern, parsed.printExpr, fieldSeparator);
    }

    test('/pattern/ without action prints the whole record', () {
      expect(awkRow('/b/', 'apple\nbanana\ncherry\n'), 'banana\n');
    });

    test(r'{print $1} prints the first field', () {
      expect(awkRow(r'{print $1}', 'a b\nc d\n'), 'a\nc\n');
    });

    test(r'{print $1, $3} joins fields with a space (OFS)', () {
      expect(awkRow(r'{print $1, $3}', 'a b c d\n'), 'a c\n');
    });

    test(r'{print NF, NR} exposes field count and record number', () {
      expect(awkRow(r'{print NF, NR}', 'x y\nz\n'), '2 1\n1 2\n');
    });

    test(r'{print $0} prints the whole line', () {
      expect(awkRow(r'{print $0}', 'hello\n'), 'hello\n');
    });

    test(r'-F overrides the field separator', () {
      expect(awkRow(r'{print $2}', 'a:b:c\n', fieldSeparator: ':'), 'b\n');
    });

    test('pattern and action compose', () {
      expect(awkRow(r'/^e/{print $2}', 'a b\nec d\n'), 'd\n');
    });

    test('parse: bad regex pattern is an error', () {
      expect(parseAwkProgram(r'/[unclosed/{print $1}').error, isNotNull);
    });

    test('parse: unsupported action body is an error', () {
      expect(parseAwkProgram(r'{print}').error, isNull);
      expect(parseAwkProgram(r'{delete $1}').error, isNotNull);
    });

    test('parse: missing program is a usage error', () {
      expect(parseAwkArgs([]).error, isNotNull);
    });
  });

  group('tar/gzip/zip', () {
    late MemoryFileSystem fs;

    setUp(() => fs = MemoryFileSystem());

    test('parse: no operation, both c/x, missing -f arg, no archive', () {
      expect(parseTarArgs([]).error, isNotNull);
      expect(parseTarArgs(['-c', '-x', 'f', 'a.tar']).error, isNotNull);
      expect(parseTarArgs(['cf']).error, isNotNull);
      expect(parseTarArgs(['c', 'a.bin']).error, isNotNull);
      expect(parseTarArgs(['-cf', 'a.tar', 'x.txt']).error, isNull);
      expect(parseTarArgs(['cf', 'a.tar', 'x.txt']).error, isNull);
    });

    test('tar czf/tar xzf round-trips files and directories', () async {
      await fs.writeFile('/a.txt', 'alpha');
      await fs.createDir('/sub');
      await fs.writeFile('/sub/b.txt', 'beta');
      final parsed = parseTarArgs(['-czf', '/a.tar.gz', 'a.txt', 'sub']);
      expect(parsed.error, isNull);
      expect(await createTarArchive(fs, '/', parsed), isNull);

      await fs.remove('/a.txt');
      await fs.remove('/sub/b.txt');
      final restore = parseTarArgs(['-xzf', '/a.tar.gz', '-C', '/']);
      expect(restore.error, isNull);
      expect(await extractTarArchive(fs, '/', restore), isNull);
      expect((await fs.readTextFile('/a.txt')).valueOrNull, 'alpha');
      expect((await fs.readTextFile('/sub/b.txt')).valueOrNull, 'beta');
    });

    test('tar x on a missing archive reports Cannot open', () async {
      final parsed = parseTarArgs(['-xf', '/nope.tar']);
      final err = await extractTarArchive(fs, '/', parsed);
      expect(err, isNotNull);
      expect(
        err!.message,
        'tar: /nope.tar: Cannot open: No such file or directory\n',
      );
    });

    test('gzip keeps the original unless -k says keep', () async {
      await fs.writeFile('/f.txt', 'payload');
      final compress = parseGzipArgs(['/f.txt'], decompress: false);
      expect(await runGzip(fs, '/', compress), isNull);
      expect((await fs.exists('/f.txt')).valueOrNull, isFalse);
      expect((await fs.exists('/f.txt.gz')).valueOrNull, isTrue);

      // Without -k gunzip also removes the .gz.
      final decompress = parseGzipArgs(['/f.txt.gz'], decompress: true);
      expect(await runGzip(fs, '/', decompress), isNull);
      expect((await fs.readTextFile('/f.txt')).valueOrNull, 'payload');
      expect((await fs.exists('/f.txt.gz')).valueOrNull, isFalse);
    });

    test('gzip -k keeps both sides on compress and decompress', () async {
      await fs.writeFile('/k.txt', 'kept');
      expect(
        await runGzip(
          fs,
          '/',
          parseGzipArgs(['-k', '/k.txt'], decompress: false),
        ),
        isNull,
      );
      expect((await fs.exists('/k.txt')).valueOrNull, isTrue);
      expect(
        await runGzip(
          fs,
          '/',
          parseGzipArgs(['-k', '/k.txt.gz'], decompress: true),
        ),
        isNull,
      );
      expect((await fs.exists('/k.txt.gz')).valueOrNull, isTrue);
    });

    test(
      'gzip on a non-gzip suffix fails with the ignored-suffix error',
      () async {
        await fs.writeFile('/plain.txt', 'data');
        final err = await runGzip(
          fs,
          '/',
          parseGzipArgs(['/plain.txt'], decompress: true),
        );
        expect(err!.message, 'gzip: /plain.txt: unknown suffix -- ignored\n');
      },
    );

    test('zip round-trips and refuses directories without -r', () async {
      await fs.writeFile('/x.txt', 'ex');
      expect(
        await runZip(fs, '/', parseZipArgs(['/out.zip', '/x.txt'])),
        isNull,
      );
      expect((await fs.exists('/out.zip')).valueOrNull, isTrue);

      await fs.createDir('/dir');
      final err = await runZip(fs, '/', parseZipArgs(['/o2.zip', '/dir']));
      expect(err!.message, contains('use -r'));
    });

    test('zip usage errors: fewer than two positionals', () {
      expect(parseZipArgs(['only.zip']).error, isNotNull);
    });
  });

  group('grep', () {
    final plain = <String>{};
    final query = compileGrepQuery(plain, 'an').query!;

    test('basic match filters lines', () {
      final acc = GrepAccumulator();
      grepText('banana\ncherry\n', null, query, acc);
      expect(acc.buffer.toString(), 'banana\n');
      expect(acc.anyMatch, isTrue);
    });

    test('-v inverts the match', () {
      final q = compileGrepQuery({'v'}, 'an').query!;
      final acc = GrepAccumulator();
      grepText('banana\ncherry\n', null, q, acc);
      expect(acc.buffer.toString(), 'cherry\n');
    });

    test('-c counts instead of printing', () {
      final q = compileGrepQuery({'c'}, 'a').query!;
      final acc = GrepAccumulator();
      grepText('aa\nba\nca\n', null, q, acc);
      expect(acc.buffer.toString(), '3\n');
    });

    test('-n prefixes line numbers', () {
      final q = compileGrepQuery({'n'}, 'b').query!;
      final acc = GrepAccumulator();
      grepText('a\nb\nc\n', null, q, acc);
      expect(acc.buffer.toString(), '2:b\n');
    });

    test('-i matches case-insensitively', () {
      final q = compileGrepQuery({'i'}, 'BANANA').query!;
      final acc = GrepAccumulator();
      grepText('BaNaNa\nx\n', null, q, acc);
      expect(acc.buffer.toString(), 'BaNaNa\n');
    });

    test('-E enables extended regex alternation', () {
      final q = compileGrepQuery({'E'}, 'cat|dog').query!;
      final acc = GrepAccumulator();
      grepText('cat\ncow\ndog\n', null, q, acc);
      expect(acc.buffer.toString(), 'cat\ndog\n');
    });

    test('-F treats the pattern as a literal string', () {
      final q = compileGrepQuery({'F'}, 'a.c').query!;
      final acc = GrepAccumulator();
      grepText('a.c\nabc\n', null, q, acc);
      expect(acc.buffer.toString(), 'a.c\n');
    });

    test('-l prints the file label once on match', () {
      final q = compileGrepQuery({'l'}, 'an').query!;
      final acc = GrepAccumulator();
      grepText('banana\nbandana\n', 'f.txt', q, acc);
      expect(acc.buffer.toString(), 'f.txt\n');
    });

    test('multiple files get per-file labels', () {
      final acc = GrepAccumulator();
      grepText('an\n', 'one.txt', query, acc);
      grepText('no\n', 'two.txt', query, acc);
      expect(acc.buffer.toString(), 'one.txt:an\n');
    });

    test('parse: missing pattern and -e without value are errors', () {
      expect(parseGrepArgs([]).error, isNotNull);
      expect(parseGrepArgs(['-e']).error, isNotNull);
      expect(parseGrepArgs(['-e', 'p', 'f.txt']).error, isNull);
    });

    test('compile: invalid regex is an error', () {
      expect(compileGrepQuery(const <String>{}, '([)').error, isNotNull);
    });
  });

  group('test/[', () {
    late _TableFs tableFs;

    setUp(() => tableFs = _TableFs());

    Future<bool> evalRow(List<String> args) => evalTestExpr(args, tableFs);

    test('-e detects anything, missing paths are false', () async {
      expect(await evalRow(['-e', '/']), isTrue);
      expect(await evalRow(['-e', '/nope']), isFalse);
    });

    test('-f and -d distinguish files from directories', () async {
      await tableFs.fs.writeFile('/file.txt', 'x');
      await tableFs.fs.createDir('/dir');
      expect(await evalRow(['-f', '/file.txt']), isTrue);
      expect(await evalRow(['-d', '/file.txt']), isFalse);
      expect(await evalRow(['-d', '/dir']), isTrue);
      expect(await evalRow(['-f', '/dir']), isFalse);
    });

    test('-s is true only for non-empty files', () async {
      await tableFs.fs.writeFile('/empty.txt', '');
      await tableFs.fs.writeFile('/full.txt', 'x');
      expect(await evalRow(['-s', '/empty.txt']), isFalse);
      expect(await evalRow(['-s', '/full.txt']), isTrue);
    });

    test('-z and -n test string emptiness', () async {
      expect(await evalRow(['-z', '']), isTrue);
      expect(await evalRow(['-z', 'x']), isFalse);
      expect(await evalRow(['-n', 'x']), isTrue);
      expect(await evalRow(['-n', '']), isFalse);
    });

    test('= == != compare strings', () async {
      expect(await evalRow(['a', '=', 'a']), isTrue);
      expect(await evalRow(['a', '==', 'a']), isTrue);
      expect(await evalRow(['a', '!=', 'b']), isTrue);
      expect(await evalRow(['a', '=', 'b']), isFalse);
    });

    test('-eq/-ne/-lt/-le/-gt/-ge compare integers', () async {
      expect(await evalRow(['1', '-eq', '1']), isTrue);
      expect(await evalRow(['1', '-ne', '2']), isTrue);
      expect(await evalRow(['1', '-lt', '2']), isTrue);
      expect(await evalRow(['2', '-le', '2']), isTrue);
      expect(await evalRow(['3', '-gt', '2']), isTrue);
      expect(await evalRow(['2', '-ge', '2']), isTrue);
      expect(await evalRow(['3', '-lt', '2']), isFalse);
    });

    test('! negates the predicate', () async {
      expect(await evalRow(['!', '-e', '/']), isFalse);
      expect(await evalRow(['!', '-e', '/nope']), isTrue);
    });

    test('a bare non-empty string is truthy', () async {
      expect(await evalRow(['x']), isTrue);
      expect(await evalRow(['']), isFalse);
    });

    test('too many arguments throw FormatException', () {
      expect(
        () => evalRow(['a', '=', 'b', 'c']),
        throwsA(isA<FormatException>()),
      );
    });

    test('unknown operators throw', () {
      expect(() => evalRow(['a', '<', 'b']), throwsA(isA<FormatException>()));
      expect(() => evalRow(['-w', '/x']), throwsA(isA<FormatException>()));
    });
  });

  group('paths', () {
    test('normalize collapses . and .. and returns absolute paths', () {
      expect(normalizeSandboxPath('/a/./b'), '/a/b');
      expect(normalizeSandboxPath('/a/b/../c'), '/a/c');
      expect(normalizeSandboxPath('a/b'), '/a/b');
      expect(normalizeSandboxPath('/'), '/');
      expect(normalizeSandboxPath('/..'), '/');
    });

    test('resolve joins relative paths onto cwd', () {
      expect(resolveSandboxPath('x.txt', '/work'), '/work/x.txt');
      expect(resolveSandboxPath('/abs.txt', '/work'), '/abs.txt');
      expect(resolveSandboxPath('../up', '/work/deep'), '/work/up');
    });

    test('splitArgs separates flags, -- terminator, and lone dash', () {
      final split = splitArgs(['-n', '--', '-x', '-', 'f.txt']);
      expect(split.flags, ['-n']);
      expect(split.paths, ['-x', '-', 'f.txt']);
    });

    test('readCommandInput concatenates files, stdin, and dash', () async {
      final fs = MemoryFileSystem();
      await fs.writeFile('/a', 'one');
      await fs.writeFile('/b', 'two');
      final out = await readCommandInput(
        fs,
        '/',
        ['/a', '-', '/b'],
        'STDIN',
        (path) => fail('unexpected error path: $path'),
      );
      expect(out, 'oneSTDINtwo');
    });

    test(
      'readCommandInput defaults to stdin and reports missing files',
      () async {
        final fs = MemoryFileSystem();
        expect(
          await readCommandInput(fs, '/', [], null, (path) => fail(path)),
          '',
        );
        expect(
          await readCommandInput(fs, '/', [], 's', (path) => fail(path)),
          's',
        );
        String? reported;
        final out = await readCommandInput(
          fs,
          '/',
          ['/missing'],
          null,
          (path) => reported = path,
        );
        expect(out, isNull);
        expect(reported, '/missing');
      },
    );
  });

  group('pipeline redirects', () {
    Redirect redirect(int fd, RedirectKind kind, String target) =>
        Redirect(fd: fd, kind: kind, target: target);

    test('classifies > >> 2> 2>> and <', () {
      final r = parseStageRedirects([
        redirect(0, RedirectKind.read, '/in'),
        redirect(1, RedirectKind.write, '/out'),
        redirect(2, RedirectKind.append, '/err'),
      ]);
      expect(r.stdinFile, '/in');
      expect(r.stdoutFile, '/out');
      expect(r.appendStdout, isFalse);
      expect(r.stderrFile, '/err');
      expect(r.appendStderr, isTrue);
    });

    test('append writes flag stdout and stderr independently', () {
      final r = parseStageRedirects([redirect(1, RedirectKind.append, '/log')]);
      expect(r.stdoutFile, '/log');
      expect(r.appendStdout, isTrue);
      expect(r.stderrFile, isNull);
    });

    test('empty redirects produce an empty record', () {
      final r = parseStageRedirects(const []);
      expect(r.stdinFile, isNull);
      expect(r.stdoutFile, isNull);
      expect(r.stderrFile, isNull);
    });
  });

  group('interpreters', () {
    test(
      'sqlite usage errors surface before interpreter availability',
      () async {
        final fs = MemoryFileSystem();
        final noDb = await runSqliteCommand(fs, '/', [], null);
        expect(noDb.exitCode, 127);
        expect(noDb.stderr, 'sqlite3: command not found\n');

        final badOpt = await runSqliteCommand(fs, '/', ['-bogus'], null);
        expect(badOpt.exitCode, 1);
        expect(badOpt.stderr, 'sqlite3: unsupported option -bogus\n');

        // The db file is read (or missed) before the engine short-circuits.
        await fs.writeFile('/data.sqlite', 'stub');
        final withDb = await runSqliteCommand(fs, '/', [
          '/data.sqlite',
          'SELECT 1;',
        ], null);
        expect(withDb.exitCode, 127);
        final missingDb = await runSqliteCommand(fs, '/', [
          '/nope.sqlite',
          'SELECT 1;',
        ], null);
        expect(missingDb.exitCode, 127);

        // --version short-circuits the arg loop: still unavailable in the VM.
        final version = await runSqliteCommand(fs, '/', ['--version'], null);
        expect(version.exitCode, 127);
        expect(version.stderr, 'sqlite3: command not found\n');
      },
    );

    test('parseSqliteArgs: -version flag order does not swallow options', () {
      final parsed = parseSqliteArgs(['--version', '-bogus'], stdin: null);
      expect(parsed.wantVersion, isTrue);
      expect(parsed.error, isNull);
      expect(parsed.dbPath, isNull);
    });

    test('parseSqliteArgs: db path and sql positional split', () {
      final parsed = parseSqliteArgs([
        '/db.sqlite',
        'SELECT',
        '1;',
      ], stdin: null);
      expect(parsed.dbPath, '/db.sqlite');
      expect(parsed.sql, 'SELECT 1;');
    });

    test('parseSqliteArgs: stdin fills in missing sql', () {
      final parsed = parseSqliteArgs(['/db.sqlite'], stdin: 'SELECT 2;');
      expect(parsed.sql, 'SELECT 2;');
    });

    test('python/qjs usage errors do not touch interpreters', () async {
      final fs = MemoryFileSystem();
      final py = await runPythonCommand(fs, '/', []);
      expect(py.exitCode, 2);
      expect(py.stderr, contains('usage: python3'));

      final js = await runQjsCommand(fs, '/', []);
      expect(js.exitCode, 2);
      expect(js.stderr, contains('usage: qjs'));
    });

    test(
      'interpreterCode reads inline flag first, then script files',
      () async {
        final fs = MemoryFileSystem();
        await fs.writeFile('/s.py', 'print(1)');
        expect(
          await interpreterCode(fs, '/', ['-c', 'print(2)'], flag: '-c'),
          'print(2)',
        );
        expect(
          await interpreterCode(fs, '/', ['/s.py'], flag: '-c'),
          'print(1)',
        );
        expect(await interpreterCode(fs, '/', [], flag: '-c'), isNull);
      },
    );
  });
}
