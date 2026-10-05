/// gh-1164 Part B: the shared JS-app error record — the shape the JS
/// runtime reports and every host (flutter app, CLI, tests) relays.
///
/// One record per captured error: [kind] classifies the capture surface,
/// [message] is the JS `Error.message`, [stack] the raw `.stack` (already
/// truncated by the reporter in JS where a hard cap matters), and
/// [fingerprint] dedups bursts (per-frame animation errors collapse to the
/// first occurrence). Hosts attach app id, surface, and source revision
/// at the delivery boundary.
library;

/// Classification of one captured JS error.
enum JsAppErrorKind {
  /// `jsr.showError` — the runtime's own crash overlay (load-time throws
  /// from the eval wrapper reach the screen through it).
  showError,

  /// An exception in a timer/animation-frame callback (the bridge
  /// swallows these silently today — captured by the bootstrap wrapper).
  callback,

  /// `window.onerror` — uncaught exceptions anywhere else.
  onerror,

  /// `unhandledrejection` — a rejected promise with no handler.
  unhandledRejection,

  /// The host's render/build of the app's UI tree threw.
  render,

  /// The engine failed to start at all (bootstrap failure).
  bootstrap,
}

/// One captured JS error, reported toward the authoring agent.
class JsAppErrorEvent {
  const JsAppErrorEvent({
    required this.kind,
    required this.message,
    required this.stack,
    this.fingerprint = '',
  });

  /// Parses one structured `faAppError:` log record (JSON object) — the
  /// single wire format the bootstrap emits. Returns null for any other
  /// line, so a log tap can pass everything through it.
  static JsAppErrorEvent? fromLogJson(Map<String, dynamic> json) {
    final message = json['message'];
    if (message is! String || message.isEmpty) return null;
    final stack = json['stack'];
    final rawKind = json['kind'];
    final kind = switch (rawKind) {
      'showError' => JsAppErrorKind.showError,
      'callback' => JsAppErrorKind.callback,
      'onerror' => JsAppErrorKind.onerror,
      'unhandledrejection' => JsAppErrorKind.unhandledRejection,
      'render' => JsAppErrorKind.render,
      'bootstrap' => JsAppErrorKind.bootstrap,
      _ => JsAppErrorKind.onerror,
    };
    final fingerprint = json['fingerprint'];
    return JsAppErrorEvent(
      kind: kind,
      message: message,
      stack: stack is String ? stack : '',
      fingerprint: fingerprint is String ? fingerprint : '',
    );
  }

  final JsAppErrorKind kind;
  final String message;
  final String stack;
  final String fingerprint;

  /// Dedup key over the stable parts of the event (message + top stack
  /// frame). Two records with the same key are "the same error still
  /// happening" — reported once per app source revision.
  String get dedupKey => fingerprint.isNotEmpty
      ? fingerprint
      : '$message\n${stack.split('\n').firstOrNull ?? ''}';

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'message': message,
    'stack': stack,
    'fingerprint': fingerprint,
  };
}
