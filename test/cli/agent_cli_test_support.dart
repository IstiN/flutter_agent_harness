// Shared fakes and helpers for the agent_cli test suite.

// The scripted-stream half (test model, turn builders, fake stream) lives
// in the suite-neutral harness; re-exported so the suite's consumers keep
// this one import. The file's own remaining members (Abortable's abort
// turn) use it too.
export '../support/scripted_stream_harness.dart';
import '../support/scripted_stream_harness.dart';

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// A [StreamFunction] turn that hangs until cancelled, then reports aborted.
class AbortableStreamFunction {
  var started = false;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    started = true;
    final stream = AssistantMessageEventStream();
    stream.push(StartEvent(partial: testAssistant()));
    cancelToken?.onCancel.then((_) {
      stream.push(
        ErrorEvent(
          reason: StopReason.aborted,
          error: testAssistant(
            stopReason: StopReason.aborted,
            errorMessage: 'Operation aborted',
          ),
        ),
      );
      stream.end();
    });
    return stream;
  }
}

/// A [Shell] that blocks until [release] completes the gate.
class GatedShell implements Shell {
  final _gate = Completer<void>();

  void release() => _gate.complete();

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    await _gate.future;
    return const Ok(ShellExecResult(stdout: '', stderr: '', exitCode: 0));
  }
}

/// A [Shell] that echoes the command and returns canned output.
class FakeShell implements Shell {
  FakeShell({this.stdout = '', this.stderr = '', this.exitCode = 0});

  final String stdout;
  final String stderr;
  final int exitCode;
  final commands = <String>[];
  ShellExecOptions? lastOptions;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    commands.add(command);
    lastOptions = options;
    return Ok(
      ShellExecResult(stdout: stdout, stderr: stderr, exitCode: exitCode),
    );
  }
}

/// In-memory [CliIO]: scripted input lines, captured output.
class FakeCliIO implements CliIO {
  @override
  int columns = 80;

  @override
  int rows = 24;

  final _lines = StreamController<String>();
  final _interrupts = StreamController<void>.broadcast();
  final _keys = StreamController<KeyEvent>.broadcast();
  final out = StringBuffer();

  /// Tests flip this to exercise the non-interactive approval path.
  @override
  bool isInteractive = true;

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Stream<void> get interrupts => _interrupts.stream;

  @override
  Stream<KeyEvent> get keys => _keys.stream;

  @override
  bool get supportsRawMode => true;

  @override
  void write(String text) => out.write(text);

  @override
  void writeln(String text) => out.write('$text\n');

  void sendLine(String line) => _lines.add(line);

  void sendKey(KeyEvent key) => _keys.add(key);

  void interrupt() => _interrupts.add(null);

  Future<void> close() async {
    // The close future only completes once a listener received the done
    // event; tests that never ran the CLI have no listener, so don't await.
    unawaited(_lines.close());
    unawaited(_keys.close());
    await _interrupts.close();
  }
}

/// Split-channel headless IO — the canonical fixture for the headless
/// channel contract (gh-1292 review): [write] is the pipeable primary
/// stream (stdout — byte-identical assistant prose only, issue #774
/// AC3), [writeln] is the diagnostics channel (stderr on headless hosts,
/// per bin/fah_io.dart). Use it wherever a suite pins "this must reach
/// the captured run log but never pollute stdout" — sibling suites that
/// still hand-roll the shape (headless_cli, headless_hep,
/// markdown_surface, log_file_tee, ext_cli) adopt it incrementally.
class SplitChannelCliIO implements CliIO {
  final out = StringBuffer();
  final diag = StringBuffer();

  @override
  bool get isInteractive => false;

  @override
  int columns = 80;

  @override
  int rows = 24;

  @override
  Stream<String> get lines => const Stream<String>.empty();

  @override
  Stream<void> get interrupts => const Stream<void>.empty();

  @override
  Stream<KeyEvent> get keys => const Stream<KeyEvent>.empty();

  @override
  bool get supportsRawMode => false;

  @override
  void write(String text) => out.write(text);

  @override
  void writeln(String text) => diag.write('$text\n');
}

/// In-memory [SecureKeyStore] with a toggleable availability flag.
class FakeSecureKeyStore implements SecureKeyStore {
  FakeSecureKeyStore({this.available = true});

  bool available;
  bool failWrites = false;
  final map = <String, String>{};

  @override
  String get label => 'fake store';

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<String?> read(String name) async => map[name];

  @override
  Future<void> write(String name, String value) async {
    if (failWrites) throw StateError('keychain write failed (exit 45)');
    map[name] = value;
  }

  @override
  Future<void> delete(String name) async => map.remove(name);
}

/// The text carried by a transcript message or a fabric mail record —
/// the shared message-text extractor the routing/record-asserting suites
/// read contexts and mail entries with (hoisted from file-local copies,
/// gh-1947 review).
String messageText(Object message) {
  final content = switch (message) {
    UserMessage() => message.content,
    AssistantMessage() => message.content,
    ToolResultMessage() => message.content,
    AgentMessage() => message.text,
    _ => '',
  };
  return content is String
      ? content
      : content is List<ContentBlock>
      ? [
          for (final block in content)
            if (block is TextContent) block.text,
        ].join('\n')
      : '';
}

/// Polls [condition] until it holds or the [seconds] budget expires.
Future<void> waitForIt(
  FutureOr<bool> Function() condition, {
  String? reason,
  int seconds = 25,
}) async {
  // Generous budget: startup discovery + prompt composition must finish
  // within this window even on a LOADED machine (coverage instrumentation
  // roughly doubles run time; parallel builds/other projects' test runners
  // eat the rest). [seconds] of polling; the condition is checked every
  // 5ms so tests still finish as soon as the awaited state actually
  // appears. Async conditions are awaited (polling a Future beats a
  // silent fall-through on timeout — the failure must name the wait).
  for (var i = 0; i < seconds * 200; i++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: ${reason ?? 'condition'}');
}

/// An env whose `.owner.json` renames fail for a chosen call window
/// (0-based, counting only sidecar publishes): the #2138 refused-claim
/// rig. Boot/switch renames on other paths (waiting manifest, usage
/// ledger) pass through untouched, so the window pins exactly which
/// lease claim refuses.
final class RenameGateEnv implements ExecutionEnv, RenamableFileSystem {
  RenameGateEnv(this._delegate, {required this.failFrom, required this.failTo});

  final MemoryExecutionEnv _delegate;

  /// The 0-based window of `.owner.json` rename calls that fail.
  final int failFrom;
  final int failTo;
  int _ownerRenames = 0;

  @override
  Future<Result<void, FileError>> renamePath(String from, String to) async {
    if (to.endsWith('.owner.json')) {
      final index = _ownerRenames++;
      if (index >= failFrom && index <= failTo) {
        return Err(
          FileError(FileErrorCode.unknown, 'injected owner rename failure'),
        );
      }
    }
    return _delegate.renamePath(from, to);
  }

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _delegate.readTextFile(path);

  @override
  String get cwd => _delegate.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _delegate.absolutePath(path);

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
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _delegate.writeFile(path, content);

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

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _delegate.exec(command, options: options);
}
