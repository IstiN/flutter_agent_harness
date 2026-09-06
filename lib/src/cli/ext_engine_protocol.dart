/// Pure protocol layer for the `qjs` stdio transport: line decoding and
/// dispatch, pending-invoke bookkeeping, bridge reply shaping, probe result
/// validation, and script composition.
///
/// **No `dart:io`** — everything here is unit-testable without an engine
/// process; `ext_engine_process.dart` is the thin io shell on top.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import '../js_ext/ext_protocol.dart';

/// The exact extension script handed to `qjs`: fatal reporter, engine
/// bootstrap (transport + core), then the extension source guarded so an
/// evaluation error reaches the host as `{fatal}` instead of dying silently.
String composeExtScript(String bootstrapJs, String mainJs) =>
    'globalThis.__extFatal=function(m){ '
    'print(JSON.stringify({fatal:m})); };\n'
    '$bootstrapJs\n;try{\n$mainJs\n'
    '}catch(e){ __extFatal(String(e && e.message || e)); }\n';

/// Unwraps an invoke reply: the `value` on success, a thrown
/// [ExtProtocolException] carrying `error` otherwise.
Object? extReplyValue(Map<String, dynamic> reply) => reply['ok'] == true
    ? reply['value']
    : throw ExtProtocolException('${reply['error'] ?? 'engine error'}');

/// Bridge argument coercion: objects pass through as string-keyed maps,
/// anything else becomes an empty map.
Map<String, dynamic> extBridgeArgs(Object? rawArgs) =>
    rawArgs is Map ? Map<String, dynamic>.from(rawArgs) : const {};

/// Successful JS→host bridge reply.
Map<String, Object?> extBridgeOk(int seq, Object? value) => {
  'seq': seq,
  'ok': true,
  'value': value,
};

/// Failed JS→host bridge reply.
Map<String, Object?> extBridgeError(int seq, String error) => {
  'seq': seq,
  'ok': false,
  'error': error,
};

/// Probe verdict for `<bin> -e 'print(1)'`: null when the binary works,
/// the diagnostics message otherwise.
String? extProbeProblem(
  String bin,
  int exitCode,
  String stdout,
  String stderr,
) => exitCode == 0 && stdout.trim() == '1'
    ? null
    : '`$bin -e "print(1)"` failed (exit $exitCode): ${stderr.trim()}';

/// Version line from `<bin> -v`, or null when unusable (the caller falls
/// back to the binary path).
String? extProbeVersion(int exitCode, String stdout) {
  final text = stdout.trim();
  return exitCode == 0 && text.isNotEmpty ? text : null;
}

/// The io side of the wire protocol: where stderr notes land and how a
/// JS→host bridge request gets answered.
abstract interface class ExtLineSink {
  /// Records one diagnostic line in the engine stderr buffer.
  void note(String line);

  /// Answers a `{seq, method, args}` bridge request on stdin.
  void answerBridge(int seq, String method, Object? args);
}

/// The host action one engine stdout line demands.
sealed class ExtLineAction {
  const ExtLineAction();

  /// Executes the action against the io side. Invoke replies and fatal
  /// lines carry no io step (waiters are resolved/failed in the router).
  void runWith(ExtLineSink sink) {
    final action = this;
    if (action is ExtBridgeRequest) {
      sink.answerBridge(action.seq, action.method, action.args);
      return;
    }
    if (action is ExtLineNote) sink.note(action.note);
  }
}

/// Nothing further for the io shell to do (blank line, invoke reply,
/// fatal line — pending calls already failed, bridge request already
/// dispatched through [ExtLineSink]).
final class ExtHandled extends ExtLineAction {
  const ExtHandled();
}

/// An undecodable / non-object / unrecognized line, already worded for the
/// stderr buffer (without the `<stdout> ` source prefix).
final class ExtLineNote extends ExtLineAction {
  final String note;
  const ExtLineNote(this.note);
}

/// A JS→host bridge request the io shell must answer.
final class ExtBridgeRequest extends ExtLineAction {
  final int seq;
  final String method;
  final Object? args;
  const ExtBridgeRequest(this.seq, this.method, this.args);
}

/// Pending-invoke registry, stderr note buffer, and stdout line router —
/// the engine runtime's bookkeeping, free of `dart:io`.
final class ExtEngineRouter {
  final Map<int, Completer<Object?>> _waiters = {};
  final Queue<String> _notes = Queue();
  int _nextId = 1;

  /// Bound for the diagnostics note buffer.
  static const int _maxNotes = 200;

  /// Last [_maxNotes] engine diagnostics lines (stderr + stdout notes).
  String get lastNotes => _notes.join('\n');

  /// Records one diagnostics line, dropping the oldest past the bound.
  void note(String line) {
    _notes.addLast(line);
    while (_notes.length > _maxNotes) {
      _notes.removeFirst();
    }
  }

  /// Registers a pending invoke and returns its wire id.
  int beginInvoke(String fn, List<Object?> args) {
    _waiters[_nextId] = Completer<Object?>();
    return _nextId++;
  }

  /// The wire payload for a pending invoke.
  Map<String, Object?> invokePayload(int id, String fn, List<Object?> args) => {
    'invoke': id,
    'fn': fn,
    'args': args,
  };

  /// Resolves when the engine replies to invoke [id]. [timeout] first
  /// drops the waiter and runs [onTimeout] (the shell's kill switch),
  /// then throws [TimeoutException].
  Future<Object?> response(
    int id,
    String fn,
    Duration? timeout,
    Future<void> Function()? onTimeout,
  ) {
    var future = _waiters[id]!.future;
    if (timeout != null) {
      future = future.timeout(
        timeout,
        onTimeout: () async {
          // A stuck JS loop can never answer; the only recovery is a kill.
          _waiters.remove(id);
          await onTimeout?.call();
          throw TimeoutException(
            'engine invoke `$fn` timed out after '
            '${timeout.inMilliseconds}ms',
            timeout,
          );
        },
      );
    }
    return future;
  }

  /// Fails every pending invoke (engine exit or fatal line).
  void failAll(Object error) {
    final waiters = Map<int, Completer<Object?>>.from(_waiters);
    _waiters.clear();
    for (final completer in waiters.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }

  /// Decodes and classifies one engine stdout line.
  ExtLineAction onLine(String line) {
    if (line.trim().isEmpty) return const ExtHandled();
    final decoded = _tryDecode(line);
    if (decoded == null) return ExtLineNote('undecodable: $line');
    if (decoded is! Map<String, dynamic>) {
      return ExtLineNote('non-object: $line');
    }
    return _dispatch(decoded, line);
  }

  ExtLineAction _dispatch(Map<String, dynamic> msg, String line) {
    if (msg.containsKey('fatal')) {
      failAll(ExtProtocolException('engine fatal: ${msg['fatal']}'));
      return const ExtHandled();
    }
    final invokeId = msg['invoke'];
    if (invokeId is int) {
      final waiter = _waiters.remove(invokeId);
      if (waiter != null) {
        try {
          waiter.complete(extReplyValue(msg));
        } on Object catch (error) {
          waiter.completeError(error);
        }
      }
      return const ExtHandled();
    }
    final seq = msg['seq'];
    if (seq is int && msg.containsKey('method')) {
      final method = msg['method'];
      if (method is String) return ExtBridgeRequest(seq, method, msg['args']);
    }
    return ExtLineNote('unrecognized: $line');
  }

  Object? _tryDecode(String line) {
    try {
      return jsonDecode(line);
    } on FormatException {
      return null;
    }
  }
}
