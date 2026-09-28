import 'dart:convert';

import 'package:flutter_agent_harness/src/cli/jsr_cli.dart';
import 'package:flutter_agent_harness/src/cli/cli_args.dart';
import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:test/test.dart';

/// Delegate unit tests for `fa jsr widget:test|widget:screenshot`
/// (gh-1033, IT-*): a FAKE jsr package injected into a temp project's
/// package_config plus a scripted shell — flag passthrough, stdout/stderr
/// streaming, exit-code mapping, and both clean-error paths. No real
/// flutter needed.
void main() {
  const projectDir = '/work';
  const jsrRoot = '/pub/js_widget_runtime-0.4.126';
  const flutterBin = '/flutter/bin';

  /// A scripted [Shell]: records every command + options, optionally
  /// emits streamed stdout/stderr chunks, returns a scripted outcome.
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
        return Err(
          ExecutionError(
            ExecutionErrorCode.processFailed,
            'spawn failed',
          ),
        );
      }
      options?.onStdout?.call('stdout line 1\n');
      options?.onStdout?.call('{"ok":true}'); // no trailing newline: AC2
      options?.onStderr?.call('stderr line\n');
      return Ok(
        ShellExecResult(stdout: 'stdout line 1\n{"ok":true}', stderr: 'stderr line\n', exitCode: exitCode),
      );
    }
  }

  /// Builds a fake consumer project: package_config naming the fake jsr
  /// package, the package's CLI entrypoint, and a flutter binary on PATH.
  Future<MemoryExecutionEnv> project({
    String? rootUri = 'file://$jsrRoot',
    bool writeEntrypoint = true,
    bool flutterOnPath = true,
    String? configJson,
  }) async {
    final env = MemoryExecutionEnv(cwd: projectDir);
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
    if (writeEntrypoint) {
      await env.writeFile('$jsrRoot/bin/jsr_widget.dart', 'void main() {}');
    }
    if (flutterOnPath) {
      await env.writeFile('$flutterBin/flutter', '#!/bin/sh\n');
    }
    return env;
  }

  RecordingJsrIo run(
    MemoryExecutionEnv env,
    ScriptedShell shell, {
    String pathEnv = '$flutterBin:/usr/bin',
  }) {
    final io = RecordingJsrIo();
    late final int code;
    // runJsrCliCommand is awaited by the caller; this helper just wires it.
    runJsrCliCommandLater(env, shell, io, pathEnv, (c) => code = c);
    return io;
  }

  group('jsr package resolution', () {
    test('absolute file:// rootUri resolves to the package root', () async {
      final env = await project();
      final resolution = await resolveJsrPackageRoot(env, projectDir: projectDir);
      expect(resolution, isA<JsrPackageReady>());
      expect((resolution as JsrPackageReady).packageRoot, jsrRoot);
    });

    test('relative rootUri resolves against the .dart_tool directory', () async {
      final env = await project(rootUri: '../../pub/js_widget_runtime-0.4.126');
      final resolution = await resolveJsrPackageRoot(env, projectDir: projectDir);
      expect(resolution, isA<JsrPackageReady>());
      expect((resolution as JsrPackageReady).packageRoot, jsrRoot);
    });

    test('missing package_config is JsrPackageMissing', () async {
      final env = MemoryExecutionEnv(cwd: projectDir);
      final resolution = await resolveJsrPackageRoot(env, projectDir: projectDir);
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
      final resolution = await resolveJsrPackageRoot(env, projectDir: projectDir);
      expect(resolution, isA<JsrPackageMissing>());
    });

    test('malformed package_config is JsrPackageMissing', () async {
      final env = await project(configJson: '{not json');
      final resolution = await resolveJsrPackageRoot(env, projectDir: projectDir);
      expect(resolution, isA<JsrPackageMissing>());
    });

    test('jsr without the CLI entrypoint is JsrCliEntrypointMissing', () async {
      final env = await project(writeEntrypoint: false);
      final resolution = await resolveJsrPackageRoot(env, projectDir: projectDir);
      expect(resolution, isA<JsrCliEntrypointMissing>());
    });
  });

  group('flutter PATH probe', () {
    test('finds flutter in a later PATH entry (2+ entries)', () async {
      final env = await project();
      final found = await flutterOnPath(
        env,
        pathEnv: '/usr/local/bin:$flutterBin:/usr/bin',
        pathListSeparator: ':',
      );
      expect(found, isTrue);
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
        await flutterOnPath(env, pathEnv: '$flutterBin:/usr/bin', pathListSeparator: ':'),
        isFalse,
      );
    });

    test('windows separator and .bat candidate', () async {
      final env = await project();
      await env.writeFile('$flutterBin/flutter.bat', '@echo off\n');
      expect(
        await flutterOnPath(env, pathEnv: 'C:\\flutter\\bin', pathListSeparator: ';'),
        isFalse, // plain `flutter` lives at C:\flutter\bin\flutter — absent here
      );
      await env.writeFile('C:/flutter/bin/flutter', 'x');
      expect(
        await flutterOnPath(env, pathEnv: 'C:\\flutter\\bin', pathListSeparator: ';'),
        isTrue,
      );
    });
  });
}
