/// Double-press Ctrl+C contract (issue #830) over the real PTY.
///
/// ACX.1-ACX.3 spawn the TUI with `raw: false` so the kernel line
/// discipline keeps ISIG: the harness-written 0x03 becomes a SIGINT — the
/// exact path real terminal users hit (the TUI never sees ctrl+c as a key).
/// ACX.4 pins the headless `fa -p` SIGINT abort (no double-press window).
///
/// The 3 s press window is a contract constant (no config knob), so ACX.3
/// sleeps past it with a real clock — a PTY test cannot inject one.
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

        await harness.waitForScreen('press ctrl+c again to exit');
        expect(
          harness.screenText,
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

    test(
      'ACX.2: press 2 within the window exits 130; a fresh session prints '
      'the honest nothing-to-resume line',
      () async {
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
        expect(
          await harness.pty.exitCode.timeout(const Duration(seconds: 15)),
          130,
        );
      },
    );

    test('ACX.3: a press after the window is a fresh press 1', () async {
      final harness = await spawnTui();
      addTearDown(harness.close);
      await harness.waitForBoot();

      harness.sendCtrlC(); // press 1 at t=0
      await harness.waitForScreen('press ctrl+c again to exit');
      await Future<void>.delayed(
        kSigintPressWindow + const Duration(seconds: 1),
      );
      harness.sendCtrlC(); // past the window: fresh press 1, NOT an exit
      await harness.waitForOutput(settleMs: 200);
      expect(
        await exitedWithin(harness, const Duration(seconds: 2)),
        isFalse,
        reason: 'an expired window must reset to press 1 (ACX.3)',
      );

      harness.sendCtrlC(); // now inside the fresh window: exit
      expect(
        await harness.pty.exitCode.timeout(const Duration(seconds: 15)),
        130,
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
        environment: {'OPENAI_API_KEY': 'mock', 'HOME': tempHome.path},
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
        await stdoutSub.cancel;
        await stderrSub.cancel;
      });

      await gotRequest.future.timeout(const Duration(minutes: 2));
      process.kill(ProcessSignal.sigint);

      final exitCode = await process.exitCode.timeout(
        const Duration(minutes: 2),
      );
      expect(
        exitCode,
        130,
        reason: 'headless has no press window\nstderr: ${stderrBuffer}',
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
