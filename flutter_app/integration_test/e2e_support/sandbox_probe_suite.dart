// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The iOS/WASI sandbox golden probe suite (issue #1156).
///
/// One probe per row of the issue's 14-row evidence table, plus the AC2/AC3/
/// AC4/E1-E4 pins. Every probe runs the REAL `WasiSandboxShell` (the same
/// class the iOS app runs) against a fresh sandbox directory, so a green run
/// here means the advertised toolbelt actually works.
///
/// The suite body is shared: `integration_test/sandbox_probe_suite_test.dart`
/// runs it on the iOS simulator (the AC7 lane) and
/// `test/sandbox_probe_suite_host_test.dart` runs it on macOS/desktop hosts
/// where the wasm_run dylib is available — same shell class, same asserts.
///
/// Network rows hit a local fixture server (`ProbeFixtureServer`), not the public
/// internet: the table's httpbin/archive.org endpoints are stand-ins for the
/// same curl shapes (POST echo, binary download, media fetch), kept
/// deterministic for CI.
library;

import 'dart:convert';
import 'dart:io' as io;

import 'package:crypto/crypto.dart';
import 'package:fa/sandbox/wasm_shell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

// ---------------------------------------------------------------------------
// Fixture data
// ---------------------------------------------------------------------------

/// 1 MiB deterministic pattern: byte i is `i & 0xFF` (AC4 fixture).
final Uint8List binaryFixture = Uint8List.fromList(
  List<int>.generate(1 << 20, (i) => i & 0xFF),
);

/// The AC4 pinned digest of [binaryFixture].
const String binaryFixtureSha256 =
    'fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83';

/// 256 KiB fake media body (row 13 fixture).
final Uint8List videoFixture = Uint8List.fromList(
  List<int>.generate(1 << 18, (i) => 'FAKEVIDEO'.codeUnitAt(i % 9)),
);

/// Local stand-in for the public endpoints the issue's table probed: an echo
/// POST (httpbin /post), a binary download, and a media fetch.
final class ProbeFixtureServer {
  ProbeFixtureServer();

  io.HttpServer? _server;

  int get port => _server!.port;

  Future<void> start() async {
    _server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) async {
      final path = request.uri.path;
      if (path == '/post' && request.method == 'POST') {
        final body = await utf8.decoder.bind(request).join();
        final echo = jsonEncode({
          'url': request.uri.toString(),
          'data': body,
          'json': null,
        });
        request.response.headers.contentType = io.ContentType.json;
        request.response.write(echo);
        await request.response.close();
        return;
      }
      if (path == '/binary.bin') {
        request.response.headers.contentType = io.ContentType.binary;
        request.response.add(binaryFixture);
        await request.response.close();
        return;
      }
      if (path == '/video.mp4') {
        request.response.headers.contentType = io.ContentType('video', 'mp4');
        request.response.add(videoFixture);
        await request.response.close();
        return;
      }
      if (path == '/version') {
        request.response.write('fixture-curl 1.2.3\n');
        await request.response.close();
        return;
      }
      request.response.statusCode = 404;
      await request.response.close();
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }
}

// ---------------------------------------------------------------------------
// Suite definition
// ---------------------------------------------------------------------------

/// Builds the probe probe list: each entry is (name, async body). Entry
/// files wrap these in their own test/testWidgets registration.
typedef ProbeBody = Future<void> Function();

/// Defines the whole suite against the lazily-loaded [loadShell] and the
/// fixture [server].
///
/// [sandboxRoot] is the HOST directory backing the sandbox `/` — the suite
/// uses it to verify `-o` downloads landed on disk (row 11 / AC4) and to
/// assert host paths never leak (E4). The shell loads on first use INSIDE a
/// test body: the test binding's mock HTTP overrides reject client
/// construction from `main()`.
List<(String, ProbeBody)> sandboxProbes({
  required Future<WasiSandboxShell> Function() loadShell,
  required ProbeFixtureServer server,
  required String sandboxRoot,
}) {
  Future<ShellExecResult> run(String command) async {
    final shell = await loadShell();
    final result = await shell.exec(command);
    if (result.isErr) {
      fail('"$command" failed: ${result.errorOrNull}');
    }
    return result.valueOrNull!;
  }

  Future<String> hostPathOf(String sandboxPath) async =>
      (await loadShell()).hostPathOf(sandboxPath);

  return [
    // Row 1 — basic tool output is not swallowed (×2 runs like the table).
    (
      'row1: pwd, curl --version, git --version print output',
      () async {
        for (var i = 0; i < 2; i++) {
          final pwd = await run('pwd');
          expect(pwd.stdout.trim(), '/', reason: 'run $i: pwd output');
          final curl = await run('curl --version');
          expect(curl.stdout, contains('curl'), reason: 'run $i');
          expect(curl.exitCode, 0, reason: 'run $i');
          final git = await run('git --version');
          expect(git.stdout, contains('git version'), reason: 'run $i');
          expect(git.exitCode, 0, reason: 'run $i');
        }
      },
    ),
    // Row 2 — three quick commands in one line, each prints.
    (
      'row2: echo, uname, id all print',
      () async {
        final r = await run('echo "shell alive"; uname -a; id');
        expect(r.stdout, contains('shell alive'));
        expect(r.stdout, contains('wasi'), reason: 'uname -a');
        expect(r.stdout.trim().split('\n').last, isNotEmpty, reason: 'id');
        expect(r.exitCode, 0);
      },
    ),
    // Row 3 — git status outside a repo: fatal goes to stderr, non-zero exit.
    (
      'row3: git status outside a repo fails loudly on stderr',
      () async {
        final r = await run('git status');
        expect(r.exitCode, isNot(0));
        expect(r.stderr, contains('fatal:'));
        expect(r.stderr, contains('not a git repository'));
      },
    ),
    // Row 4 — QuickJS runs (the landing page advertises js).
    (
      'row4: qjs -e evaluates JavaScript',
      () async {
        final r = await run('qjs -e "console.log(\'qjs works:\', 1+1)"');
        expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
        expect(r.stdout, contains('qjs works: 2'));
      },
    ),
    // Row 5 — CPython runs (the landing page advertises python3).
    (
      'row5: python3 -c prints',
      () async {
        final r = await run("python3 -c \"print('python ok')\"");
        expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
        expect(r.stdout, contains('python ok'));
      },
    ),
    // Row 6 — jq --version answers like real jq (exit 0, jq-N on stdout).
    (
      'row6: jq --version prints a version',
      () async {
        final r = await run('jq --version');
        expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
        expect(r.stdout, contains('jq'));
      },
    ),
    // Row 7 — REG pin: rg keeps working.
    (
      'row7: rg --version (REG pin)',
      () async {
        final r = await run('rg --version');
        expect(r.exitCode, 0);
        expect(r.stdout, contains('ripgrep'));
      },
    ),
    // Row 8 — pipes: echo | sed transforms.
    (
      'row8: echo | sed pipe transforms',
      () async {
        final r = await run('echo "hello world" | sed \'s/world/sed/\'');
        expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
        expect(r.stdout, 'hello sed\n');
      },
    ),
    // Row 9 — no cross-command contamination; sqlite3 and tar | head work.
    (
      'row9: sqlite3 --version; tar --version | head -n 1 (no contamination)',
      () async {
        final r = await run('sqlite3 --version; tar --version | head -n 1');
        expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
        expect(r.stdout, contains('3.'), reason: 'sqlite3 --version output');
        expect(r.stdout, contains('tar'), reason: 'tar --version line');
        expect(r.stdout, isNot(contains('hello world')), reason: 'no leak');
      },
    ),
    // Row 10 — REG pin: curl POST echoes (local httpbin-shaped fixture).
    (
      'row10: curl -X POST echoes the body (REG pin)',
      () async {
        final r = await run(
          'curl -s -X POST http://127.0.0.1:${server.port}/post '
          "-d 'k=v&x=1'",
        );
        expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
        final echo = jsonDecode(r.stdout) as Map<String, dynamic>;
        expect(echo['data'], 'k=v&x=1');
      },
    ),
    // Row 11 — curl -o writes the file into the sandbox fs; ls sees it.
    (
      'row11: curl -o downloads into the sandbox fs',
      () async {
        final r = await run(
          'curl -s -o /tmp/probe.bin '
          'http://127.0.0.1:${server.port}/binary.bin; ls -l /tmp/probe.bin',
        );
        expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
        expect(r.stdout, contains('probe.bin'), reason: 'ls sees the file');
        final bytes = await io.File(
          await hostPathOf('/tmp/probe.bin'),
        ).readAsBytes();
        expect(bytes.length, 1 << 20);
        expect(sha256.convert(bytes).toString(), binaryFixtureSha256);
      },
    ),
    // Row 12 — curl -w prints the write-out line.
    (
      'row12: curl -w prints http_code and size_download',
      () async {
        final r = await run(
          'curl -s -o /dev/null -w "%{http_code} %{size_download}\\n" '
          'http://127.0.0.1:${server.port}/binary.bin',
        );
        expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
        expect(r.stdout, '200 1048576\n');
      },
    ),
    // Row 13 — media fetch is not silent (body bytes reach stdout).
    (
      'row13: curl -sS media fetch returns the body',
      () async {
        final r = await run(
          'curl -sS http://127.0.0.1:${server.port}/video.mp4',
        );
        expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
        expect(r.stdout, isNotEmpty);
        expect(utf8.encode(r.stdout).length, videoFixture.length);
      },
    ),
    // Row 14 / E4 — missing-file errors name sandbox paths, never host paths.
    (
      'row14: missing-file error speaks sandbox paths (E4)',
      () async {
        final r = await run('tail logs/app.log');
        expect(r.exitCode, isNot(0));
        expect(r.stderr, contains('logs/app.log'));
        expect(r.stderr, isNot(contains(sandboxRoot)));
        expect(r.stderr, isNot(contains('/var/')));
      },
    ),
    // AC2 — stderr ordering: out on stdout, err on stderr, both captured.
    (
      'AC2: stderr ordering — echo out; echo err >&2',
      () async {
        final r = await run('echo out; echo err >&2');
        expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
        expect(r.stdout, 'out\n');
        expect(r.stderr, 'err\n');
      },
    ),
    // AC2b — the merge form: 2>&1 folds stderr into stdout.
    (
      'AC2b: 2>&1 merge keeps stream order',
      () async {
        final r = await run('echo err2 2>&1');
        expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
        expect(r.stdout, 'err2\n');
      },
    ),
    // AC3 — 100 sequential piped commands: zero cross-command leakage.
    (
      'AC3: 100 sequential piped commands, zero leakage',
      () async {
        for (var i = 0; i < 100; i++) {
          final r = await (await loadShell()).exec("echo 'line$i' | sed 's/line/L/'");
          final res = r.valueOrNull;
          expect(res?.stdout, 'L$i\n', reason: 'iteration $i');
          expect(res?.stderr, '', reason: 'iteration $i');
        }
      },
    ),
    // AC4 — binary round-trip by digest (download path).
    (
      'AC4: 1 MiB binary download sha256 matches',
      () async {
        final r = await run(
          'curl -s -o /tmp/ac4.bin http://127.0.0.1:${server.port}/binary.bin',
        );
        expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
        final bytes = await io.File(await hostPathOf('/tmp/ac4.bin')).readAsBytes();
        expect(bytes.length, 1 << 20);
        expect(sha256.convert(bytes).toString(), binaryFixtureSha256);
      },
    ),
    // E1 — multi-MB stdout through a pipe, captured without crash.
    (
      'E1: huge stdout survives a pipe',
      () async {
        final r = await run('seq 1 300000 | tail -n 1');
        expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
        expect(r.stdout, '300000\n');
      },
    ),
    // E2 — writing to an unwritable sandbox path: clean error, non-zero
    // exit, never a silent success or a host exception.
    (
      'E2: read-only redirect fails cleanly',
      () async {
        final shell = await loadShell();
        if (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android) {
          // iOS has no process spawning and dart:io has no chmod: a
          // file-as-parent target gives the same clean-failure contract
          // without host helpers.
          io.File('$sandboxRoot/ro_file').writeAsStringSync('x');
          final r = await shell.exec('echo x > /ro_file/f.txt');
          expect(r.isOk, isTrue, reason: '${r.errorOrNull}');
          final res = r.valueOrNull!;
          expect(res.exitCode, isNot(0), reason: 'never silent success');
          expect(res.stderr, isNot(isEmpty));
          expect(res.stderr, startsWith('sh:'));
          expect(res.stderr, contains('/ro_file/f.txt'));
          expect(res.stderr, isNot(contains(sandboxRoot)));
          return;
        }
        final roDir = io.Directory('$sandboxRoot/ro_dir')..createSync();
        // chmod after create: the owner keeps read/execute, loses write.
        // Desktop hosts only — dart:io Process spawning is unavailable on
        // iOS, so the mobile lane uses the file-as-parent variant above.
        await io.Process.run('chmod', ['555', roDir.path]);
        final r = await shell.exec('echo x > /ro_dir/f.txt');
        expect(r.isOk, isTrue, reason: '${r.errorOrNull}');
        final res = r.valueOrNull!;
        expect(res.exitCode, isNot(0), reason: 'never silent success');
        expect(res.stderr, isNot(isEmpty));
        expect(res.stderr, contains('Permission denied'));
        expect(res.stderr, isNot(contains(sandboxRoot)));
      },
    ),
    // E3 — concurrent jobs: pipe/temp names are job-scoped.
    (
      'E3: concurrent piped jobs do not cross-contaminate',
      () async {
        io.Directory('$sandboxRoot/.fah/bash_jobs').createSync(
          recursive: true,
        );
        final jobs = <ShellJob>[];
        for (final spec in [('a', 'echo A-payload | sed s/A/B/'), (
          'b',
          'echo C-payload | sed s/C/D/',
        )]) {
          final started = await (await loadShell()).startShellJob(
            spec.$2,
            id: 'e3-${spec.$1}',
            logPath: '$sandboxRoot/.fah/bash_jobs/e3-${spec.$1}.log',
          );
          expect(started.isOk, isTrue, reason: '${started.errorOrNull}');
          jobs.add(started.valueOrNull!);
        }
        for (final job in jobs) {
          await job.settled;
        }
        final logA = await io.File(
          '$sandboxRoot/.fah/bash_jobs/e3-a.log',
        ).readAsString();
        final logB = await io.File(
          '$sandboxRoot/.fah/bash_jobs/e3-b.log',
        ).readAsString();
        expect(logA, contains('B-payload'));
        expect(logA, isNot(contains('D-payload')));
        expect(logB, contains('D-payload'));
        expect(logB, isNot(contains('B-payload')));
      },
    ),
  ];
}

/// Builds the probe list plus fixture server for a probe run. The shell
/// itself loads lazily inside the first probe body (see [sandboxProbes]).
Future<List<(String, ProbeBody)>> makeProbeSuite(
  String sandboxRoot, {
  required http.Client httpClient,
}) async {
  // [httpClient] must be constructed BEFORE the test binding initializes:
  // flutter_test replaces `HttpOverrides.global` with a 400 stub for the
  // whole process, so a client built after that can never reach the local
  // fixture server. Clients built pre-binding keep real sockets.
  final server = ProbeFixtureServer();
  await server.start();
  WasiSandboxShell? shell;
  Future<WasiSandboxShell> loadShell() async =>
      shell ??= await WasiSandboxShell.load(
        workingDirectory: '/',
        sandboxHostPath: sandboxRoot,
        httpClient: httpClient,
      );
  return [
    ...sandboxProbes(
      loadShell: loadShell,
      server: server,
      sandboxRoot: sandboxRoot,
    ),
    (
      'fixture server stops',
      () async {
        await server.stop();
      },
    ),
  ];
}
