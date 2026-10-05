/// The mutating file tools and their shared guard: the per-path mutation lock [_PathMutationLock] (issue #1083), the `write` tool ([writeFileTool]), and the `edit` tool ([editFileTool]) with its exact-match and hashline execution paths. Split out of `builtin_tools.dart` to keep that file under the repo line gate; same library (a `part of`), so the privates stay visible.
part of 'builtin_tools.dart';

// ---------------------------------------------------------------------------
// per-path mutation lock (issue #1083)
// ---------------------------------------------------------------------------

/// Serializes mutating built-in tools (`write`, `edit`) on the same resolved
/// file path (issue #1083): a parallel batch of same-file edits used to
/// interleave their read-modify-write windows — every call reported success
/// but only the last write survived on disk. Holding the whole
/// read-validate-write body makes each edit apply on top of the previous
/// one; different files and read-only tools are unaffected. The registry is
/// process-wide, matching the conflict domain: one agent process
/// (cross-process locking is a separate OS-level problem, out of scope).
///
/// ponytail: covers the built-in file tools only; third-party plugin file
/// tools don't inherit this yet — lift the guard into the ToolExecutor keyed
/// by a `mutatesPath` tool hint if plugins ever need it.
final _pathMutationLock = _PathMutationLock();

/// The canonical lock key for [path]: the env-absolute spelling collapsed
/// to one POSIX-normal form, so aliased spellings of one file (`f.md`,
/// `./f.md`, `x/../f.md`) serialize together on EVERY env — production IO
/// envs do not normalize (`io_execution_env._resolve` merely prefixes the
/// cwd) while [MemoryExecutionEnv] does, so the lock must not rely on
/// either. Mirrors `HashlinePatcher._canonicalPath` for the absolute step;
/// symlink aliasing stays out of scope (the pure-Dart env seam does not
/// resolve links).
///
/// Documented residual (issue #1083 review round 2): on case-insensitive
/// backends (macOS default APFS, Windows) `F.md` and `f.md` are one file
/// but keep two lock keys. The env seam carries no case-sensitivity
/// signal, and folding keys unconditionally would spuriously serialize
/// distinct files on case-sensitive backends (Linux production targets) —
/// the same out-of-scope class as symlink aliasing above.
Future<String> _canonicalPath(ExecutionEnv env, String path) async {
  final resolved = await env.absolutePath(path);
  return _normalizeLockKey(resolved.valueOrNull ?? path);
}

/// Collapses duplicate separators, `.` and `..` segments so one absolute
/// file has exactly one lock-key spelling. Windows drive letters survive
/// as a segment — keys only need to be equal iff the spellings alias.
String _normalizeLockKey(String path) {
  final out = <String>[];
  for (final segment in path.replaceAll('\\', '/').split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(segment);
  }
  return '/${out.join('/')}';
}

/// Per-path async mutex. Waiters chain per key: a body runs only after the
/// previous body for the same path settled. Every wait is single-resource
/// (one path), so acquisition order can never deadlock and no timeouts are
/// needed (issue #1083 E2).
final class _PathMutationLock {
  final _tails = <String, Future<void>>{};

  /// Runs [body] holding the lock on [path].
  Future<T> run<T>(String path, Future<T> Function() body) {
    final previous = _tails[path];
    final released = Completer<void>();
    _tails[path] = released.future;
    return Future<T>(() async {
      // [previous] always settles normally — [released] completes in a
      // finally below, so a failed body leaves its error with its own
      // caller and merely frees the path.
      if (previous != null) await previous;
      try {
        return await body();
      } finally {
        released.complete();
        if (identical(_tails[path], released.future)) _tails.remove(path);
      }
    });
  }

  /// Runs [body] holding the locks on every distinct [paths] entry,
  /// acquired in sorted order to keep multi-path waits deadlock-free.
  Future<T> runAll<T>(Iterable<String> paths, Future<T> Function() body) {
    final ordered = paths.toSet().toList()..sort();
    Future<T> acquire(int index) => index == ordered.length
        ? Future<T>(body)
        : run(ordered[index], () => acquire(index + 1));
    return acquire(0);
  }
}

// ---------------------------------------------------------------------------
// write (ported from pi's tools/write.ts)
// ---------------------------------------------------------------------------

/// Creates the `write` tool: creates or overwrites a file, creating parent
/// directories as needed.
AgentTool writeFileTool(ExecutionEnv env) {
  return AgentTool(
    name: 'write',
    label: 'write',
    tier: ApprovalTier.write,
    description:
        'Write content to a file, creating parent directories as needed. '
        'Overwrites the file if it already exists.',
    parameters: const {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'Path to the file to write (relative or absolute)',
        },
        'content': {
          'type': 'string',
          'description': 'Content to write to the file',
        },
      },
      'required': ['path', 'content'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final path = arguments['path'] as String;
      final content = arguments['content'] as String;
      // Issue #1083: hold the per-path lock across the whole mutation so a
      // concurrent same-file tool call queues behind it instead of racing.
      return _pathMutationLock.run(await _canonicalPath(env, path), () async {
        // Re-check after the lock wait: the queue can span a cancel, and a
        // cancelled call must not run its mutation once its turn arrives.
        cancelToken?.throwIfCancelled();
        final written = await env.writeFile(path, content);
        if (written.isErr) throw StateError('${written.errorOrNull}');
        return ToolExecutionResult.text(
          'Successfully wrote ${_byteLength(content)} bytes to $path',
        );
      });
    },
  );
}

// ---------------------------------------------------------------------------
// edit (exact-match replace, or hashline patch with content-hash anchors)
// ---------------------------------------------------------------------------

/// Creates the `edit` tool: edits a file in one of two modes.
///
/// Legacy exact-match mode (`path` + `oldText` + `newText`): the replacement
/// only happens when `oldText` occurs exactly once — the cheap, model-friendly
/// way to make precise code edits without rewriting whole files (mirrors pi's
/// `edit` and Claude Code's `str_replace` tools).
///
/// Hashline mode (`patch`): a hashline patch with `[path#TAG]` section
/// headers and `SWAP`/`DEL`/`INS` ops on 1-indexed line anchors, ported from
/// oh-my-pi `packages/hashline`. The tag is a whole-file content hash minted
/// by a hashline-mode `read` (or a previous edit response); a stale tag is
/// rejected BEFORE any write with a diagnostic naming the drifted lines, so
/// a mistargeted edit can never silently corrupt the file.
///
/// [snapshots] is the session snapshot store binding tags to file content;
/// share it with the `read` tool (via [builtinTools]) so read-minted tags
/// validate here.
AgentTool editFileTool(ExecutionEnv env, {HashlineSnapshotStore? snapshots}) {
  final store = snapshots ?? HashlineSnapshotStore();
  return AgentTool(
    name: 'edit',
    label: 'edit',
    tier: ApprovalTier.write,
    description: editToolDescriptionPrompt,
    parameters: const {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description':
              'Path to the file to edit (relative or absolute). Required '
              'for exact-match mode; optional in hashline mode (the patch '
              'header carries its own [path#TAG]).',
        },
        'oldText': {
          'type': 'string',
          'description':
              'Exact-match mode: exact text to replace. Must occur exactly '
              'once in the file.',
        },
        'newText': {
          'type': 'string',
          'description':
              'Exact-match mode: replacement text (may be empty to delete '
              'oldText).',
        },
        'patch': {
          'type': 'string',
          'description':
              'Hashline mode: a hashline patch — [path#TAG] section '
              'header(s) followed by SWAP/DEL/INS ops anchored on line '
              'numbers from a hashline-mode read.',
        },
      },
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final path = arguments['path'] as String?;
      final oldText = arguments['oldText'] as String?;
      final newText = arguments['newText'] as String?;
      final patch = arguments['patch'] as String?;

      // Issue #862: an unambiguous both-modes mix is coerced (patch wins;
      // a malformed patch with a complete exact-match triple falls back),
      // never looped on. Only "neither mode complete" rejects, with a
      // remedy example.
      final plan = resolveEditMode(
        path: path,
        oldText: oldText,
        newText: newText,
        patch: patch,
      );
      switch (plan) {
        case EditReject(:final message):
          throw StateError(message);
        case EditRunPatch(:final parsed, :final notice):
          // The plan carries the ONE shared parse (issue #862 review):
          // no re-parse here, so the gate and the apply cannot drift.
          // Lock every file the patch can touch: the authored section paths
          // AND the canonical paths that minted each cited tag — the
          // patcher's missing-path recovery (_recoverSectionPathFromTag) can
          // redirect a section onto a snapshot's file, which must not race
          // its own mutations either. Extra keys only over-lock briefly;
          // sorted acquisition in [runAll] keeps that deadlock-free.
          final keys = <String>{
            for (final section in parsed.sections)
              await _canonicalPath(env, section.path),
            for (final section in parsed.sections)
              if (section.fileHash != null)
                for (final snapshot in store.findByHash(section.fileHash!))
                  _normalizeLockKey(snapshot.path),
          };
          final result = await _pathMutationLock.runAll(keys, () {
            // Re-check after the lock wait: the queue can span a cancel.
            cancelToken?.throwIfCancelled();
            return _executeHashlineEdit(env, store, path, parsed, cancelToken);
          });
          return _withNotice(result, notice);
        case EditRunExactMatch(
          :final path,
          :final oldText,
          :final newText,
          :final notice,
        ):
          // Issue #1083: hold the lock across the read-validate-write window
          // so a concurrent same-file edit applies on top of this one's
          // result instead of both editing the same snapshot.
          final result = await _pathMutationLock.run(
            await _canonicalPath(env, path),
            () {
              // Re-check after the lock wait: the queue can span a cancel.
              cancelToken?.throwIfCancelled();
              return _executeExactMatchEdit(
                env,
                path,
                oldText,
                newText,
                cancelToken,
              );
            },
          );
          return _withNotice(result, notice);
      }
    },
  );
}

/// Appends a coercion [notice] to a successful [result]'s text (issue #862):
/// the model must see what was ignored so the next call carries one mode.
ToolExecutionResult _withNotice(ToolExecutionResult result, String? notice) {
  if (notice == null) return result;
  return ToolExecutionResult(
    content: [
      ...result.content,
      TextContent(text: '\n$notice'),
    ],
    terminate: result.terminate,
  );
}

Future<ToolExecutionResult> _executeExactMatchEdit(
  ExecutionEnv env,
  String path,
  String oldText,
  String newText,
  CancelToken? cancelToken,
) async {
  if (oldText.isEmpty) {
    throw StateError('oldText must not be empty');
  }

  final read = await env.readTextFile(path);
  if (read.isErr) throw StateError('${read.errorOrNull}');
  cancelToken?.throwIfCancelled();
  final content = read.valueOrNull!;

  final occurrences = _countOccurrences(content, oldText);
  if (occurrences == 0) {
    throw StateError(
      'No exact match found in $path. oldText must match the file '
      'contents byte-for-byte (check whitespace and newlines with read).',
    );
  }
  if (occurrences > 1) {
    throw StateError(
      'oldText occurs $occurrences times in $path and is ambiguous. '
      'Include more surrounding context so it matches exactly once.',
    );
  }

  final updated = content.replaceFirst(oldText, newText);
  final written = await env.writeFile(path, updated);
  if (written.isErr) throw StateError('${written.errorOrNull}');

  return ToolExecutionResult.text(
    'Edited $path: replaced ${_byteLength(oldText)} bytes with '
    '${_byteLength(newText)} bytes.',
  );
}

/// Runs one hashline-mode edit: applies the parsed [patch] all-or-nothing
/// via [HashlinePatcher], and renders the post-edit `[path#TAG]` header(s)
/// the model anchors its next edit on (omp's edit response).
Future<ToolExecutionResult> _executeHashlineEdit(
  ExecutionEnv env,
  HashlineSnapshotStore store,
  String? path,
  HashlinePatch patch,
  CancelToken? cancelToken,
) async {
  final patcher = HashlinePatcher(env: env, snapshots: store);
  final result = await patcher.apply(patch);
  cancelToken?.throwIfCancelled();

  // Single-section no-op: the body rows matched the file byte-for-byte —
  // surface omp's soft diagnostic so the model re-reads instead of widening
  // the payload (multi-section no-ops already threw inside `apply`).
  if (result.sections.length == 1 &&
      result.sections[0].op == HashlineSectionOp.noop) {
    return ToolExecutionResult.text(
      noChangeDiagnostic(result.sections[0].path),
    );
  }

  final parts = <String>[];
  for (final section in result.sections) {
    final buffer = StringBuffer(section.header);
    if (section.firstChangedLine != null) {
      buffer.write('\nFirst change at line ${section.firstChangedLine}.');
    }
    if (section.warnings.isNotEmpty) {
      buffer.write('\n\nWarnings:\n${section.warnings.join('\n')}');
    }
    parts.add(buffer.toString());
  }
  return ToolExecutionResult.text(parts.join('\n\n'));
}

int _countOccurrences(String haystack, String needle) {
  var count = 0;
  var start = 0;
  while (true) {
    final index = haystack.indexOf(needle, start);
    if (index == -1) return count;
    count++;
    start = index + needle.length;
  }
}
