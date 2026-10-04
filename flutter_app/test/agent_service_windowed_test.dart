import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:fa/services/agent_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_test/flutter_test.dart';

StreamFunction _singleTextResponse(String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.now(),
    );
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  };
}

Agent _createAgent() {
  return Agent(
    model: Model(
      id: 'test-model',
      api: 'test-api',
      provider: 'test',
      baseUrl: 'https://example.com',
      contextWindow: 100000,
      maxTokens: 4096,
    ),
    systemPrompt: 'You are Fa.',
    streamFunction: _singleTextResponse('ok'),
    toolRegistry: ToolRegistry(const []),
  );
}

/// An [Agent] wired to a caller-supplied stream function — the mid-run
/// scenarios (#1159) script the streaming bubble themselves.
Agent _streamAgent(StreamFunction streamFunction) {
  return Agent(
    model: Model(
      id: 'test-model',
      api: 'test-api',
      provider: 'test',
      baseUrl: 'https://example.com',
      contextWindow: 100000,
      maxTokens: 4096,
    ),
    systemPrompt: 'You are Fa.',
    streamFunction: streamFunction,
    toolRegistry: ToolRegistry(const []),
  );
}

/// A [FileSystem] that tallies how many bytes each read strategy touched —
/// the O(window)-not-O(file) proof for issue #135 at the app level.
final class CountingFileSystem implements FileSystem, RangedReadFileSystem {
  CountingFileSystem(this.delegate);

  final FileSystem delegate;

  /// Bytes moved by ranged (seek) reads — the windowed path.
  int rangedBytes = 0;

  /// Bytes moved by whole-file reads — must stay 0 while windowed.
  int bulkBytes = 0;
  @override
  String get cwd => delegate.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      delegate.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      delegate.joinPath(parts);

  @override
  Future<Result<String, FileError>> readTextFile(String path) async {
    final result = await delegate.readTextFile(path);
    if (result.isOk) bulkBytes += result.valueOrNull!.length;
    return result;
  }

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) async {
    final result = await delegate.readBinaryFile(path);
    if (result.isOk) bulkBytes += result.valueOrNull!.length;
    return result;
  }

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => delegate.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => delegate.writeBinaryFile(path, content);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      delegate.writeFile(path, content);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      delegate.appendFile(path, content);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      delegate.fileInfo(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      delegate.listDir(path);

  @override
  Future<Result<bool, FileError>> exists(String path) => delegate.exists(path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => delegate.createDir(path, recursive: recursive);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => delegate.remove(path, recursive: recursive, force: force);
  @override
  Future<Result<Uint8List, FileError>> readRange(
    String path,
    int start,
    int end,
  ) async {
    final Result<Uint8List, FileError> result;
    if (delegate case final RangedReadFileSystem ranged) {
      result = await ranged.readRange(path, start, end);
    } else {
      result = Err(
        FileError(FileErrorCode.notSupported, 'no ranged reads', path: path),
      );
    }
    if (result.isOk) rangedBytes += result.valueOrNull!.length;
    return result;
  }
}

/// A [FileSystem] that parks the FIRST ranged read of [gatePath] after
/// [armGate] until [releaseGate] — freezes a page load mid-flight to
/// prove the generation race (issue #1159 E1).
final class GatedFileSystem implements FileSystem, RangedReadFileSystem {
  GatedFileSystem(this.delegate, {required this.gatePath});

  final FileSystem delegate;
  final String gatePath;

  Completer<void>? _gate;
  void armGate() => _gate = Completer<void>();
  void releaseGate() => _gate?.complete();

  @override
  String get cwd => delegate.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      delegate.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      delegate.joinPath(parts);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      delegate.readTextFile(path);

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      delegate.readBinaryFile(path);

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => delegate.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => delegate.writeBinaryFile(path, content);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      delegate.writeFile(path, content);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      delegate.appendFile(path, content);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      delegate.fileInfo(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      delegate.listDir(path);

  @override
  Future<Result<bool, FileError>> exists(String path) => delegate.exists(path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => delegate.createDir(path, recursive: recursive);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => delegate.remove(path, recursive: recursive, force: force);

  @override
  Future<Result<Uint8List, FileError>> readRange(
    String path,
    int start,
    int end,
  ) async {
    final gate = _gate;
    if (gate != null && path.contains(gatePath)) {
      // Park with the field still set so releaseGate() reaches the
      // parked completer; consume it after the release.
      await gate.future;
      _gate = null;
    }
    if (delegate case final RangedReadFileSystem ranged) {
      return ranged.readRange(path, start, end);
    }
    return Err(
      FileError(FileErrorCode.notSupported, 'no ranged reads', path: path),
    );
  }
}

void main() {
  /// Builds a big session file in one write — thousands of awaited storage
  /// appends would dominate the test runtime.
  Future<void> seedRaw(String path, int count) async {
    const iso = '2026-01-01T00:00:00.000Z';
    final buffer = StringBuffer(
      '{"type":"session","version":3,"id":"big","timestamp":"$iso",'
      '"cwd":"/work"}\n',
    );
    for (var i = 0; i < count; i++) {
      buffer.write(
        '{"type":"message","id":"e$i","parentId":'
        '${i == 0 ? 'null' : '"e${i - 1}"'},"timestamp":"$iso",'
        '"message":{"role":"user","content":[{"type":"text","text":'
        '"message $i with a bit of body to be realistic"}]}}\n',
      );
    }
    await io.File(path).writeAsString(buffer.toString());
  }

  Future<(AgentService, CountingFileSystem)> loadedService(
    int count, {
    CountingFileSystem? countingFs,
    Agent Function()? agentBuilder,
  }) async {
    final tmp = await io.Directory.systemTemp.createTemp('fa_windowed');
    addTearDown(() => tmp.delete(recursive: true));
    await seedRaw('${tmp.path}/big.jsonl', count);
    final counting =
        countingFs ?? CountingFileSystem(LocalFileSystem(cwd: tmp.path));
    final service = AgentService(
      agent: agentBuilder?.call() ?? _createAgent(),
      env: LocalExecutionEnv(cwd: tmp.path),
      sessionsRoot: tmp.path,
      repo: JsonlSessionRepo(fs: counting, sessionsRoot: tmp.path),
      watchExternalSessions: false,
      // Hermetic: the host's shared macOS session roots (App Group,
      // ~/.fah/sessions) must not leak extra sessions into listSessions.
      includeSharedSessionRoots: false,
    );
    await service.initialize();
    final stored = (await service.listSessions()).single;
    // Count only the OPEN path: list bookkeeping may bulk-read headers.
    counting
      ..bulkBytes = 0
      ..rangedBytes = 0;
    await service.loadSession(stored);
    return (service, counting);
  }

  /// The history count lands via an unawaited background refresh.
  Future<void> waitForCount(AgentService service, int expected) async {
    for (var i = 0; i < 300; i++) {
      if (service.historyAboveCount == expected) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail(
      'historyAboveCount never reached $expected '
      '(got ${service.historyAboveCount})',
    );
  }

  test('loadSession opens windowed: tail chunk only, count lands', () async {
    final (service, counting) = await loadedService(20000);
    addTearDown(service.dispose);

    // The window is the newest chunk (200 records) — not the 20000-record
    // file.
    expect(service.messages, hasLength(200));
    // Ranged reads moved the window; no whole-file read ever happened.
    expect(counting.rangedBytes, greaterThan(0));
    expect(counting.bulkBytes, 0);
    // The background count fills in the records above the window.
    await waitForCount(service, 19800);
  });

  test('loadOlderHistory pages the next chunk into the transcript', () async {
    // 5000 records: big enough to force many pages, small enough that
    // paging to the top stays comfortably inside the test timeout.
    final (service, _) = await loadedService(5000);
    addTearDown(service.dispose);
    await waitForCount(service, 4800);

    await service.loadOlderHistory();

    expect(service.messages, hasLength(400));
    expect(
      service.messages.first.content,
      'message 4600 with a bit of body to be realistic',
    );
    expect(service.historyAboveCount, 4600);

    // Paging to the file top: the VIEW stays bounded by the residency
    // cap (round-4 end-to-end memory bound — the transcript never
    // re-accumulates what the storage evicted); the newest side that
    // slid out is reported BELOW and pages back in.
    while (service.historyAboveCount! > 0) {
      await service.loadOlderHistory();
    }
    expect(service.historyAboveCount, 0);
    expect(service.messages, hasLength(600));
    // Deep paging at the file top: the window holds the OLDEST side;
    // the newest slid out and is reported below (the page-down path).
    expect(
      service.messages.first.content,
      'message 0 with a bit of body to be realistic',
    );
    expect(service.historyHasNewer, isTrue);
    expect(service.historyBelowCount, 4400);

    // The page-down path: residency slides back to the tail chunk by
    // chunk; the view follows the window exactly — contiguous, in
    // order, never a duplicate or a gap.
    while (service.historyHasNewer) {
      await service.loadNewerHistory();
    }
    expect(service.historyBelowCount, 0);
    expect(service.messages, hasLength(600));
    expect(
      service.messages.first.content,
      'message 4400 with a bit of body to be realistic',
    );
    expect(
      service.messages.last.content,
      'message 4999 with a bit of body to be realistic',
    );
    // And a further tap pages up one chunk — the window slides, the
    // view stays capped and contiguous.
    await service.loadOlderHistory();
    expect(service.messages, hasLength(600));
    expect(
      service.messages.first.content,
      'message 4200 with a bit of body to be realistic',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'loadNewerHistory reaches the tail in one call mid-run (#1159 AC1/E2)',
    () async {
      final (service, _) = await loadedService(1000);
      addTearDown(service.dispose);
      await waitForCount(service, 800);
      while (service.historyAboveCount! > 0) {
        await service.loadOlderHistory();
      }
      // Deep-paged: the newest side slid out below.
      expect(service.historyHasNewer, isTrue);
      expect(service.historyBelowCount, 400);

      // Exactly the incident state: an active run with a stuck
      // "Load newer" plate. The tap must work mid-run.
      service.isStreaming = true;
      await service.loadNewerHistory();

      // One bounded call lands at the live tail — no chunk-by-chunk crawl.
      expect(service.historyHasNewer, isFalse);
      expect(service.historyBelowCount, 0);
      // One tap = one jump: the window re-centers on the tail and fills
      // back up to the resident cap — never a chunk-by-chunk crawl.
      expect(service.messages, hasLength(600));
      expect(
        service.messages.first.content,
        'message 400 with a bit of body to be realistic',
      );
      expect(
        service.messages.last.content,
        'message 999 with a bit of body to be realistic',
      );
    },
  );

  test('mid-run jump keeps the streaming bubble live (#1159 AC1)', () async {
    AssistantMessageEventStream? live;
    AssistantMessage? partial;
    final (service, _) = await loadedService(
      1000,
      agentBuilder: () => _streamAgent((model, context, {cancelToken}) {
        final stream = AssistantMessageEventStream();
        live = stream;
        partial = AssistantMessage(
          content: [const TextContent(text: '')],
          api: model.api,
          provider: model.provider,
          model: model.id,
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.now(),
        );
        stream.push(StartEvent(partial: partial!));
        stream.push(
          TextDeltaEvent(
            contentIndex: 0,
            delta: 'tail-jump',
            partial: partial!,
          ),
        );
        // No DoneEvent: the run hangs mid-bubble, exactly the incident's
        // "Thinking… · 29s" state.
        return stream;
      }),
    );
    addTearDown(service.dispose);
    await waitForCount(service, 800);
    while (service.historyAboveCount! > 0) {
      await service.loadOlderHistory();
    }

    final run = service.sendText('hi');
    for (
      var i = 0;
      i < 300 &&
          !(service.isStreaming &&
              service.messages.last.content.contains('tail-jump'));
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(service.isStreaming, isTrue);
    expect(service.messages.last.content, 'tail-jump');

    // Mid-run jump to the tail: the tail region lands — and the live
    // bubble must survive the projection rebuild. The recorder keeps
    // appending below mid-run (the pinned-to-bottom UI follows on its
    // own — AC2 — so the banner state is not asserted mid-run here).
    await service.loadNewerHistory();
    expect(
      service.messages.map((m) => m.content),
      contains('message 999 with a bit of body to be realistic'),
    );
    expect(service.messages.last.content, 'tail-jump');

    // Streaming continues into the SAME row: deltas mutate the re-appended
    // bubble, not an orphaned object.
    live?.push(TextDeltaEvent(contentIndex: 0, delta: '!!', partial: partial!));
    for (
      var i = 0;
      i < 300 && service.messages.last.content != 'tail-jump!!';
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(service.messages.last.content, 'tail-jump!!');

    // Settle the run: the final record appends at the (now tail-anchored)
    // window and the transcript stays contiguous.
    live?.push(
      DoneEvent(
        reason: StopReason.stop,
        message: AssistantMessage(
          content: [const TextContent(text: 'full assistant message')],
          api: partial!.api,
          provider: partial!.provider,
          model: partial!.model,
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.now(),
        ),
      ),
    );
    live?.end();
    await run;
    // The AgentEnd handler is async (persist, then the flag flip) — the
    // run future can resolve a beat earlier; give the end boundary a
    // bounded beat.
    for (var i = 0; i < 300 && service.isStreaming; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(service.isStreaming, isFalse);
    expect(service.messages.last.content, 'full assistant message');
    // The mid-jump turn boundary must not duplicate: the run finalized
    // while the jump was rebuilding, and the re-appended live rows were
    // captured AFTER the rebuild - the finalized bubble lands exactly
    // once, and no stale pre-finalize bubble lingers (issue #1159
    // review).
    expect(
      service.messages.where((m) => m.content == 'full assistant message'),
      hasLength(1),
    );
    expect(service.messages.where((m) => m.content == 'tail-jump!!'), isEmpty);
    // A follow-up page-down — the UI's at-bottom follow does this on its
    // own — drains what the recorder parked below mid-run.
    await service.loadNewerHistory();
    expect(service.historyHasNewer, isFalse);
    expect(service.historyBelowCount, 0);
  });

  test('generation race: a reset mid-jump drops the stale page (E1)', () async {
    final gated = GatedFileSystem(
      LocalFileSystem(cwd: io.Directory.systemTemp.path),
      gatePath: 'big.jsonl',
    );
    final (service, _) = await loadedService(
      1000,
      countingFs: CountingFileSystem(gated),
    );
    addTearDown(service.dispose);
    await waitForCount(service, 800);
    while (service.historyAboveCount! > 0) {
      await service.loadOlderHistory();
    }
    expect(service.historyHasNewer, isTrue);
    expect(service.historyBelowCount, 400);

    // Park the jump's tail read mid-flight, reset underneath it: the
    // generation bump must make the stale page vanish on resume.
    gated.armGate();
    final jump = service.loadNewerHistory();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await service.reset();
    expect(service.messages, isEmpty);
    gated.releaseGate();
    await jump;

    // The stale page must not land in the new session's state.
    expect(service.messages, isEmpty);
    expect(service.historyHasNewer, isFalse);
  });

  test(
    'jumpToMessage: positional rows page in; record ids seek (AC6)',
    () async {
      final (service, _) = await loadedService(3000);
      addTearDown(service.dispose);
      await waitForCount(service, 2800);

      expect(service.messages, hasLength(200));
      // A positional target inside the reachable window pages in and
      // lands (the bounded view can hold the residency cap, not more).
      final jumped = await service.jumpToMessage('msg-350');
      expect(jumped, isTrue);
      expect(service.messages, hasLength(greaterThan(350)));
      // AC6 mechanism: a RECORD id (search / ✦ / trajectory-link hit)
      // seeks by byte offset and re-centers the window on the target.
      final sought = await service.jumpToMessage('e600');
      expect(sought, isTrue);
      expect(
        service.messages.map((m) => m.content),
        contains('message 600 with a bit of body to be realistic'),
      );
      // Out-of-range positional targets resolve as a miss without paging
      // the whole file (bounded by the residency cap, not a full read).
      expect(await service.jumpToMessage('msg-99999'), isFalse);
      // Unknown record ids are a plain miss.
      expect(await service.jumpToMessage('e-nope'), isFalse);
      // Garbage ids are a plain miss.
      expect(await service.jumpToMessage('garbage'), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('small sessions load whole: history count reports 0', () async {
    final (service, _) = await loadedService(5);
    addTearDown(service.dispose);

    expect(service.messages, hasLength(5));
    await waitForCount(service, 0);
    // Tapping with everything loaded is a no-op.
    await service.loadOlderHistory();
    expect(service.messages, hasLength(5));
  });

  test('a windowed-open failure falls back to the full open', () async {
    // The ranged-read path dies on the very first read (an IO hiccup
    // where the windowed storage opens): the session still loads —
    // through the classic full open (round-4 review, F5b).
    final tmp = await io.Directory.systemTemp.createTemp('fa_fallback');
    addTearDown(() => tmp.delete(recursive: true));
    await seedRaw('${tmp.path}/big.jsonl', 500);
    final flaky = FlakyFileSystem(LocalFileSystem(cwd: tmp.path));
    flaky.failNextReadRange = true;
    final service = AgentService(
      agent: _createAgent(),
      env: LocalExecutionEnv(cwd: tmp.path),
      sessionsRoot: tmp.path,
      repo: JsonlSessionRepo(fs: flaky, sessionsRoot: tmp.path),
      watchExternalSessions: false,
      includeSharedSessionRoots: false,
    );
    addTearDown(service.dispose);
    await service.initialize();
    final stored = (await service.listSessions()).single;
    await service.loadSession(stored);

    // The FULL open read the whole file (bulk), everything is loaded,
    // and the paging surfaces behave as a complete session: nothing
    // above the window (issue #974 — `0`, not `null`, so the chat
    // banner never renders on a full-open session).
    expect(flaky.bulkBytes, greaterThan(0));
    expect(service.messages, hasLength(500));
    expect(service.historyAboveCount, 0);
    await service.loadOlderHistory();
    expect(service.messages, hasLength(500));
  });
  test('jumpToMessage resolves record ids on fallback-open sessions', () async {
    // The windowed open dies on the first ranged read: the session
    // loads through the FULL open — where a record-id jump must still
    // land (issue #197 defect 4), not silently no-op.
    final tmp = await io.Directory.systemTemp.createTemp('fa_fallback_jump');
    addTearDown(() => tmp.delete(recursive: true));
    await seedRaw('${tmp.path}/big.jsonl', 500);
    final flaky = FlakyFileSystem(LocalFileSystem(cwd: tmp.path));
    flaky.failNextReadRange = true;
    final service = AgentService(
      agent: _createAgent(),
      env: LocalExecutionEnv(cwd: tmp.path),
      sessionsRoot: tmp.path,
      repo: JsonlSessionRepo(fs: flaky, sessionsRoot: tmp.path),
      watchExternalSessions: false,
      includeSharedSessionRoots: false,
    );
    addTearDown(service.dispose);
    await service.initialize();
    final stored = (await service.listSessions()).single;
    await service.loadSession(stored);
    expect(service.messages, hasLength(500));

    String? scrolled;
    service.scrollToMessageHandler = (messageId) => scrolled = messageId;
    // A record id resolves to its transcript row and hands it to the
    // scroll surface.
    expect(await service.jumpToMessage('e250'), isTrue);
    expect(scrolled, 'msg-250');
    // Unknown record ids stay a plain miss.
    expect(await service.jumpToMessage('e-nope'), isFalse);
    expect(scrolled, 'msg-250');
  });

  test('a failed page load surfaces historyLoadError until a retry', () async {
    final flaky = FlakyFileSystem(
      LocalFileSystem(cwd: io.Directory.systemTemp.path),
    );
    final (service, _) = await loadedService(1000, countingFs: flaky);
    addTearDown(service.dispose);
    await waitForCount(service, 800);

    // The next ranged read dies mid-page (a torn read).
    flaky.failNextReadRange = true;
    await service.loadOlderHistory();

    expect(service.historyLoadError, 'torn read');
    expect(service.messages, hasLength(200));

    // A retry (no fault) succeeds and clears the error.
    await service.loadOlderHistory();
    expect(service.historyLoadError, isNull);
    expect(service.messages, hasLength(400));
  });
}

/// A [CountingFileSystem] whose ranged reads can be armed to fail once -
/// the historyLoadError surface test's torn-read fault.
final class FlakyFileSystem extends CountingFileSystem {
  FlakyFileSystem(super.delegate);

  bool failNextReadRange = false;

  @override
  Future<Result<Uint8List, FileError>> readRange(
    String path,
    int start,
    int end,
  ) async {
    if (failNextReadRange) {
      failNextReadRange = false;
      throw StateError('torn read');
    }
    return super.readRange(path, start, end);
  }
}
