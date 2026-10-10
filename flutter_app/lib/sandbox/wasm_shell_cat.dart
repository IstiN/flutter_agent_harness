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
    final files = [...parsed.files];
    if (files.isEmpty && inputSource != null) files.add(inputSource);
    final cwd = _effectiveCwd(options);
    final stdinText = await _stdinFromSource(stage, inputSource);
    final out = BytesBuilder(copy: false);
    final err = StringBuffer();
    var exitCode = 0;
    for (final file in files) {
      if (file == '-') {
        out.add(utf8.encode(stdinText ?? ''));
        continue;
      }
      // A builtin:// URI is its own operand namespace (C1: fs paths and
      // builtin URIs are equivalent for reads) — it must NEVER ride the
      // sandbox path resolver, which would mangle it into a guest path.
      if (file.startsWith(builtinSkillPathPrefix)) {
        final embedded = builtinSkillTextAt(file);
        if (embedded == null) {
          err.write('cat: $file: No such file or directory\n');
          exitCode = 1;
          continue;
        }
        out.add(utf8.encode(_catNumbered(embedded, parsed)));
        continue;
      }
      final path = _resolveSandboxPath(file, cwd);
      // Byte-first: an existing operand is delivered verbatim (the
      // coreutils applet was binary-safe; the seam must not regress that —
      // tarballs/PNGs ride cat). Only a MISSING operand consults pointer
      // machinery, and pointer files are harness-authored text.
      final bytes = await _readSandboxBytes(path);
      if (bytes != null) {
        if (parsed.number || parsed.numberNonBlank) {
          // GNU cat -n/-b on binary is a mangled best effort; decode
          // lossily rather than throwing the operand out of exec().
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
        continue;
      }
      final followed = await followSkillPointer(path, _readSandboxText);
      switch (followed) {
        case SkillPointerResolved(:final text):
          out.add(utf8.encode(_catNumbered(text, parsed)));
        case SkillPointerRefused(:final reason):
          err.write('cat: $file: skill pointer refused: $reason\n');
          exitCode = 1;
        case SkillPointerAbsent():
          err.write('cat: $file: No such file or directory\n');
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

  /// Applies `cat` numbering only when the invocation asked for it.
  String _catNumbered(String text, CatInvocation parsed) =>
      parsed.number || parsed.numberNonBlank
      ? applyCatNumbering(text, nonBlankOnly: parsed.numberNonBlank)
      : text;
}
