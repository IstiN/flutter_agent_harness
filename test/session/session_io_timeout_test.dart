import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'flaky_session_fs.dart';

/// Issue #2248: session IO must fail FAST and VISIBLY.
///
/// - AC1: a wrapped OSError (EMFILE shape) rides the [FileError] message
///   into the [SessionException], and the surfaced failure joins the
///   per-session IO health the stall watchdog reads (AC5's input).
/// - AC2: a hung append fails named at the session-IO bound instead of
///   wedging the turn forever (the 21-minute yoclip hang).
/// - AC3: a serialized chain whose head hangs cannot block later appends
///   past the same bound — the queue advances or each entry fails
///   bounded.
/// - AC7 REG: the transient-ENOENT retry (#427) is untouched — a flaky
///   append still rides the capped backoff and lands.
void main() {
  const path = '/sessions/s.jsonl';

  // The raw OS reason the incident log could not surface: the engine's
  // generic "Cannot open file" plus the errno detail (AC1's shape).
  final emfileError = FileError(
    FileErrorCode.unknown,
    'Cannot open file (errno 24: Too many open files)',
    path: path,
  );

  Future<JsonlSessionStorage> createStorage(
    FileSystem fs, {
    SessionIoRetryConfig ioRetry = const SessionIoRetryConfig(
      ioTimeout: Duration(milliseconds: 200),
    ),
  }) {
    return JsonlSessionStorage.create(
      fs,
      path,
      cwd: '/work',
      sessionId: 's1',
      ioRetry: ioRetry,
    );
  }

  MessageRecord record(String id, {String text = 'hello'}) => MessageRecord(
    id: id,
    parentId: null,
    timestamp: DateTime.utc(2026),
    message: UserMessage.text(text),
  );

  setUp(SessionIoHealth.resetForTests);
  tearDown(SessionIoHealth.resetForTests);

  test('AC1: a wrapped EMFILE surfaces errno through the named '
      'SessionException and joins the per-session IO health', () async {
    final fs = _FailingAppendFs(MemoryFileSystem(), failure: emfileError);
    final storage = await createStorage(fs);
    await expectLater(
      storage.appendEntry(record('e1')),
      throwsA(
        isA<SessionException>()
            .having(
              (e) => e.message,
              'message',
              contains('Too many open files'),
            )
            .having((e) => e.message, 'message', contains('errno 24'))
            .having((e) => e.code, 'code', SessionErrorCode.storage),
      ),
    );
    // AC5's input: the watchdog can now name THIS session's failing IO.
    final last = SessionIoHealth.lastFailure('s1');
    expect(last, isNotNull);
    expect(last!.error, contains('Too many open files'));
  });

  test('AC2: a hung append fails named at the session-IO bound — '
      'never an unbounded await', () async {
    final fs = _HangingAppendFs(
      MemoryFileSystem(),
      failure: emfileError,
      hangAppends: true,
    );
    final storage = await createStorage(fs);
    final sw = Stopwatch()..start();
    await expectLater(
      storage.appendEntry(record('e1')),
      throwsA(
        isA<SessionException>().having(
          (e) => e.message,
          'message',
          contains('session IO timed out after 200ms'),
        ),
      ),
    );
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    expect(SessionIoHealth.lastFailure('s1'), isNotNull);
  });

  test(
    'AC2: the header create is bounded too — a hung create fails named',
    () async {
      final fs = _HangingAppendFs(
        MemoryFileSystem(),
        failure: emfileError,
        hangWrites: true,
      );
      await expectLater(
        JsonlSessionStorage.create(
          fs,
          path,
          cwd: '/work',
          sessionId: 's1',
          ioRetry: const SessionIoRetryConfig(
            ioTimeout: Duration(milliseconds: 200),
          ),
        ),
        throwsA(
          isA<SessionException>().having(
            (e) => e.message,
            'message',
            contains('session IO timed out'),
          ),
        ),
      );
    },
  );

  test('AC3: a stuck head cannot block later appends — the followup '
      'resolves bounded (lands, or fails with a named queue/IO timeout), '
      'never inheriting the head hang', () async {
    // ONLY the head's append hangs (its content names it); the followup
    // append would succeed if it ever got a turn.
    final fs = _HangingAppendFs(
      MemoryFileSystem(),
      failure: emfileError,
      hangMarker: 'hang-me',
    );
    final storage = await createStorage(fs);
    final sw = Stopwatch()..start();
    final stuck = storage.appendEntry(record('e1', text: 'hang-me'));
    await expectLater(stuck, throwsA(isA<SessionException>()));
    // The followup resolves past the head's bound — landed (the queue
    // advanced) or per-entry bounded failure — but never unbounded.
    final followup = await storage
        .appendEntry(record('e2'))
        .then(
          (_) => true,
          onError: (Object error) {
            // Bounded per-entry failure (queue/IO timeout or the
            // underlying fs error) — never an unbounded wait.
            expect(error, isA<SessionException>());
            return true;
          },
        );
    expect(followup, isTrue);
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('AC3: a wholesale-hang fs fails EVERY entry bounded — no entry waits '
      'unbounded behind the previous one', () async {
    final fs = _HangingAppendFs(
      MemoryFileSystem(),
      failure: emfileError,
      hangAppends: true,
    );
    final storage = await createStorage(fs);
    final sw = Stopwatch()..start();
    for (var i = 0; i < 3; i++) {
      await expectLater(
        storage.appendEntry(record('e$i')),
        throwsA(
          isA<SessionException>().having(
            (e) => e.message,
            'message',
            contains('timed out'),
          ),
        ),
      );
    }
    // Three entries × 200ms bound + slack — NOT 3 × forever.
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('AC7 REG: a transient-ENOENT append still rides the #427 capped '
      'retry and lands — semantics unchanged', () async {
    final fs = FlakySessionFs(MemoryFileSystem())..failNextAppends = 1;
    final storage = await createStorage(fs);
    await storage.appendEntry(record('e1'));
    expect(fs.appendCalls, greaterThanOrEqualTo(2), reason: 'one retry');
    final entries = await storage.getEntries();
    expect(entries.single.id, 'e1');
    expect(SessionIoHealth.lastFailure('s1'), isNull);
  });

  test('AC5 REG (RC round-1): a surfaced notFound is NOT a health signal — '
      'a genuinely missing path never arms the fs banner', () async {
    final fs = FlakySessionFs(MemoryFileSystem())
      ..failNextAppends = 99; // retries exhaust → the notFound surfaces.
    // The DEFAULT ioTimeout (30s) comfortably covers the #427 retry
    // window (~1.5s); a shrunken test bound would cut the retries off
    // before exhaustion and surface the timeout instead.
    final storage = await JsonlSessionStorage.create(
      fs,
      path,
      cwd: '/work',
      sessionId: 's1',
    );
    await expectLater(
      storage.appendEntry(record('e1')),
      throwsA(
        isA<SessionException>().having(
          (e) => e.code,
          'code',
          SessionErrorCode.notFound,
        ),
      ),
    );
    expect(
      SessionIoHealth.lastFailure('s1'),
      isNull,
      reason: 'file-missing is benign — no fs-failure verdict',
    );
  });

  test('AC5 classification: stallIsSessionIo windows the last failure — '
      'per-session isolation and old failures stay provider stalls', () async {
    final now = DateTime.now();
    expect(
      stallIsSessionIo(
        last: null,
        now: now,
        window: const Duration(minutes: 2),
      ),
      isFalse,
      reason: 'no failure — provider stall',
    );
    final fresh = (at: now.subtract(const Duration(seconds: 10)), error: 'e');
    expect(
      stallIsSessionIo(
        last: fresh,
        now: now,
        window: const Duration(minutes: 2),
      ),
      isTrue,
    );
    final stale = (at: now.subtract(const Duration(minutes: 5)), error: 'e');
    expect(
      stallIsSessionIo(
        last: stale,
        now: now,
        window: const Duration(minutes: 2),
      ),
      isFalse,
      reason: 'a failure older than the window must not relabel a stall',
    );
  });

  test('AC6 gauge: failuresInLastMinute counts the rolling window, '
      'per-session isolation holds', () async {
    SessionIoHealth.noteFailure('s1', 'boom');
    SessionIoHealth.noteFailure('s1', 'boom 2');
    SessionIoHealth.noteFailure('s2', 'other session');
    expect(SessionIoHealth.failuresInLastMinute(), 3);
    expect(SessionIoHealth.lastFailure('s1')!.error, 'boom 2');
    expect(SessionIoHealth.lastFailure('s2')!.error, 'other session');
    expect(SessionIoHealth.lastFailure('s3'), isNull);
    SessionIoHealth.resetForTests();
    expect(SessionIoHealth.failuresInLastMinute(), 0);
  });
}

/// Fake fs whose session-file appends fail with a fixed [FileError]
/// (the AC1 wrapped-OSError shape).
class _FailingAppendFs implements FileSystem {
  _FailingAppendFs(this._delegate, {required this.failure});

  final MemoryFileSystem _delegate;
  final FileError failure;

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      path.endsWith('.jsonl')
      ? Future.value(Err(failure))
      : _delegate.appendFile(path, content);

  @override
  String get cwd => _delegate.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _delegate.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _delegate.joinPath(parts);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _delegate.readTextFile(path);

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
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _delegate.writeFile(path, content);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _delegate.fileInfo(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _delegate.listDir(path);

  @override
  Future<Result<bool, FileError>> exists(String path) => _delegate.exists(path);

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
}

/// Fake fs whose jsonl ops hang (never complete) — the wedge shape.
/// [hangAppends] hangs every session append ([hangMarker] narrows it to
/// lines carrying the marker — the stuck head of the AC3 chain);
/// [hangWrites] hangs the header create (the writeFile shape).
final class _HangingAppendFs extends _FailingAppendFs {
  _HangingAppendFs(
    super.delegate, {
    required super.failure,
    this.hangAppends = false,
    this.hangWrites = false,
    this.hangMarker,
  });

  final bool hangAppends;
  final bool hangWrites;
  final String? hangMarker;

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) {
    final marker = hangMarker;
    final hangs = hangAppends || (marker != null && content.contains(marker));
    if (path.endsWith('.jsonl') && hangs) {
      return Completer<Result<void, FileError>>().future;
    }
    return super.appendFile(path, content);
  }

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) {
    if (path.endsWith('.jsonl') && hangWrites) {
      return Completer<Result<void, FileError>>().future;
    }
    return super.writeFile(path, content);
  }
}
