/// Issue #1083: parallel same-file `edit`/`write` tool calls must never
/// silently lose writes. The per-path mutation lock serializes the mutating
/// built-ins on the resolved absolute path; the deterministic-latch fixtures
/// below force the exact read-read-write-write interleaving that used to
/// lose bytes and prove it now queues instead.
///
/// AC map: UT-1 (AC1), edit/write mix (AC2), different-file overlap (AC3),
/// hashline same-tag batch (AC4), agent-loop end-to-end (AC5/IT-1).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

String _text(ToolExecutionResult result) {
  return result.content.whereType<TextContent>().map((b) => b.text).join();
}

/// In-memory [ExecutionEnv] with single-shot latches in the read/write
/// window: a test parks a tool call inside its lock-protected mutation
/// window and then observes who else manages to enter. Gates key on the
/// path spelling the tool call passes.
final class _GatedEnv implements ExecutionEnv {
  _GatedEnv({this.cwd = '/w'}) : _delegate = MemoryExecutionEnv(cwd: cwd);

  @override
  final String cwd;

  final MemoryExecutionEnv _delegate;

  /// Consumed by the first read of the keyed path.
  final readGates = <String, Completer<void>>{};

  /// Consumed by the first write of the keyed path.
  final writeGates = <String, Completer<void>>{};

  /// How many tool writes were actually parked on a gate.
  int gatedWrites = 0;

  /// When true, [absolutePath] mimics production IO envs: prefix cwd with
  /// NO `.`/`..` normalization (`io_execution_env._resolve` semantics).
  bool rawAbsolutePaths = false;

  /// Fires with every raw read path as it enters the window.
  void Function(String path)? onReadStart;

  final reads = <String>[];
  final writes = <String>[];

  @override
  Future<Result<String, FileError>> readTextFile(String path) async {
    reads.add(path);
    onReadStart?.call(path);
    final gate = readGates.remove(path);
    if (gate != null) await gate.future;
    return _delegate.readTextFile(path);
  }

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) async {
    writes.add(path);
    final gate = writeGates.remove(path);
    if (gate != null) {
      gatedWrites++;
      await gate.future;
    }
    return _delegate.writeFile(path, content);
  }

  // -- plain forwards ------------------------------------------------------

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      rawAbsolutePaths
          ? Future.value(Ok(path.startsWith('/') ? path : '$cwd/$path'))
          : _delegate.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _delegate.joinPath(parts);

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _delegate.readBinaryFile(path);

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _delegate.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _delegate.writeBinaryFile(path, content);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _delegate.appendFile(path, content);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _delegate.fileInfo(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _delegate.listDir(path);

  @override
  Future<Result<bool, FileError>> exists(String path) =>
      _delegate.exists(path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _delegate.createDir(path, recursive: recursive);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _delegate.remove(path, recursive: recursive, force: force);

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _delegate.exec(command, options: options);
}

/// Records a full read the way the hashline read tool does and returns the
/// tag a model would cite (same minting convention as patcher_test).
Future<String> _recordFullRead(
  ExecutionEnv env,
  HashlineSnapshotStore store,
  String path,
) async {
  final body = (await env.readTextFile(path)).valueOrNull!;
  final normalized = normalizeToLF(stripBom(body).text);
  final canonical = (await env.absolutePath(path)).valueOrNull ?? path;
  return store.record(canonical, normalized, [
    for (var i = 1; i <= normalized.split('\n').length; i++) i,
  ]);
}

/// Pumps the event loop until [ready] turns true, so a launched tool call
/// deterministically reaches the awaited point before the test proceeds.
Future<void> _pumpUntil(
  bool Function() ready, {
  String reason = 'condition not reached',
  int maxTurns = 2000,
}) async {
  for (var i = 0; i < maxTurns && !ready(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(ready(), isTrue, reason: reason);
}

/// Pumps a fixed number of event-loop turns: anything not blocked behind
/// the lock has ample room to run.
Future<void> _pumpTurns([int turns = 25]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
    errorMessage: null,
    timestamp: DateTime.utc(2026),
  );
}

/// A scripted turn that ends with tool calls.
List<AssistantMessageEvent> _toolTurn(
  List<ToolCall> calls, {
  StopReason reason = StopReason.toolUse,
}) {
  final empty = _assistant();
  final partial = _assistant(content: calls, stopReason: reason);
  final events = <AssistantMessageEvent>[StartEvent(partial: empty)];
  for (var i = 0; i < calls.length; i++) {
    events
      ..add(ToolCallStartEvent(contentIndex: i, partial: empty))
      ..add(
        ToolCallEndEvent(contentIndex: i, toolCall: calls[i], partial: partial),
      );
  }
  events.add(DoneEvent(reason: reason, message: partial));
  return events;
}

List<AssistantMessageEvent> _textTurn(String text) {
  final partial = _assistant(content: [TextContent(text: text)]);
  return [
    StartEvent(partial: _assistant()),
    TextStartEvent(contentIndex: 0, partial: partial),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

ToolCall _call(String id, String name, [Map<String, dynamic>? args]) {
  return ToolCall(id: id, name: name, arguments: args ?? const {});
}

/// Fake [StreamFunction]: replays scripted turns.
class _FakeStreamFunction {
  _FakeStreamFunction(this.turns);

  final List<List<AssistantMessageEvent>> turns;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final stream = AssistantMessageEventStream();
    for (final event in turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

void main() {
  group('per-path mutation lock: exact-match edits (issue #1083)', () {
    test('UT-1: two same-file edits in one parallel batch both apply '
        '(AC1)', () async {
      final env = _GatedEnv(cwd: '/w');
      await env.writeFile('f.md', 'A B');
      final edit = editFileTool(env);

      // Edit 1 acquires the lock and parks inside its read window.
      final gate = Completer<void>();
      env.readGates['f.md'] = gate;
      final first = edit.execute(
        {'path': 'f.md', 'oldText': 'A', 'newText': 'A1'},
        null,
        null,
      );
      await _pumpUntil(
        () => env.reads.length == 1,
        reason: 'edit 1 never entered its read window',
      );

      // Edit 2 must queue on the path lock: with the read gate still shut,
      // it can never reach its own read (the old code read concurrently).
      final second = edit.execute(
        {'path': 'f.md', 'oldText': 'B', 'newText': 'B1'},
        null,
        null,
      );
      await _pumpTurns();
      expect(env.reads.length, 1, reason: 'edit 2 raced past the lock');

      gate.complete();
      final results = await Future.wait([first, second]);
      expect(_text(results[0]), contains('Edited'));
      expect(_text(results[1]), contains('Edited'));
      expect(
        (await env.readTextFile('f.md')).valueOrNull,
        'A1 B1',
        reason: 'each edit must apply on top of the previous one',
      );
    });

    test('E1: aliased spellings of one file serialize too', () async {
      final env = _GatedEnv(cwd: '/w');
      await env.writeFile('f.md', 'A B');
      final edit = editFileTool(env);

      final gate = Completer<void>();
      env.readGates['f.md'] = gate;
      final first = edit.execute(
        {'path': 'f.md', 'oldText': 'A', 'newText': 'A1'},
        null,
        null,
      );
      await _pumpUntil(() => env.reads.length == 1);

      final second = edit.execute(
        {'path': './f.md', 'oldText': 'B', 'newText': 'B1'},
        null,
        null,
      );
      await _pumpTurns();
      expect(env.reads.length, 1, reason: './f.md must hit the same lock');

      gate.complete();
      await Future.wait([first, second]);
      expect((await env.readTextFile('f.md')).valueOrNull, 'A1 B1');
    });

    test('UT-2: edit + write on one path land in order without torn '
        'content (AC2)', () async {
      final env = _GatedEnv(cwd: '/w');
      await env.writeFile('g.md', 'seed');
      final write = writeFileTool(env);
      final edit = editFileTool(env);

      // The write parks inside its lock-protected writeFile window.
      final gate = Completer<void>();
      env.writeGates['g.md'] = gate;
      final writing = write.execute(
        {'path': 'g.md', 'content': 'BASE tail'},
        null,
        null,
      );
      await _pumpUntil(
        () => env.gatedWrites == 1,
        reason: 'write never entered its write window',
      );

      // The edit queues behind the write, then applies on top of it.
      final editing = edit.execute(
        {'path': 'g.md', 'oldText': 'BASE', 'newText': 'BASE·EDIT'},
        null,
        null,
      );
      await _pumpTurns();
      expect(env.reads, isEmpty, reason: 'edit raced past the write lock');

      gate.complete();
      final results = await Future.wait([writing, editing]);
      expect(_text(results[0]), contains('Successfully wrote'));
      expect(_text(results[1]), contains('Edited'));
      expect(
        (await env.readTextFile('g.md')).valueOrNull,
        'BASE·EDIT tail',
        reason: 'no torn content: write lands whole, edit applies on top',
      );
    });

    test('UT-3: edits to different files still run concurrently (AC3)',
        () async {
      final env = _GatedEnv(cwd: '/w');
      await env.writeFile('a.md', 'one');
      await env.writeFile('b.md', 'two');
      final edit = editFileTool(env);

      // Each edit parks in its read until the other entered its own: if
      // the locks over-serialize, this hangs and the timeout fails it.
      final gateA = Completer<void>();
      final gateB = Completer<void>();
      env.readGates
        ..['a.md'] = gateA
        ..['b.md'] = gateB;
      env.onReadStart = (path) {
        // Guarded: later verification reads re-enter this callback after
        // both gates have fired.
        if (path == 'a.md' && !gateB.isCompleted) {
          gateB.complete();
        } else if (path == 'b.md' && !gateA.isCompleted) {
          gateA.complete();
        }
      };

      final first = edit.execute(
        {'path': 'a.md', 'oldText': 'one', 'newText': 'ONE'},
        null,
        null,
      );
      final second = edit.execute(
        {'path': 'b.md', 'oldText': 'two', 'newText': 'TWO'},
        null,
        null,
      );
      final results = await Future.wait([first, second]).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw StateError(
          'AC3 regression: edits to different files no longer overlap',
        ),
      );
      expect(_text(results[0]), contains('Edited'));
      expect(_text(results[1]), contains('Edited'));
      expect((await env.readTextFile('a.md')).valueOrNull, 'ONE');
      expect((await env.readTextFile('b.md')).valueOrNull, 'TWO');
    });
  });

  group('per-path mutation lock: pairings, cancel, raw envs (review '
      '#1084)', () {
    test('E2: aliased spellings serialize even on a raw, non-normalizing '
        'env (production IO semantics)', () async {
      final env = _GatedEnv(cwd: '/w');
      // io_execution_env._resolve merely prefixes the cwd — lock keys must
      // not depend on the env collapsing `./`.
      env.rawAbsolutePaths = true;
      await env.writeFile('f.md', 'A B');
      final edit = editFileTool(env);

      final gate = Completer<void>();
      env.readGates['f.md'] = gate;
      final first = edit.execute(
        {'path': 'f.md', 'oldText': 'A', 'newText': 'A1'},
        null,
        null,
      );
      await _pumpUntil(() => env.reads.length == 1);

      final second = edit.execute(
        {'path': './f.md', 'oldText': 'B', 'newText': 'B1'},
        null,
        null,
      );
      await _pumpTurns();
      expect(
        env.reads.length,
        1,
        reason: './f.md must hit the same lock key as f.md on a raw env',
      );

      gate.complete();
      await Future.wait([first, second]);
      expect((await env.readTextFile('f.md')).valueOrNull, 'A1 B1');
    });

    test('UT-2c: a call cancelled while queued on the lock never mutates',
        () async {
      final env = _GatedEnv(cwd: '/w');
      await env.writeFile('g.md', 'seed');
      final write = writeFileTool(env);
      final edit = editFileTool(env);

      final gate = Completer<void>();
      env.writeGates['g.md'] = gate;
      final writing = write.execute(
        {'path': 'g.md', 'content': 'BASE tail'},
        null,
        null,
      );
      await _pumpUntil(() => env.gatedWrites == 1);

      final source = CancelTokenSource();
      final editing = edit.execute(
        {'path': 'g.md', 'oldText': 'BASE', 'newText': 'BASE·EDIT'},
        source.token,
        null,
      );
      await _pumpTurns();
      source.cancel('user changed direction');
      gate.complete();

      await expectLater(editing, throwsA(isA<CancelledException>()));
      expect(_text(await writing), contains('Successfully wrote'));
      expect(
        (await env.readTextFile('g.md')).valueOrNull,
        'BASE tail',
        reason: 'the cancelled edit must not run its mutation',
      );
    });

    test('P1: write + write on one path serialize — last content wins',
        () async {
      final env = _GatedEnv(cwd: '/w');
      await env.writeFile('w.md', 'seed');
      final write = writeFileTool(env);

      final gate = Completer<void>();
      env.writeGates['w.md'] = gate;
      final first = write.execute(
        {'path': 'w.md', 'content': 'one'},
        null,
        null,
      );
      await _pumpUntil(() => env.gatedWrites == 1);

      final second = write.execute(
        {'path': 'w.md', 'content': 'two'},
        null,
        null,
      );
      await _pumpTurns();
      expect(
        env.writes.length,
        2,
        reason: 'second write raced past the lock (seed + first = 2)',
      );

      gate.complete();
      final results = await Future.wait([first, second]);
      expect(_text(results[0]), contains('Successfully wrote'));
      expect(_text(results[1]), contains('Successfully wrote'));
      expect((await env.readTextFile('w.md')).valueOrNull, 'two');
    });

    test('P2: edit → write reversed pairing — the write still lands whole',
        () async {
      final env = _GatedEnv(cwd: '/w');
      await env.writeFile('g.md', 'seed');
      final edit = editFileTool(env);
      final write = writeFileTool(env);

      final gate = Completer<void>();
      env.readGates['g.md'] = gate;
      final editing = edit.execute(
        {'path': 'g.md', 'oldText': 'seed', 'newText': 'seed·EDIT'},
        null,
        null,
      );
      await _pumpUntil(() => env.reads.length == 1);

      final writing = write.execute(
        {'path': 'g.md', 'content': 'fresh'},
        null,
        null,
      );
      await _pumpTurns();
      expect(env.gatedWrites, 0, reason: 'write raced past the edit lock');

      gate.complete();
      final results = await Future.wait([editing, writing]);
      expect(_text(results[0]), contains('Edited'));
      expect(_text(results[1]), contains('Successfully wrote'));
      expect(
        (await env.readTextFile('g.md')).valueOrNull,
        'fresh',
        reason: 'a full overwrite after an edit replaces it — in order, '
            'never interleaved',
      );
    });

    test('P3: exact-match edit + same-tag hashline patch serialize — the '
        'patch rejects stale instead of double-writing', () async {
      final env = _GatedEnv(cwd: '/w');
      const content = 'alpha\nbeta\ngamma\n';
      await env.writeFile('h.md', content);
      final store = HashlineSnapshotStore();
      final edit = editFileTool(env, snapshots: store);
      final tag = await _recordFullRead(env, store, 'h.md');

      final gate = Completer<void>();
      env.readGates['h.md'] = gate;
      final exact = edit.execute(
        {'path': 'h.md', 'oldText': 'beta', 'newText': 'BETA'},
        null,
        null,
      );
      // reads[0] is the tag-minting read; reads[1] is the parked edit read.
      await _pumpUntil(() => env.reads.length == 2);

      final patch = edit.execute(
        {'patch': '[h.md#$tag]\nSWAP 1.=1:\n+ALPHA'},
        null,
        null,
      );
      await _pumpTurns();
      expect(
        env.reads.length,
        2,
        reason: 'patch raced past the exact edit',
      );

      gate.complete();
      expect(_text(await exact), contains('Edited'));
      await expectLater(patch, throwsA(isA<HashlineMismatchError>()));
      expect(
        (await env.readTextFile('h.md')).valueOrNull,
        'alpha\nBETA\ngamma\n',
        reason: 'the stale-tag patch must not write over the applied edit',
      );
    });
    test('UT-2cW: a WRITE cancelled while queued never mutates either',
        () async {
      final env = _GatedEnv(cwd: '/w');
      final write = writeFileTool(env);

      final gate = Completer<void>();
      env.writeGates['w.md'] = gate;
      final first = write.execute(
        {'path': 'w.md', 'content': 'one'},
        null,
        null,
      );
      await _pumpUntil(() => env.gatedWrites == 1);

      final source = CancelTokenSource();
      final second = write.execute(
        {'path': 'w.md', 'content': 'two'},
        source.token,
        null,
      );
      await _pumpTurns();
      source.cancel('superseded');
      gate.complete();

      await expectLater(second, throwsA(isA<CancelledException>()));
      expect(_text(await first), contains('Successfully wrote'));
      expect(
        (await env.readTextFile('w.md')).valueOrNull,
        'one',
        reason: 'the cancelled write must not run its mutation',
      );
    });

    test('UT-3r: a hashline patch recovered onto another file holds that '
        "file's lock too", () async {
      final env = _GatedEnv(cwd: '/w');
      const content = 'alpha\nbeta\ngamma\n';
      await env.writeFile('real.md', content);
      final store = HashlineSnapshotStore();
      final edit = editFileTool(env, snapshots: store);
      final tag = await _recordFullRead(env, store, 'real.md');

      final gate = Completer<void>();
      // The recovery read targets the snapshot's canonical path.
      env.readGates['/w/real.md'] = gate;

      // The patch names a MISSING sibling directory spelling; the tag and
      // basename redirect it onto /w/real.md (patcher path recovery).
      final patch = edit.execute(
        {'patch': '[sub/real.md#$tag]\nSWAP 1.=1:\n+ALPHA'},
        null,
        null,
      );
      // reads[0] = tag mint; reads[1] = the patch's missing-path probe;
      // reads[2] = the patch's recovered read of real.md, parked on the
      // gate while the patch holds BOTH lock keys.
      await _pumpUntil(() => env.reads.length == 3);

      final exact = edit.execute(
        {'path': 'real.md', 'oldText': 'beta', 'newText': 'BETA'},
        null,
        null,
      );
      await _pumpTurns();
      expect(
        env.reads.length,
        3,
        reason: 'exact edit raced past the recovered patch: the patch '
            'never names real.md directly, yet must hold its lock',
      );

      gate.complete();
      expect(_text(await patch), contains('real.md#'));
      expect(_text(await exact), contains('Edited'));
      expect(
        (await env.readTextFile('real.md')).valueOrNull,
        'ALPHA\nBETA\ngamma\n',
        reason: 'both mutations land serialized on the recovered file',
      );
    });
    test('UT-2cH: a hashline PATCH cancelled while queued never mutates '
        'either', () async {
      final env = _GatedEnv(cwd: '/w');
      const content = 'alpha\nbeta\ngamma\n';
      await env.writeFile('f.txt', content);
      final store = HashlineSnapshotStore();
      final edit = editFileTool(env, snapshots: store);
      final tag = await _recordFullRead(env, store, 'f.txt');

      final gate = Completer<void>();
      env.readGates['f.txt'] = gate;
      final holder = edit.execute(
        {'patch': '[f.txt#$tag]\nSWAP 1.=1:\n+ALPHA'},
        null,
        null,
      );
      // reads[0] = tag mint; reads[1] = the holder patch's parked read.
      await _pumpUntil(() => env.reads.length == 2);

      final source = CancelTokenSource();
      final queued = edit.execute(
        {'patch': '[f.txt#$tag]\nSWAP 1.=1:\n+BETA'},
        source.token,
        null,
      );
      await _pumpTurns();
      source.cancel('superseded');
      gate.complete();

      // Cancel wins before the stale-tag guard: the queued patch throws
      // CancelledException on acquisition and never even reads the file.
      await expectLater(queued, throwsA(isA<CancelledException>()));
      expect(_text(await holder), contains('[f.txt#'));
      expect(
        (await env.readTextFile('f.txt')).valueOrNull,
        'ALPHA\nbeta\ngamma\n',
        reason: 'the cancelled patch must not run its mutation',
      );
    });
  });

  group('per-path mutation lock: hashline patches (issue #1083)', () {
    test('UT-4: two same-tag patches in one batch — exactly one applies, '
        'the other rejects stale (AC4)', () async {
      final env = MemoryExecutionEnv(cwd: '/w');
      const content = 'alpha\nbeta\ngamma\ndelta\n';
      await env.writeFile('f.txt', content);
      final store = HashlineSnapshotStore();
      final edit = editFileTool(env, snapshots: store);
      final tag = await _recordFullRead(env, store, 'f.txt');

      // Both patches carry the SAME snapshot tag: serialized on the path,
      // the first applies and mints a new tag, the second must fail the
      // stale-tag guard — never silently double-apply.
      final first = edit.execute(
        {'patch': '[f.txt#$tag]\nSWAP 2.=2:\n+BETA1'},
        null,
        null,
      );
      final second = edit.execute(
        {'patch': '[f.txt#$tag]\nSWAP 2.=2:\n+BETA2'},
        null,
        null,
      );
      final outcomes = await Future.wait([
        first.then<Object?>((result) => result, onError: (Object e) => e),
        second.then<Object?>((result) => result, onError: (Object e) => e),
      ]).timeout(const Duration(seconds: 10));

      final successes = outcomes
          .whereType<ToolExecutionResult>()
          .length;
      expect(successes, 1, reason: 'exactly one same-tag patch may apply');
      final errors = outcomes
          .where((outcome) => outcome is! ToolExecutionResult)
          .toList();
      expect(errors.single, isA<HashlineMismatchError>());
      final finalContent = (await env.readTextFile('f.txt')).valueOrNull;
      expect(
        finalContent == 'alpha\nBETA1\ngamma\ndelta\n' ||
            finalContent == 'alpha\nBETA2\ngamma\ndelta\n',
        isTrue,
        reason: 'final content must be one clean edit, not a mix',
      );
    });

    test('UT-4b: the rejected patch fails loudly with a stale-tag '
        'mismatch', () async {
      final env = MemoryExecutionEnv(cwd: '/w');
      const content = 'alpha\nbeta\ngamma\ndelta\n';
      await env.writeFile('f.txt', content);
      final store = HashlineSnapshotStore();
      final edit = editFileTool(env, snapshots: store);
      final tag = await _recordFullRead(env, store, 'f.txt');

      Object? rejection;
      await edit.execute(
        {'patch': '[f.txt#$tag]\nSWAP 2.=2:\n+BETA1'},
        null,
        null,
      );
      try {
        await edit.execute(
          {'patch': '[f.txt#$tag]\nSWAP 2.=2:\n+BETA2'},
          null,
          null,
        );
      } on Object catch (error) {
        rejection = error;
      }
      expect(rejection, isA<HashlineMismatchError>());
      expect(
        (await env.readTextFile('f.txt')).valueOrNull,
        'alpha\nBETA1\ngamma\ndelta\n',
      );
    });
  });

  group('per-path mutation lock: end-to-end (issue #1083)', () {
    test('IT-1: five same-file edits in one scripted batch all land '
        '(AC5)', () async {
      final env = MemoryExecutionEnv(cwd: '/w');
      await env.writeFile('goal.md', 'one two three four five\n');
      final edit = editFileTool(env);
      final fake = _FakeStreamFunction([
        _toolTurn([
          _call('c1', 'edit', {
            'path': 'goal.md',
            'oldText': 'one',
            'newText': 'ONE',
          }),
          _call('c2', 'edit', {
            'path': 'goal.md',
            'oldText': 'two',
            'newText': 'TWO',
          }),
          _call('c3', 'edit', {
            'path': 'goal.md',
            'oldText': 'three',
            'newText': 'THREE',
          }),
          _call('c4', 'edit', {
            'path': 'goal.md',
            'oldText': 'four',
            'newText': 'FOUR',
          }),
          _call('c5', 'edit', {
            'path': 'goal.md',
            'oldText': 'five',
            'newText': 'FIVE',
          }),
        ]),
        _textTurn('all edits applied'),
      ]);

      final stream = agentLoop(
        prompts: [UserMessage.text('apply the edits')],
        context: Context(messages: const [], tools: [edit]),
        config: const AgentLoopConfig(model: _model),
        streamFunction: fake.call,
        toolExecutor: (toolCall, cancelToken, onUpdate) =>
            edit.execute(toolCall.arguments, cancelToken, onUpdate),
      );

      final events = await stream.toList();
      final ends = events.whereType<ToolExecutionEndEvent>().toList();
      expect(ends, hasLength(5));
      expect(
        ends.every((event) => !event.isError),
        isTrue,
        reason:
            'every same-file edit must succeed under the lock: '
            '${[for (final e in ends) e.toString()]}',
      );
      expect(
        (await env.readTextFile('goal.md')).valueOrNull,
        'ONE TWO THREE FOUR FIVE\n',
      );
    });
  });
}
