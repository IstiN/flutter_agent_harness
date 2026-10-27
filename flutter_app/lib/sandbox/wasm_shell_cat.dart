// Cat builtin for WasiSandboxShell (gh-1444 rework: extracted from
// wasm_shell.dart so the primary file stays under the 2800-line guard —
// the wasm_shell_grep.dart pattern; same library scope, so the private
// stage-runner/path helpers stay reachable).
//
// The cat seam (gh-1444 C1/AC1): a `builtin://skills/...` operand, or a
// missing operand whose `<path>.pointer` sibling resolves, rides pointer
// machinery; every existing operand stays on the byte-safe builtin path
// (the coreutils.wasm applet was binary-safe and must not regress).

part of 'wasm_shell.dart';

extension _WasiShellCat on WasiSandboxShell {
  /// True when a `cat` invocation touches pointer semantics (gh-1444 C1):
  /// a `builtin://skills/...` operand, or a missing operand whose
  /// `<path>.pointer` sibling resolves (the seam rule: an existing file
  /// always wins). Plain cats stay on the coreutils.wasm applet path so
  /// the host-cwd argument projection (gh-1274, issue #1335) keeps
  /// applying byte-identically.
  Future<bool> _catNeedsPointerSeam(
    List<String> args,
    ShellExecOptions? options,
    String? inputSource,
  ) async {
    final parsed = parseCatArgs(args);
    if (parsed.error != null) return false;
    final files = [...parsed.files];
    if (files.isEmpty && inputSource != null) files.add(inputSource);
    final cwd = _effectiveCwd(options);
    for (final file in files) {
      if (file == '-') continue;
      if (file.startsWith(builtinSkillPathPrefix)) return true;
      final path = _resolveSandboxPath(file, cwd);
      // Existence probe only: an existing operand always wins and the
      // coreutils applet is binary-safe, so the seam must never read bytes
      // through a UTF-8 text API (gh-1444 review: cat of a downloaded
      // tarball/PNG threw a FileSystemException out of exec()).
      if (await _hostFile(path).exists()) continue;
      final followed = await followSkillPointer(path, _readSandboxText);
      if (followed is! SkillPointerAbsent) return true;
    }
    return false;
  }

  /// The `cat` operand list: the parsed files, or stdin's `-` when no
  /// operand was given but input is piped.
  static List<String> _catOperands(CatInvocation parsed, String? inputSource) {
    final files = [...parsed.files];
    if (files.isEmpty && inputSource != null) files.add(inputSource);
    return files;
  }

  /// The `cat` builtin (gh-1444 C1): reads operands through the shell's
  Future<Result<StageResult, ExecutionError>> _catBuiltin(
    Stage stage,
    ShellExecOptions? options,
    String? inputSource,
  ) async {
    final parsed = parseCatArgs(stage.args);
    if (parsed.error != null) {
      return Ok(
        StageResult(
          stdout: const [],
          stderr: utf8.encode('cat: ${parsed.error}\n'),
          exitCode: 1,
        ),
      );
    }
    final files = _catOperands(parsed, inputSource);
    final cwd = _effectiveCwd(options);
    final stdinText = await _stdinFromSource(stage, inputSource);
    final out = BytesBuilder(copy: false);
    final err = StringBuffer();
    var exitCode = 0;
    for (final file in files) {
      final error = await _catSingle(file, parsed, stdinText, cwd, out);
      if (error != null) {
        err.write(error);
        exitCode = 1;
      }
    }
    return Ok(
      StageResult(
        stdout: out.toBytes(),
        stderr: utf8.encode(err.toString()),
        exitCode: exitCode,
      ),
    );
  }

  /// Consumes one `cat` operand into [out]. Returns the error line when
  /// the operand cannot be read, else null.
  Future<String?> _catSingle(
    String file,
    CatInvocation parsed,
    String? stdinText,
    String cwd,
    BytesBuilder out,
  ) async {
    if (file == '-') {
      out.add(utf8.encode(stdinText ?? ''));
      return null;
    }
    // A builtin:// URI is its own operand namespace (C1: fs paths and
    // builtin URIs are equivalent for reads) — it must NEVER ride the
    // sandbox path resolver, which would mangle it into a guest path.
    if (file.startsWith(builtinSkillPathPrefix)) {
      final embedded = builtinSkillTextAt(file);
      if (embedded == null) {
        return 'cat: $file: No such file or directory\n';
      }
      out.add(utf8.encode(_catNumbered(embedded, parsed)));
      return null;
    }
    return _catPath(file, _resolveSandboxPath(file, cwd), parsed, out);
  }

  /// Reads one filesystem operand: byte-first when it exists (the
  /// coreutils applet was binary-safe; the seam must not regress that —
  /// tarballs/PNGs ride cat), then pointer machinery for a MISSING
  /// operand. Returns the error line, or null on success.
  Future<String?> _catPath(
    String file,
    String path,
    CatInvocation parsed,
    BytesBuilder out,
  ) async {
    final bytes = await _readSandboxBytes(path);
    if (bytes != null) {
      _catNumberedBytes(bytes, parsed, out);
      return null;
    }
    return _catPointer(path, file, parsed, out);
  }

  /// Adds [bytes] to [out], applying `cat -n`/`-b` numbering when the
  /// invocation asked for it (GNU cat on binary is a mangled best
  /// effort; decode lossily rather than throwing the operand out of
  /// exec()).
  static void _catNumberedBytes(
    List<int> bytes,
    CatInvocation parsed,
    BytesBuilder out,
  ) {
    if (parsed.number || parsed.numberNonBlank) {
      out.add(
        utf8.encode(
          applyCatNumbering(
            utf8.decode(bytes, allowMalformed: true),
            nonBlankOnly: parsed.numberNonBlank,
          ),
        ),
      );
    } else {
      out.add(bytes);
    }
  }

  /// The pointer fallback for a missing operand (gh-1444 C1). Returns
  /// the error line, or null after the resolved text was written.
  Future<String?> _catPointer(
    String path,
    String file,
    CatInvocation parsed,
    BytesBuilder out,
  ) async {
    final followed = await followSkillPointer(path, _readSandboxText);
    switch (followed) {
      case SkillPointerResolved(:final text):
        out.add(utf8.encode(_catNumbered(text, parsed)));
        return null;
      case SkillPointerRefused(:final reason):
        return 'cat: $file: skill pointer refused: $reason\n';
      case SkillPointerAbsent():
        return 'cat: $file: No such file or directory\n';
    }
  }

  /// Applies `cat` numbering only when the invocation asked for it.
  String _catNumbered(String text, CatInvocation parsed) =>
      parsed.number || parsed.numberNonBlank
      ? applyCatNumbering(text, nonBlankOnly: parsed.numberNonBlank)
      : text;
}
