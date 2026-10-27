// gh-1596 IT-1..IT-4 — the first-run wizard under `curl | sh`, driven
// through a real pseudo-terminal.
//
// AC2: `cat site/setup.sh | <shell>` (the pipe is what makes the shebang
// dead text) with scripted /dev/tty answers picks Custom, accepts an
// endpoint + key, writes a valid ~/.fah/config.yaml and exits 0 — under
// dash (Ubuntu sh), busybox ash (Alpine) and bash.
// AC3: the hidden API key never appears in the captured transcript and
// lands in exactly ONE produced file, exactly once (the shell rc on the
// persist-yes flavor; fa's config.yaml is deliberately key-free — secrets
// never ride the yaml, settings_registry #288 E1).
// AC4: a non-TTY run prints the guidance and exits non-zero, writing no
// .fah (plain pipes — no pty needed: the guard keys on stderr not being a
// tty).
// AC5/I3: the direct `bash site/setup.sh` run answers with the SAME
// prompts as the piped dash run.
//
// Platform facts pinned with a probe each: dash and busybox ash REJECT
// `printf -v` (the #1596 crash), bash accepts it (why macOS never saw the
// bug — its sh is bash 3.2 POSIX mode).
//
// Shells missing on the host (busybox on most CI images, dash on macOS)
// SKIP their tests with a named reason; the installer-portability CI job
// installs both on ubuntu before running this file (REG-1).
@Tags(['io', 'integration'])
@Timeout(Duration(minutes: 6))
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:pty2/pty2.dart';

/// The fixture API key. Byte-scanned against every captured transcript
/// (AC3) — must never leak into the pty output (read -s has echo off by
/// the time the key is fed).
const _key = 'FA-TEST-KEY-1596-qX7wP9';

/// E3 fixture values: spaces, single + double quotes, a `$`, a trailing
/// slash — stored VERBATIM into config.yaml.
const _endpoint = 'http://localhost:11434/v1/';
const _model = "m0del with space 'sq' \"dq\" and \$dollar";

String _repoRoot() {
  var dir = Directory.current;
  while (true) {
    if (Directory('${dir.path}/site').existsSync() &&
        Directory('${dir.path}/scripts').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('run from inside the flutter_agent repo');
    }
    dir = parent;
  }
}

bool _have(String bin) =>
    Process.runSync('sh', ['-c', 'command -v $bin']).exitCode == 0;

final _ansi = RegExp('\x1b\\[[0-9;]*[A-Za-z]');

String _clean(String s) => s.replaceAll(_ansi, '');

/// A throwaway HOME with a stub `fa` first on PATH (the wizard only checks
/// `command -v fa` — it must never touch the real CLI). No `.fah` exists
/// unless the test creates one.
class _Fixture {
  _Fixture() {
    home = Directory.systemTemp.createTempSync('fa_setup_wizard_');
    exitFile = '${home.path}/exit_code';
    final shim = Directory('${home.path}/bin')..createSync();
    final stub = File('${shim.path}/fa')
      ..writeAsStringSync('#!/bin/sh\necho fa-fixture-1596\n');
    Process.runSync('chmod', ['+x', stub.path]);
    path = '${shim.path}:${Platform.environment['PATH'] ?? '/usr/bin:/bin'}';
  }

  late final Directory home;
  late final String path;
  late final String exitFile;

  File get config => File('${home.path}/.fah/config.yaml');

  /// E2 seed: a pre-existing config the wizard must not clobber silently.
  void seedConfig(String content) {
    Directory('${home.path}/.fah').createSync();
    config.writeAsStringSync(content);
  }

  void dispose() => home.deleteSync(recursive: true);
}

/// Answers, in wizard order, for the Custom flow (`feed` appends the \r).
/// The key is fed only after the hidden prompt is seen (+150 ms — read -s
/// disables echo at read entry; the delay makes the race unwinnable).
class _Answers {
  final List<(String, String)> items;
  _Answers(this.items);
  static _Answers custom({bool persistKey = false}) => _Answers([
    ('Pick a provider', 'custom'),
    ('Custom base URL', _endpoint),
    ('Model id on that endpoint', _model),
    ('Does this endpoint require an API key', 'y'),
    ('Paste your API key', _key),
    ('Pick a mode', '1'),
    ('Pick an approval mode', 'yolo'),
    if (persistKey) ('Add OPENAI_API_KEY to', 'y'),
  ]);
}

/// Echoed by the run wrappers onto the pty AFTER the exit file is written
/// (see [_PtyRun.awaitExit]): its arrival in the captured buffer is the
/// completeness proof — everything queued before it on the kernel pty is
/// already consumed and delivered.
const _drainSentinel = '__FA_PTY_DRAIN_SENTINEL_1796__';

class _PtyRun {
  _PtyRun._(this.pty, this.buffer, this.exitFile);
  final PseudoTerminal pty;
  final StringBuffer buffer;
  final String exitFile;
  var done = false;

  /// Waits until [text] (ANSI-stripped) appears in the captured output.
  Future<void> waitPrompt(String text) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!_clean(buffer.toString()).contains(text)) {
      if (DateTime.now().isAfter(deadline)) {
        fail(
          'timed out waiting for "$text"; captured so far:\n'
          '${_clean(buffer.toString())}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// The wizard's exit status, delivered out-of-band by the run wrapper —
  /// pty2's own `exitCode` races the Dart VM's child reaper (ECHILD → -1).
  ///
  /// The exit FILE is written by the wrapper the instant the pipeline
  /// exits, but pty2 closes the pty master the moment IT reaps the same
  /// child (BlockingPseudoTerminal chains exitCode → kill → close), and
  /// an undrained master output queue is discarded on that close — #1796:
  /// the trailing "Kept existing config." was lost exactly this way, in
  /// two distinct-SHA gate runs.
  ///
  /// A drained buffer therefore cannot be proven via `done`: pty2's read
  /// maps any `read() <= 0` — EBADF after that close included — to the
  /// same null-as-EOF, so onDone fires from the KILL even when bytes were
  /// discarded. The completeness proof is the [_drainSentinel] the run
  /// wrapper echoes onto the same pty AFTER the exit file: the kernel
  /// queues it strictly behind every byte the wizard wrote, the reader
  /// consumes that queue in order, and one SendPort/stream chain
  /// delivers in order — seeing the sentinel in [buffer] thus proves
  /// every wizard byte already arrived, whatever the close did after.
  Future<int> awaitExit() async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (true) {
      final f = File(exitFile);
      if (f.existsSync()) {
        final text = f.readAsStringSync().trim();
        if (text.isNotEmpty) {
          final code = int.parse(text);
          final drainDeadline = DateTime.now().add(const Duration(seconds: 10));
          while (!_clean(buffer.toString()).contains(_drainSentinel)) {
            if (DateTime.now().isAfter(drainDeadline)) {
              fail(
                'wizard exited $code but the pty output never drained to '
                'the sentinel; captured:\n${_clean(buffer.toString())}',
              );
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          return code;
        }
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('wizard never exited; captured:\n${_clean(buffer.toString())}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  void send(String s) => pty.write(s);

  /// Feeds every answer after its prompt shows up; the hidden key gets a
  /// settle delay so echo-off (stty -echo) is already in effect.
  Future<void> feed(_Answers answers) async {
    for (final (prompt, answer) in answers.items) {
      await waitPrompt(prompt);
      if (prompt == 'Paste your API key') {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      send('$answer\r');
    }
  }
}

Future<_PtyRun> _spawn(
  String executable,
  List<String> arguments, {
  required _Fixture fixture,
  String shellEnv = '',
}) {
  final buffer = StringBuffer();
  final pty = PseudoTerminal.start(
    executable,
    arguments,
    workingDirectory: _repoRoot(),
    environment: {
      'HOME': fixture.home.path,
      'PATH': fixture.path,
      'SHELL': shellEnv,
    },
    // Canonical mode: ICRNL rewrites the fed \r to \n (line reads), and
    // the tty line discipline behaves like a real terminal (issue #77).
    raw: false,
  );
  final run = _PtyRun._(pty, buffer, fixture.exitFile);
  pty.out.listen(buffer.write, onDone: () => run.done = true);
  return Future.value(run);
}

/// A piped `cat setup.sh | <shell>` run on a pty (the AC2 curl|sh shape:
/// the shell's stdin is the pipe, answers ride /dev/tty).
Future<_PtyRun> _startPiped(
  String shell, {
  required _Fixture fixture,
  List<String> shellArgs = const [],
  String shellEnv = '',
}) {
  final script = '${_repoRoot()}/site/setup.sh';
  final inner = [shell, ...shellArgs].join(' ');
  return _spawn(
    shell,
    [
      ...shellArgs,
      '-c',
      'cat "\$1" | $inner; echo \$? > "\$2"; echo $_drainSentinel',
      'wizard',
      script,
      fixture.exitFile,
    ],
    fixture: fixture,
    shellEnv: shellEnv,
  );
}

/// A direct `<shell> site/setup.sh` run on a pty (the AC5 shape: stdin IS
/// the tty, so the wizard takes its /dev/stdin branch).
Future<_PtyRun> _startDirect({
  required _Fixture fixture,
  String shellEnv = '',
}) {
  final script = '${_repoRoot()}/site/setup.sh';
  return _spawn(
    'bash',
    [
      '-c',
      'bash "\$1"; echo \$? > "\$2"; echo $_drainSentinel',
      'wizard',
      script,
      fixture.exitFile,
    ],
    fixture: fixture,
    shellEnv: shellEnv,
  );
}

void main() {
  group('platform facts (pinned, gh-1596)', () {
    test('dash rejects printf -v (the #1596 crash)', () {
      final r = Process.runSync('dash', ['-c', 'printf -v x "%s" hi']);
      expect(
        r.exitCode,
        isNonZero,
        reason: 'dash must not accept the bash builtin form',
      );
    }, skip: _have('dash') ? null : 'dash not installed');

    test('busybox ash: printf -v silently corrupts (no assignment)', () {
      // This busybox build doesn't abort on `printf -v` — the flag rides
      // into the FORMAT and the variable stays empty. Either way the
      // bashism cannot survive: the assignment provably never happens.
      final r = Process.runSync('busybox', [
        'ash',
        '-c',
        'printf -v x "%s" hi; [ "\$x" = hi ]',
      ]);
      expect(
        r.exitCode,
        isNonZero,
        reason: 'printf -v must not assign under busybox ash',
      );
    }, skip: _have('busybox') ? null : 'busybox not installed');

    test('bash accepts printf -v (why macOS sh never crashed)', () {
      final r = Process.runSync('bash', ['-c', 'printf -v x "%s" hi']);
      expect(r.exitCode, isZero);
    });

    test('dash read has no -s (why ask_hidden hides via stty)', () {
      final r = Process.runSync('dash', ['-c', 'read -s x < /dev/null']);
      expect(
        r.exitCode,
        isNonZero,
        reason:
            'the ticket I3 shape `read -rs` is unrunnable on dash — '
            'the emitted wizard must hide the key with stty instead',
      );
    }, skip: _have('dash') ? null : 'dash not installed');
  });

  Future<void> runCustomWizard(
    String label, {
    required String shell,
    List<String> shellArgs = const [],
    required bool persistKey,
    bool direct = false,
  }) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final run = direct
        ? await _startDirect(
            fixture: fixture,
            shellEnv: persistKey ? '/bin/bash' : '',
          )
        : await _startPiped(
            shell,
            shellArgs: shellArgs,
            fixture: fixture,
            shellEnv: persistKey ? '/bin/bash' : '',
          );
    await run.feed(_Answers.custom(persistKey: persistKey));

    final exitCode = await run.awaitExit();
    expect(
      exitCode,
      0,
      reason:
          '$label: wizard exited non-zero; output:\n'
          '${_clean(run.buffer.toString())}',
    );

    // The wizard completed through the whole flow.
    final out = _clean(run.buffer.toString());
    expect(out, contains("Found 'fa' on PATH"));
    expect(out, contains('Pick a provider'));
    expect(out, contains('Configuration complete.'));

    // AC2: a valid config landed.
    final configText = fixture.config.readAsStringSync();
    expect(configText, contains('provider: openai-completions'));
    expect(configText, contains('mode: code'));
    expect(configText, contains('approvalMode: yolo'));

    // E3: endpoint + model stored verbatim (spaces, quotes, $, trailing /).
    expect(configText, contains('baseUrl: $_endpoint'));
    expect(configText, contains('model: $_model'));

    // AC3: the key never appears in the transcript...
    expect(
      out.contains(_key),
      isFalse,
      reason: 'the hidden API key leaked into the captured transcript',
    );
    // ...and lands in exactly ONE produced file, exactly once. config.yaml
    // stays key-free by design (secrets never ride the yaml, #288 E1) —
    // the key's home is the env-var rc file.
    final rcFile = File('${fixture.home.path}/.bashrc');
    if (persistKey) {
      expect(
        rcFile.readAsStringSync().split(_key).length - 1,
        1,
        reason: 'persist-yes: the key must appear exactly once (the rc)',
      );
    } else {
      expect(rcFile.existsSync(), isFalse);
    }
    expect(
      configText.contains(_key),
      isFalse,
      reason: 'config.yaml must stay key-free (#288 E1)',
    );
    // Nothing else under HOME carries the key.
    for (final f in fixture.home.listSync(recursive: true).whereType<File>()) {
      if (f.path.endsWith('.bashrc')) continue;
      expect(
        f.readAsStringSync().contains(_key),
        isFalse,
        reason: '${f.path} unexpectedly carries the API key',
      );
    }
  }

  group('IT — piped wizard completes per shell (AC2/AC3)', () {
    test('dash (Ubuntu sh) — full custom flow', () async {
      await runCustomWizard('dash', shell: 'dash', persistKey: false);
    }, skip: _have('dash') ? null : 'dash not installed');

    test('busybox ash (Alpine sh) — full custom flow', () async {
      await runCustomWizard(
        'busybox ash',
        shell: 'busybox',
        shellArgs: const ['ash'],
        persistKey: false,
      );
    }, skip: _have('busybox') ? null : 'busybox not installed');

    test('bash — full custom flow, key persisted exactly once (AC3)', () async {
      await runCustomWizard('bash', shell: 'bash', persistKey: true);
    });
  });

  group('IT-3/AC5 — direct bash run parity', () {
    test('bash site/setup.sh (non-piped) shows the same prompts', () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final run = await _startDirect(fixture: fixture);
      await run.feed(_Answers.custom(persistKey: false));
      final exitCode = await run.awaitExit();
      expect(exitCode, 0);
      final out = _clean(run.buffer.toString());
      // I3: prompt texts identical to the piped runs.
      expect(out, contains('Pick a provider [1-13]'));
      expect(out, contains('Custom base URL'));
      expect(out, contains('Pick a mode'));
      expect(out, contains('Pick an approval mode'));
      expect(out, contains('Configuration complete.'));
      expect(
        fixture.config.readAsStringSync(),
        contains('provider: openai-completions'),
      );
      expect(out.contains(_key), isFalse);
    });
  });

  group('IT-4/AC4 — non-TTY degradation', () {
    test('no pty: guidance message, non-zero exit, no .fah written', () {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final script = '${_repoRoot()}/site/setup.sh';
      final r = Process.runSync(
        'dash',
        ['-c', 'cat "$script" | dash'],
        environment: {'HOME': fixture.home.path, 'PATH': fixture.path},
      );
      expect(
        r.exitCode,
        isNonZero,
        reason: 'a non-interactive run must not read as success (AC4)',
      );
      final out = '${r.stdout}${r.stderr}';
      expect(out, contains('Non-interactive environment detected.'));
      expect(out, contains('To finish setup, set an API key and run'));
      expect(
        Directory('${fixture.home.path}/.fah').existsSync(),
        isFalse,
        reason: 'the guard must fire before any config write',
      );
    }, skip: _have('dash') ? null : 'dash not installed');
  });

  group('edge cases', () {
    test('E2 — existing config is not clobbered silently', () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      fixture.seedConfig('provider: keep-me\n');
      final run = await _startPiped('dash', fixture: fixture, shellEnv: '');
      await run.feed(_Answers([('Reconfigure?', 'n')]));
      final exitCode = await run.awaitExit();
      expect(exitCode, 0);
      expect(_clean(run.buffer.toString()), contains('Kept existing config.'));
      expect(
        fixture.config.readAsStringSync(),
        'provider: keep-me\n',
        reason: 'answering no must leave the config untouched',
      );
    }, skip: _have('dash') ? null : 'dash not installed');

    test('E1 — Ctrl-C mid-wizard leaves no .fah behind', () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final run = await _startPiped('dash', fixture: fixture, shellEnv: '');
      await run.waitPrompt('Pick a provider');
      run.send('\x03');
      // The SIGINT takes down the whole pipeline — including the wrapper
      // that would write the exit-status file — so the observable fact is
      // process death (pty closed), not a status code (pty2's exitCode
      // also races the VM's child reaper).
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!run.done) {
        if (DateTime.now().isAfter(deadline)) {
          fail(
            'wizard survived Ctrl-C; captured:\n'
            '${_clean(run.buffer.toString())}',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        Directory('${fixture.home.path}/.fah').existsSync(),
        isFalse,
        reason: 'an interrupted wizard must leave no config dir behind',
      );
      expect(
        File(fixture.exitFile).existsSync(),
        isFalse,
        reason: 'the interrupt killed the pipeline before completion',
      );
    }, skip: _have('dash') ? null : 'dash not installed');

    test('E3 — EOF mid-wizard aborts non-zero, no config written', () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final run = await _startPiped('dash', fixture: fixture, shellEnv: '');
      // One real answer, then ^D on an empty line at the NEXT prompt: the
      // read inside `ask` fails, the `var=$(ask …)` assignment fails, and
      // `set -eu` must take the whole wizard down — never silently proceed
      // on defaults and write a half-configured ~/.fah.
      await run.waitPrompt('Pick a provider');
      run.send('custom\r');
      await run.waitPrompt('Custom base URL');
      run.send('\x04');
      final code = await run.awaitExit();
      expect(
        code,
        isNonZero,
        reason: 'an EOF wizard run must not read as a completed setup',
      );
      expect(
        Directory('${fixture.home.path}/.fah').existsSync(),
        isFalse,
        reason: 'no config may be written once input died mid-wizard',
      );
    }, skip: _have('dash') ? null : 'dash not installed');

    test('E4 — HOME unset: clear error, non-zero exit', () {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final script = '${_repoRoot()}/site/setup.sh';
      final r = Process.runSync(
        'dash',
        ['-c', 'cat "$script" | dash'],
        environment: {'HOME': '', 'PATH': fixture.path},
      );
      expect(r.exitCode, isNonZero);
      expect(
        '${r.stdout}${r.stderr}',
        contains(r'$HOME is not set'),
        reason:
            'the failure must name the problem, not a bare '
            '"parameter not set" from deep inside the script',
      );
      expect(Directory('${fixture.home.path}/.fah').existsSync(), isFalse);
    }, skip: _have('dash') ? null : 'dash not installed');
  });
}
