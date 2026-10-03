/// Double-press Ctrl+C contract (issue #830) over the real PTY.
///
/// ACX.1-ACX.3 spawn the TUI with `raw: false` so the kernel line
/// discipline keeps ISIG: the harness-written 0x03 becomes a SIGINT — the
/// exact path real terminal users hit (the TUI never sees ctrl+c as a key).
/// ACX.4 pins the headless `fa -p` SIGINT abort (no double-press window).
///
/// The 3 s press window is a contract constant (no user-facing config
/// knob). A PTY test cannot inject a clock into the spawned CLI, so
/// ACX.3 runs the window ladder against the `kSigintWindowEnvVar` TEST
/// seam instead (gh-1014): the window is widened far past every
/// test-side wait, making both crossings insensitive to runner-load
/// jitter — the wait past the window can only land later (always a fresh
/// press 1), and the presses inside the fresh window land seconds before
/// it closes. The in-process unit tests keep pinning the 3 s default.
@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 8))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/cli/sigint_action.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  group('double-press ctrl+c - SIGINT path (issue #830)', () {
    late Directory tempHome;

    setUp(() {
      tempHome = Directory.systemTemp.createTempSync('fa_ctrl_c_');
      File('${tempHome.path}/.fah/config.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
provider: openai-completions
model: test-model
baseUrl: http://localhost:9999/v1
mode: code
approvalMode: always-ask
allowedTools: []
tui:
  classic: true  # pins the classic chrome the press hints render in (band redesign #805-#807 has its own surface)
''');
    });

    tearDown(() {
      tempHome.deleteSync(recursive: true);
    });

    Future<FaCliHarness> spawnTui() => FaCliHarness.spawn(
      extraEnv: {'HOME': tempHome.path},
      columns: 120,
      // Kernel default termios: ISIG on, 0x03 delivers SIGINT.
      raw: false,
    );

    /// Whether the CLI process died within [d].
    Future<bool> exitedWithin(FaCliHarness harness, Duration d) async {
      try {
        await harness.pty.exitCode.timeout(d);
        return true;
      } on TimeoutException {
        return false;
      }
    }

    test(
      'ACX.1: press 1 aborts but stays - dim hint up, composer cleared',
      () async {
        final harness = await spawnTui();
        addTearDown(harness.close);
        await harness.waitForBoot();

        harness.sendText('draft text');
        await harness.waitForOutput(settleMs: 150);
        harness.sendCtrlC(); // SIGINT press 1

        // gh-1049: assert on the CAPTURED screen — a fresh screenText read
        // after the wait re-samples the screen mid-render.
        final screen = await harness.waitForScreen(
          'press ctrl+c again to exit',
        );
        expect(
          screen,
          isNot(contains('draft text')),
          reason: 'ctrl+c clear at an idle prompt',
        );
        expect(
          await exitedWithin(harness, const Duration(seconds: 2)),
          isFalse,
          reason: 'press 1 never exits (issue #830)',
        );
      },
    );

    test('ACX.2: press 2 within the window exits 130; a fresh session prints '
        'the honest nothing-to-resume line', () async {
      final harness = await spawnTui();
      addTearDown(harness.close);
      await harness.waitForBoot();

      harness.sendCtrlC(); // press 1: arm
      await harness.waitForScreen('press ctrl+c again to exit');
      harness.sendCtrlC(); // press 2: exit

      // A virgin session persists nothing, so the exit deletes the empty
      // session file — "resume this session with ..." would point at a
      // deleted file. The honest line is the contract for fresh runs
      // (issue #830 review); a non-empty session prints the resume hint.
      await harness.waitForText(kNothingToResumeHint);
      // The 130 exit code is pinned race-free by the headless pin (ACX.4,
      // Process.exitCode). Over the PTY, pty2 can lose the waitpid race and
      // report -1 for a clean 130 exit (same CI flake as
      // ssh_shift_gate_test.dart), so here the contract asserted is bounded
      // death: the process must be gone within the budget.
      const stillAlive = -999;
      final code = await harness.pty.exitCode.timeout(
        const Duration(seconds: 15),
        onTimeout: () => stillAlive,
      );
      expect(
        code,
        isNot(stillAlive),
        reason: 'press 2 must exit the REPL (issue #830); exit code $code',
      );
    });

    // gh-1014 fix: the ladder now runs against the widened
    // kSigintWindowEnvVar window (see the library comment) — unskipped.
    test('ACX.3: a press after the window is a fresh press 1', () async {
      // Widened window: the old real-clock 3 s ladder flaked under runner
      // load because the fresh-press side budget (output settle + the
      // no-exit probe) ate ~2.4 s of the 3 s fresh window — the final
      // press could land past it and silently became a fresh press 1
      // again (no exit → -999). At 12 s every wait below sits seconds
      // inside the fresh window, and the past-the-window wait can only
      // run late (timers never fire early), which is the safe direction.
      const testWindow = Duration(seconds: 12);
      final harness = await FaCliHarness.spawn(
        extraEnv: {
          'HOME': tempHome.path,
          kSigintWindowEnvVar: '${testWindow.inMilliseconds}',
        },
        columns: 120,
        // Kernel default termios: ISIG on, 0x03 delivers SIGINT.
        raw: false,
      );
      addTearDown(harness.close);
      await harness.waitForBoot();

      harness.sendCtrlC(); // press 1 at t=0
      await harness.waitForScreen('press ctrl+c again to exit');
      await Future<void>.delayed(testWindow + const Duration(seconds: 2));
      harness.sendCtrlC(); // past the window: fresh press 1, NOT an exit
      // Bounded settle: the default 10 s waitForOutput timeout could
      // itself outlive a short window; pinned to 5 s so the settle plus
      // the probe below stay inside the 12 s fresh window even when every
      // bound is hit.
      await harness.waitForOutput(
        settleMs: 200,
        timeout: const Duration(seconds: 5),
      );
      expect(
        await exitedWithin(harness, const Duration(seconds: 2)),
        isFalse,
        reason: 'an expired window must reset to press 1 (ACX.3)',
      );

      harness.sendCtrlC(); // now inside the fresh window: exit
      // The 130 code is pinned by ACX.4 (headless, Process.exitCode); over
      // the PTY pty2 can lose the waitpid race and report -1 for a clean
      // exit, so the contract here is bounded death (ACX.2 / ACX.4 note).
      // 30s, not 15: this case runs the longest press ladder of the file
      // (press → window expiry → fresh press → exit) behind three PTY
      // suites at --concurrency=4; on the hosted arm shard the exit
      // handshake measured past 15s (run 36327531059) — the assertion is
      // unchanged: the REPL must die, never park on -999.
      const stillAlive = -999;
      final code = await harness.pty.exitCode.timeout(
        const Duration(seconds: 30),
        onTimeout: () => stillAlive,
      );
      expect(
        code,
        isNot(stillAlive),
        reason:
            'press 2 inside the fresh window must exit the REPL '
            '(issue #830); exit code $code',
      );
    });
  });

  group('headless SIGINT pin (ACX.4)', () {
    late Directory tempHome;
    late Directory workspace;

    setUp(() {
      tempHome = Directory.systemTemp.createTempSync('fa_ctrl_c_headless_');
      File('${tempHome.path}/.fah/config.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('approvalMode: yolo\n');
      workspace = Directory.systemTemp.createTempSync('fa_ctrl_c_ws_');
    });

    tearDown(() {
      tempHome.deleteSync(recursive: true);
      workspace.deleteSync(recursive: true);
    });

    test('fa -p + SIGINT mid-run still exits immediately with 130', () async {
      // A provider endpoint whose completion request never answers: the
      // SIGINT lands while the turn is in flight, deterministically.
      final server = await HttpServer.bind('127.0.0.1', 0);
      final gotRequest = Completer<void>();
      final sub = server.listen((request) async {
        if (request.uri.path.endsWith('/models')) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            '{"object":"list","data":[{"id":"mock-model","object":"model"}]}',
          );
          await request.response.close();
          return;
        }
        if (!gotRequest.isCompleted) gotRequest.complete();
        await request.drain<void>();
      });
      addTearDown(sub.cancel);

      final process = await Process.start(
        'dart',
        [
          'bin/fah.dart',
          '--provider',
          'openai-completions',
          '--base-url',
          'http://127.0.0.1:${server.port}/v1',
          '--model',
          'mock-model',
          '--cwd',
          workspace.path,
          '--output',
          'events',
          '-p',
          'hi',
        ],
        workingDirectory: Directory.current.path,
        // NOT merged: Process.start adds `environment:` ON TOP of the
        // parent env by default, so a developer/agent machine carrying
        // FA_PROVIDERS_QUEUE / FA_PROVIDER_* (the agent-sandbox case)
        // made the child dial the REAL queue provider and this pin
        // timed out waiting for a mock-server request that never came.
        // Replace the env wholesale — same whitelist hygiene as the PTY
        // harness (pty_harness.dart: API keys and agent env never leak
        // into tests); PATH (executable lookup) and PUB_CACHE (package
        // resolution under the overridden HOME) are the only pass-throughs.
        includeParentEnvironment: false,
        environment: {
          'OPENAI_API_KEY': 'mock',
          'HOME': tempHome.path,
          'PATH': Platform.environment['PATH'] ?? '',
          if (Platform.environment['PUB_CACHE'] != null)
            'PUB_CACHE': Platform.environment['PUB_CACHE']!,
        },
      );
      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();
      final stdoutSub = process.stdout
          .transform(utf8.decoder)
          .listen(stdoutBuffer.write);
      final stderrSub = process.stderr
          .transform(utf8.decoder)
          .listen(stderrBuffer.write);
      addTearDown(() async {
        await stdoutSub.cancel();
        await stderrSub.cancel();
      });

      await gotRequest.future.timeout(const Duration(minutes: 2));
      process.kill(ProcessSignal.sigint);

      final exitCode = await process.exitCode.timeout(
        const Duration(minutes: 2),
      );
      expect(
        exitCode,
        130,
        reason: 'headless has no press window\nstderr: $stderrBuffer',
      );

      final lines = stdoutBuffer
          .toString()
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      final frames = [
        for (final line in lines) jsonDecode(line) as Map<String, dynamic>,
      ];
      expect(frames.first['type'], 'hep_header');
      expect(frames.last['type'], 'cancelled');
    });
  });
}
