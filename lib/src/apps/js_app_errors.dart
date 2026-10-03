/// gh-1164 Part B: render/runtime JS app errors flow back to the authoring
/// agent as failures instead of dying on screen.
///
/// The JS runtime's crash surfaces (`jsr.showError`, wrapped timer/RAF
/// callbacks, bootstrap failures) emit one structured log line; the host
/// engine parses it ([parseJsAppErrorLogLine]) and forwards the event to a
/// session-level gate ([JsAppErrorFeedback]) which decides delivery:
///
/// - **No fake success** is the caller's contract — a create/update/render
///   tool call must fail when the runtime reports an error (the gate is the
///   shared dedup layer for the async deliveries after a call returned).
/// - **Anti-spam by construction**: one report per (app, error fingerprint)
///   until the app source revision changes; a per-app circuit breaker stops
///   the loop after N consecutive revisions reporting the SAME error
///   (the agent edited and the bug persists — repeating it helps nobody).
/// - **Bounded payloads** (E2): the stack keeps its head frames, oversized
///   messages cap with an explicit truncation marker — never a silent cut.
///
/// Pure Dart: hosts without the JS runtime (pure CLI) simply never produce
/// events and the gate stays inert.
library;

import 'dart:convert';

/// The console marker the host bootstrap prefixes to a JSON-encoded error
/// record (rides the `__jsr_log` channel, already error-classified by the
/// `[E] ` console prefix).
const String jsAppErrorLogMarker = 'faAppError:';

/// The `__jsr_log` console prefix the runtime bootstrap puts on
/// `console.error` output.
const String _consoleErrorPrefix = '[E] ';

/// One error event as reported by the JS side (pre-dedup).
final class JsAppErrorEvent {
  const JsAppErrorEvent({
    required this.kind,
    required this.message,
    required this.stack,
  });

  /// Which crash surface fired: `showError` (runtime/app-invoked error
  /// overlay), `callback` (a timer/RAF/event callback threw), `bootstrap`
  /// (the widget failed to load/compile).
  final String kind;

  /// Error message text.
  final String message;

  /// Raw stack string, may be empty (not every surface has one).
  final String stack;

  /// Parses the bootstrap's JSON payload; null for a non-object payload.
  static JsAppErrorEvent? fromJsonPayload(Object? decoded) {
    if (decoded is! Map) return null;
    final kind = decoded['kind'];
    final message = decoded['message'];
    if (kind is! String || message is! String) return null;
    final stack = decoded['stack'];
    return JsAppErrorEvent(
      kind: kind,
      message: message,
      stack: stack is String ? stack : '',
    );
  }
}

/// Parses one `__jsr_log` line into a [JsAppErrorEvent], or null when the
/// line is not an error record (plain console output passes through).
JsAppErrorEvent? parseJsAppErrorLogLine(String line) {
  if (!line.startsWith(_consoleErrorPrefix)) return null;
  final rest = line.substring(_consoleErrorPrefix.length);
  if (!rest.startsWith(jsAppErrorLogMarker)) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(rest.substring(jsAppErrorLogMarker.length));
  } on FormatException {
    return null;
  }
  return JsAppErrorEvent.fromJsonPayload(decoded);
}

/// One delivered app error — the failed-tool-result-shaped record the
/// session receives (app id, stack head, source revision, timestamp).
final class JsAppErrorReport {
  JsAppErrorReport({
    required this.appId,
    required this.surface,
    required this.kind,
    required this.message,
    required this.stackHead,
    required this.stackTruncated,
    required this.sourceRevision,
    required this.timestamp,
  });

  factory JsAppErrorReport.fromJson(Map<String, dynamic> json) {
    return JsAppErrorReport(
      appId: json['appId'] as String? ?? '',
      surface: json['surface'] as String? ?? 'app',
      kind: json['kind'] as String? ?? 'error',
      message: json['message'] as String? ?? '',
      stackHead: [
        for (final frame in (json['stackHead'] as List?) ?? const [])
          frame.toString(),
      ],
      stackTruncated: json['stackTruncated'] == true,
      sourceRevision: json['sourceRevision'] as String? ?? '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (json['timestampMs'] as num?)?.toInt() ?? 0,
      ),
    );
  }

  /// The `apps/<id>` folder name the error came from.
  final String appId;

  /// Which live surface fired: `app` (fullscreen view), `tile` (launcher
  /// tile engine), `widget` (dynamic-message widget).
  final String surface;

  /// Crash surface (see [JsAppErrorEvent.kind]) plus the host-side `render`
  /// kind for Flutter-side render-host exceptions.
  final String kind;

  /// The (possibly capped) error message.
  final String message;

  /// First stack frames (bounded).
  final List<String> stackHead;

  /// Whether the stack had more frames than the head kept.
  final bool stackTruncated;

  /// Content revision of the app source the error fired against — the
  /// dedup key boundary (an edit re-arms reporting).
  final String sourceRevision;

  /// When the host observed the error.
  final DateTime timestamp;

  /// Stable identity of the error: kind + whitespace-normalized message.
  /// Formatting-only differences (line wraps inside one message) collapse;
  /// different failures never share a fingerprint.
  String get fingerprint =>
      '$kind\u0000${_normalizeMessage(message, _fingerprintChars)}';

  Map<String, Object?> toJson() => {
    'appId': appId,
    'surface': surface,
    'kind': kind,
    'message': message,
    'stackHead': stackHead,
    'stackTruncated': stackTruncated,
    'sourceRevision': sourceRevision,
    'timestampMs': timestamp.millisecondsSinceEpoch,
  };

  @override
  String toString() => 'JsAppErrorReport($appId/$surface $kind: $message)';
}

const int _fingerprintChars = 256;

String _normalizeMessage(String message, int cap) {
  final flat = message.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= cap ? flat : flat.substring(0, cap);
}

/// The delivery gate between raw engine error events and the agent's
/// session. One instance per authoring session: every live engine surface
/// of an app forwards into it, so cross-surface duplicates collapse.
class JsAppErrorFeedback {
  JsAppErrorFeedback({
    this.maxStackFrames = 8,
    this.maxMessageChars = 2000,
    this.maxUnactedRevisions = 3,
  });

  /// Stack frames kept per report.
  final int maxStackFrames;

  /// Message character cap (an explicit `…` marker replaces the tail).
  final int maxMessageChars;

  /// How many consecutive DISTINCT revisions may report the SAME error
  /// before the app's circuit breaker stops the loop.
  final int maxUnactedRevisions;

  /// (appId, fingerprint) → source revision already reported.
  final Map<String, String> _reportedRevision = {};

  /// appId → the last fingerprint reported on consecutive revisions and
  /// how many distinct revisions in a row it reported (the breaker).
  final Map<String, ({String fingerprint, int revisions})> _breaker = {};

  /// Folds one raw event into a [JsAppErrorReport] — or null when the gate
  /// suppresses it (already reported for this revision, or the app's
  /// circuit breaker tripped).
  JsAppErrorReport? observe({
    required String appId,
    String surface = 'app',
    required String kind,
    required String message,
    String stack = '',
    required String sourceRevision,
    DateTime? now,
  }) {
    final fp = '$kind\u0000${_normalizeMessage(message, _fingerprintChars)}';
    final key = '$appId\u0000$fp';
    final seenRevision = _reportedRevision[key];
    if (seenRevision == sourceRevision) return null;

    final breaker = _breaker[appId];
    if (breaker != null &&
        breaker.fingerprint == fp &&
        breaker.revisions >= maxUnactedRevisions) {
      // The same error survived N edits — stop the loop. A different
      // fingerprint re-arms (see below).
      return null;
    }
    if (breaker != null && breaker.fingerprint != fp) {
      _breaker.remove(appId);
    }

    _reportedRevision[key] = sourceRevision;
    final consecutive = (breaker?.fingerprint == fp)
        ? breaker!.revisions + 1
        : 1;
    _breaker[appId] = (fingerprint: fp, revisions: consecutive);

    final frames = stack.isEmpty
        ? const <String>[]
        : stack
              .split('\n')
              .map((frame) => frame.trim())
              .where((frame) => frame.isNotEmpty)
              .toList(growable: false);
    final head = frames.length > maxStackFrames
        ? frames.sublist(0, maxStackFrames)
        : frames;
    return JsAppErrorReport(
      appId: appId,
      surface: surface,
      kind: kind,
      message: _capMessage(message),
      stackHead: List<String>.unmodifiable(head),
      stackTruncated: frames.length > maxStackFrames,
      sourceRevision: sourceRevision,
      timestamp: now ?? DateTime.now(),
    );
  }

  /// Drops ALL gate state for [appId] — the app's source was reloaded from
  /// a known-good baseline (restore/reset flows) and its history must not
  /// suppress fresh reports.
  void resetApp(String appId) {
    _reportedRevision.removeWhere((key, _) => key.startsWith('$appId\u0000'));
    _breaker.remove(appId);
  }

  String _capMessage(String message) {
    final flat = _normalizeMessage(message, maxMessageChars);
    if (message.length <= maxMessageChars) return flat;
    return '$flat…';
  }
}
