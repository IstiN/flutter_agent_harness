@Tags(['integration'])
// The ratchet leg's coverage source (scripts/check_cli_coverage.py measures
// lib/src/cli/** from the integration-tagged PTY shards): the jsr delegate
// lives in lib/src/cli, so these tests MUST carry the tag — gh-1033 review
// thread 7 (coverage ratchet dilution).
library;

import 'dart:convert';

import 'package:flutter_agent_harness/src/cli/jsr_cli.dart';
import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:test/test.dart';

/// Delegate unit tests for `fa jsr widget:test|widget:screenshot`
/// (gh-1033, IT-*): a FAKE jsr package injected into a temp project's
/// package_config plus a scripted shell — flag passthrough, stdout/stderr
/// streaming, exit-code mapping, and both clean-error paths. No real
/// flutter needed.

/// A scripted [Shell]: records every command + options, emits streamed
/// stdout/stderr chunks, returns a scripted outcome.
final class ScriptedShell implements Shell {
  ScriptedShell({this.exitCode = 0, this.failExec = false});

  final commands = <String>[];
  final options = <ShellExecOptions?>[];
  var exitCode = 0;
  var failExec = false;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    commands.add(command);
    this.options.add(options);
    if (failExec) {
      return const Err(
        ExecutionError(ExecutionErrorCode.spawnError, 'spawn failed'),
      );
    }
    options?.onStdout?.call('stdout line 1\n');
    options?.onStdout?.call('{"ok":true}'); // no trailing newline: AC2
    options?.onStderr?.call('stderr line\n');
    return Ok(
      ShellExecResult(
        stdout: 'stdout line 1\n{"ok":true}',
        stderr: 'stderr line\n',
        exitCode: exitCode,
      ),
    );
  }
}

/// Recording [JsrCliIo]: captures every channel separately.
final class RecordingJsrIo implements JsrCliIo {
  final stdoutChunks = <String>[];
  final stderrChunks = <String>[];
  final notes = <String>[];

  @override
  void writeStdout(String chunk) => stdoutChunks.add(chunk);

  @override
  void writeStderr(String chunk) => stderrChunks.add(chunk);

  @override
  void note(String line) => notes.add(line);
}

void main() {
  const projectDir = '/work';
  const jsrRoot = '/pub/js_widget_runtime-0.4.128';
  const flutterBin = '/flutter/bin';

  /// Builds a fake consumer project: package_config naming the fake jsr
  /// package, the package's CLI entrypoint, and a flutter binary on PATH.
  Future<MemoryExecutionEnv> project({
    String? rootUri = 'file://$jsrRoot',
    bool writeEntrypoint = true,
    bool flutterOnPath = true,
    String? configJson,
    bool writePackageConfig = true,
    Shell? shell,
  }) async {
    final env = MemoryExecutionEnv(
      cwd: projectDir,
      shell: shell ?? const UnavailableShell(),
    );
    if (writePackageConfig) {
      await env.writeFile(
        '$projectDir/.dart_tool/package_config.json',
        configJson ??
            jsonEncode({
              'configVersion': 2,
              'packages': [
                {
                  'name': 'js_widget_runtime',
                  'rootUri': rootUri,
                  'languageVersion': '3.12',
                },
                {
                  'name': 'some_other_pkg',
                  'rootUri': 'file:///pub/other',
                  'languageVersion': '3.12',
                },
              ],
            }),
      );
    }
    if (writeEntrypoint) {
      await env.writeFile('$jsrRoot/bin/jsr_widget.dart', 'void main() {}');
    }
    if (flutterOnPath) {
      await env.writeFile('$flutterBin/flutter', '#!/bin/sh\n');
    }
    return env;
  }

  /// Runs the delegate against a scripted shell and hands back the exit
  /// code plus the recording io. The fake project is built here so the
  /// shell rides the env from construction.
  Future<(int, RecordingJsrIo, ScriptedShell)> runJsr(
    JsrCliCommand cmd, {
    ScriptedShell? shell,
    String? rootUri = 'file://$jsrRoot',
    bool writeEntrypoint = true,
    bool flutterOnPath = true,
    String? configJson,
    bool writePackageConfig = true,
    String? pathEnv = '$flutterBin:/usr/bin',
    String pathListSeparator = ':',
    String projectDirOverride = projectDir,
    String dartExecutable = 'dart',
    bool windowsQuoting = false,
  }) async {
    final sh = shell ?? ScriptedShell();
    final env = await project(
      rootUri: rootUri,
      writeEntrypoint: writeEntrypoint,
      flutterOnPath: flutterOnPath,
      configJson: configJson,
      writePackageConfig: writePackageConfig,
      shell: sh,
    );
    final io = RecordingJsrIo();
    final code = await runJsrCliCommand(
      cmd,
      io: io,
      env: env,
      projectDir: projectDirOverride,
      pathEnv: pathEnv,
      pathListSeparator: pathListSeparator,
      dartExecutable: dartExecutable,
      windowsQuoting: windowsQuoting,
    );
    return (code, io, sh);
  }

  group('package resolution', () {
    test('absolute file:// rootUri resolves to the package root', () async {
      final env = await project();
      final resolution = await resolveJsrPackageRoot(
        env,
        projectDir: projectDir,
      );
      expect(resolution, isA<JsrPackageReady>());
      expect((resolution as JsrPackageReady).packageRoot, jsrRoot);
    });

    test(
      'relative rootUri resolves against the .dart_tool directory',
      () async {
        final env = await project(
          rootUri: '../../pub/js_widget_runtime-0.4.128',
        );
        final resolution = await resolveJsrPackageRoot(
          env,
          projectDir: projectDir,
        );
        expect(resolution, isA<JsrPackageReady>());
        expect((resolution as JsrPackageReady).packageRoot, jsrRoot);
      },
    );

    test('missing package_config is JsrPackageMissing', () async {
      final env = MemoryExecutionEnv(cwd: projectDir);
      final resolution = await resolveJsrPackageRoot(
        env,
        projectDir: projectDir,
      );
      expect(resolution, isA<JsrPackageMissing>());
    });

    test('config without a jsr entry is JsrPackageMissing', () async {
      final env = await project(
        configJson: jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'some_other_pkg',
              'rootUri': 'file:///pub/other',
              'languageVersion': '3.12',
            },
          ],
        }),
      );
      final resolution = await resolveJsrPackageRoot(
        env,
        projectDir: projectDir,
      );
      expect(resolution, isA<JsrPackageMissing>());
    });

    test('malformed package_config is JsrPackageMissing', () async {
      final env = await project(configJson: '{not json');
      final resolution = await resolveJsrPackageRoot(
        env,
        projectDir: projectDir,
      );
      expect(resolution, isA<JsrPackageMissing>());
      expect(
        (resolution as JsrPackageMissing).detail,
        contains('invalid JSON'),
      );
    });

    test('non-map package_config is JsrPackageMissing', () async {
      final env = await project(configJson: '[]');
      final resolution = await resolveJsrPackageRoot(
        env,
        projectDir: projectDir,
      );
      expect(resolution, isA<JsrPackageMissing>());
      expect(
        (resolution as JsrPackageMissing).detail,
        contains('not a package_config'),
      );
    });

    test('config without a packages list is JsrPackageMissing', () async {
      final env = await project(configJson: '{"configVersion":2}');
      final resolution = await resolveJsrPackageRoot(
        env,
        projectDir: projectDir,
      );
      expect(resolution, isA<JsrPackageMissing>());
      expect(
        (resolution as JsrPackageMissing).detail,
        contains('no packages list'),
      );
    });

    test('jsr without the CLI entrypoint is JsrCliEntrypointMissing', () async {
      final env = await project(writeEntrypoint: false);
      final resolution = await resolveJsrPackageRoot(
        env,
        projectDir: projectDir,
      );
      expect(resolution, isA<JsrCliEntrypointMissing>());
    });
  });

  group('flutter PATH probe', () {
    test('finds flutter in a later PATH entry (2+ entries)', () async {
      final env = await project();
      expect(
        await flutterOnPath(
          env,
          pathEnv: '/usr/local/bin:$flutterBin:/usr/bin',
          pathListSeparator: ':',
        ),
        isTrue,
      );
    });

    test('empty PATH is not found', () async {
      final env = await project();
      expect(
        await flutterOnPath(env, pathEnv: '', pathListSeparator: ':'),
        isFalse,
      );
    });

    test('no entry carries flutter is not found', () async {
      final env = await project(flutterOnPath: false);
      expect(
        await flutterOnPath(
          env,
          pathEnv: '$flutterBin:/usr/bin',
          pathListSeparator: ':',
        ),
        isFalse,
      );
    });

    test('finds the .bat candidate through a windows-style PATH', () async {
      final env = await project(flutterOnPath: false);
      await env.writeFile('$flutterBin/flutter.bat', '@echo off\n');
      expect(
        await flutterOnPath(
          env,
          pathEnv: 'C:\\other;$flutterBin',
          pathListSeparator: ';',
        ),
        isTrue,
      );
    });
  });

  group('runJsrCliCommand', () {
    test(
      'AC1: widget:test execs the jsr CLI with the verb and passthrough args',
      () async {
        final (code, io, shell) = await runJsr(
          const JsrCliCommand(
            verb: 'widget:test',
            args: [
              'example/widgets/calculator',
              '--event',
              'btn_7',
              '--event',
              'btn_*',
              '--event',
              'btn_6',
              '--event',
              'btn_=',
              '--expect-state',
              '{"display":"42"}',
            ],
          ),
        );
        expect(code, 0);
        expect(io.notes, isEmpty);
        expect(
          shell.commands.single,
          'dart "$jsrRoot/bin/jsr_widget.dart" widget:test '
          'example/widgets/calculator --event btn_7 --event "btn_*" '
          '--event btn_6 --event btn_= --expect-state '
          '"{\\"display\\":\\"42\\"}"',
        );
        // The child runs in the CONSUMER project (its lockfile truth).
        expect(shell.options.single?.cwd, projectDir);
      },
    );

    test('AC2: stdout/stderr chunks stream through verbatim', () async {
      final (code, io, _) = await runJsr(
        const JsrCliCommand(verb: 'widget:test', args: ['w', '--json']),
      );
      expect(code, 0);
      // Chunk boundaries and the missing trailing newline survive.
      expect(io.stdoutChunks, ['stdout line 1\n', '{"ok":true}']);
      expect(io.stderrChunks, ['stderr line\n']);
      expect(io.notes, isEmpty);
    });

    test('AC4: a failing widget test maps its exit code 1:1', () async {
      final (code, io, _) = await runJsr(
        const JsrCliCommand(verb: 'widget:test', args: ['w']),
        shell: ScriptedShell(exitCode: 3),
      );
      expect(code, 3);
      // The child's failure output still landed (I2: no mangling).
      expect(io.stderrChunks, ['stderr line\n']);
    });

    test('widget:screenshot passes its flags through too', () async {
      final (code, _, shell) = await runJsr(
        const JsrCliCommand(
          verb: 'widget:screenshot',
          args: ['w', '--out', 'shot.png', '--scale', '2', '--freeze-clock'],
        ),
      );
      expect(code, 0);
      expect(
        shell.commands.single,
        'dart "$jsrRoot/bin/jsr_widget.dart" widget:screenshot w --out '
        'shot.png --scale 2 --freeze-clock',
      );
    });

    test('AC3: no jsr dependency fails clean, before any exec', () async {
      // No package_config: the project never ran the package manager.
      final (code, io, shell) = await runJsr(
        const JsrCliCommand(verb: 'widget:test', args: ['w']),
        writePackageConfig: false,
      );
      expect(code, 1);
      expect(shell.commands, isEmpty);
      expect(io.notes.single, contains('add js_widget_runtime'));
      expect(
        io.notes.single,
        contains('$projectDir/.dart_tool/package_config.json'),
      );
      expect(io.stdoutChunks, isEmpty);
    });

    test('AC3: jsr entrypoint missing names the 0.4.128 upgrade', () async {
      final (code, io, shell) = await runJsr(
        const JsrCliCommand(verb: 'widget:test', args: ['w']),
        writeEntrypoint: false,
      );
      expect(code, 1);
      expect(shell.commands, isEmpty);
      expect(io.notes.single, contains('0.4.128'));
    });

    test(
      'AC3: flutter missing from PATH fails fast with a named hint',
      () async {
        final (code, io, shell) = await runJsr(
          const JsrCliCommand(verb: 'widget:screenshot', args: ['w']),
          flutterOnPath: false,
          pathEnv: '/usr/local/bin:/usr/bin',
        );
        expect(code, 1);
        expect(shell.commands, isEmpty);
        expect(io.notes.single, allOf(contains('flutter'), contains('PATH')));
      },
    );

    test('a null pathEnv (no env accessor) skips the preflight instead of '
        'claiming flutter is missing', () async {
      final (code, io, shell) = await runJsr(
        const JsrCliCommand(verb: 'widget:test', args: ['w']),
        pathEnv: null,
      );
      // The child runs and owns its own failure (I2 transparency); the
      // harness never asserts a PATH it could not see.
      expect(code, 0);
      expect(shell.commands, isNotEmpty);
      expect(io.notes.where((n) => n.contains('flutter')), isEmpty);
    });

    test('spawn failure surfaces as a note and exit 1', () async {
      final (code, io, _) = await runJsr(
        const JsrCliCommand(verb: 'widget:test', args: ['w']),
        shell: ScriptedShell(failExec: true),
      );
      expect(code, 1);
      expect(io.notes.single, contains('spawn failed'));
    });

    test('quoted project paths keep the command a single sh word', () async {
      final shell = ScriptedShell();
      final env = await project(
        rootUri: 'file:///pub my cache/jsr-0.4.128',
        writeEntrypoint: false,
        shell: shell,
      );
      await env.writeFile(
        '/pub my cache/jsr-0.4.128/bin/jsr_widget.dart',
        'void main() {}',
      );
      final io = RecordingJsrIo();
      final code = await runJsrCliCommand(
        const JsrCliCommand(verb: 'widget:test', args: ['w']),
        io: io,
        env: env,
        projectDir: projectDir,
        pathEnv: '$flutterBin:/usr/bin',
        pathListSeparator: ':',
      );
      expect(code, 0);
      expect(
        shell.commands.single,
        startsWith('dart "/pub my cache/jsr-0.4.128/bin/jsr_widget.dart"'),
      );
    });

    test('dart executable is injectable', () async {
      final (code, _, shell) = await runJsr(
        const JsrCliCommand(verb: 'widget:test', args: ['w']),
        dartExecutable: '/usr/local/bin/dart',
      );
      expect(code, 0);
      expect(
        shell.commands.single,
        startsWith('/usr/local/bin/dart "$jsrRoot/bin/jsr_widget.dart"'),
      );
    });
  });

  group('package resolution: malformed rootUri stays a clean error', () {
    test(
      'an unparseable rootUri (:::) is JsrPackageMissing, not a throw',
      () async {
        final env = await project(rootUri: ':::');
        final resolution = await resolveJsrPackageRoot(
          env,
          projectDir: projectDir,
        );
        expect(resolution, isA<JsrPackageMissing>());
        expect(
          (resolution as JsrPackageMissing).detail,
          contains('invalid rootUri'),
        );
      },
    );

    test(
      'a non-file rootUri (https:) is JsrPackageMissing, not a throw',
      () async {
        final env = await project(rootUri: 'https://host/pkg');
        final resolution = await resolveJsrPackageRoot(
          env,
          projectDir: projectDir,
        );
        expect(resolution, isA<JsrPackageMissing>());
        expect(
          (resolution as JsrPackageMissing).detail,
          contains('not a file URI'),
        );
      },
    );

    test('runJsrCliCommand surfaces both as the add-dependency note', () async {
      final (code, io, shell) = await runJsr(
        const JsrCliCommand(verb: 'widget:test', args: ['w']),
        rootUri: ':::',
      );
      expect(code, 1);
      expect(shell.commands, isEmpty);
      expect(io.notes.single, contains('add js_widget_runtime'));
    });
  });

  group('windows (cmd) quoting', () {
    test(
      'POSIX default quoting is unchanged: embedded quote sh-escapes only',
      () {
        expect(quoteJsrArg('"& calc'), r'"\"& calc"');
      },
    );

    test(
      'reviewer breakout shape: \'& calc keeps every & inactive for cmd',
      () async {
        final (code, _, shell) = await runJsr(
          const JsrCliCommand(verb: 'widget:screenshot', args: ['"& calc']),
          windowsQuoting: true,
        );
        expect(code, 0);
        // The arg's embedded quote is emitted as `\"` (cmd toggles OUT
        // there), so the `&` that follows rides cmd's OUTSIDE state and
        // MUST carry a caret — the bare form would run `calc`.
        expect(
          shell.commands.single,
          'dart "$jsrRoot/bin/jsr_widget.dart" widget:screenshot '
          r'"\"^& calc"',
        );
      },
    );

    test('a quote later in the arg: metachars inside the re-opened quotes '
        'stay bare, cmd never sees them active', () {
      expect(
        quoteJsrArg('he said "hi" & left', windowsQuoting: true),
        r'"he said \"hi\" & left"',
      );
    });

    test('trailing backslashes double; plain path backslashes survive', () {
      expect(quoteJsrArg(r'C:\dir\', windowsQuoting: true), r'"C:\dir\\"');
      expect(
        quoteJsrArg(r'C:\Program Files\app', windowsQuoting: true),
        r'"C:\Program Files\app"',
      );
      expect(
        quoteJsrArg(r'C:\dir\", and more', windowsQuoting: true),
        r'"C:\dir\\\", and more"',
      );
    });

    test(
      'a %-bearing argument is refused clean, before any exec — cmd '
      'expands %VAR% before quote/caret parsing and quotes do not protect',
      () async {
        final (code, io, shell) = await runJsr(
          const JsrCliCommand(
            verb: 'widget:test',
            args: ['--expect-state', '{"dir":"%APPDATA%"}'],
          ),
          windowsQuoting: true,
        );
        expect(code, 1);
        expect(shell.commands, isEmpty);
        expect(io.notes.single, contains('%APPDATA%'));
        expect(io.notes.single, contains('jsr:'));
      },
    );

    test('the same arg carries fine on the POSIX path (no refusal)', () async {
      final (code, _, shell) = await runJsr(
        const JsrCliCommand(
          verb: 'widget:test',
          args: ['--expect-state', '{"dir":"%APPDATA%"}'],
        ),
      );
      expect(code, 0);
      expect(
        shell.commands.single,
        endsWith(r''' "{\"dir\":\"%APPDATA%\"}"'''),
      );
    });
  });
}
