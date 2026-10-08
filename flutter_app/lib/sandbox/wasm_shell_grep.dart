// Grep builtin for WasiSandboxShell (gh-1393: extracted from
// wasm_shell.dart so the primary file stays under the 2800-line guard —
// the wasm_shell_stages.dart pattern; same library scope, so the private
// stage-runner/path helpers stay reachable).
//
// The rg-forwarding grep (the WASI fallback layer) rides the SHARED argv
// parser (grep_args.dart): one parse backs the WASI rg path, the Dart-grep
// fallback and the web MemoryShell.

part of 'wasm_shell.dart';

extension _WasiShellGrep on WasiSandboxShell {
  Future<Result<StageResult, ExecutionError>> _grepBuiltin(
    Stage stage,
    ShellExecOptions? options,
    String? inputSource,
  ) async {
    final parsed = parseGrepArgs(stage.args);
    if (parsed == null) {
      return Ok(
        StageResult(
          stdout: const [],
          stderr: utf8.encode('grep: option requires an argument -- e\n'),
          exitCode: 2,
        ),
      );
    }
    if (!parsed.isUsable) {
      return Ok(
        StageResult(
          stdout: const [],
          stderr: utf8.encode(parsed.error!),
          exitCode: 2,
        ),
      );
    }
    final pattern = parsed.pattern;
    final quiet = parsed.quiet;

    if (pattern == null) {
      return Ok(
        StageResult(
          stdout: const [],
          stderr: utf8.encode(
            'usage: grep [-ivwxFcclnq] [-m N] [-A N] [-B N] [-C N] '
            '[--include=GLOB] [--exclude=GLOB] pattern [file...]\n',
          ),
          exitCode: 2,
        ),
      );
    }
    final files = _grepInputFiles(parsed, inputSource, _effectiveCwd(options));

    // `--include=`/`--exclude=` ride rg's `-g` glob filters (bash parity:
    // traversal already covers rg's defaults via --no-ignore --hidden).
    // The pattern rides `-e` (position-safe) and the argv is built by the
    // SHARED parser (grep_args.dart), so the flags the field evidence broke
    // on (`-rl`, `--include=`, `\|`) translate exactly once for both shells.
    final rgResult = await _runStage(
      command: 'rg',
      args: [
        ...parsed.flags,
        for (final glob in parsed.includeGlobs) ...['-g', glob],
        for (final glob in parsed.excludeGlobs) ...['-g', '!$glob'],
        '--no-ignore',
        '--hidden',
        '-e',
        pattern,
        ...files,
      ],
      options: options,
      captureStdout: true,
      captureStderr: true,
    );
    if (rgResult.isErr) return rgResult;
    final data = rgResult.valueOrNull!;
    return Ok(
      StageResult(
        stdout: quiet ? const [] : data.stdout,
        stderr: data.stderr,
        exitCode: data.exitCode,
      ),
    );
  }

  /// Assembles grep's file operand list: the parsed operands, plus the
  /// piped input when no file was given; every operand is rewritten
  /// against [cwd] the way `rg` positional paths are.
  List<String> _grepInputFiles(
    GrepArgs parsed,
    String? inputSource,
    String cwd,
  ) {
    final files = List<String>.of(parsed.files);
    if (files.isEmpty && inputSource != null) files.add(inputSource);
    return [for (final file in files) _maybeRewritePath('rg', file, cwd)];
  }
}
