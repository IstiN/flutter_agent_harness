import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Polls the live-session presence store shared with the `fa` CLI: the
/// sessions currently owned by a running CLI process (green-dot in the
/// session lists, attachable). The CLI heartbeats into the store every
/// ~4s; staleness (15s) covers crashed processes.
class CliSessionPresence extends ChangeNotifier {
  CliSessionPresence._(this._store);

  /// Starts the service over the app's sessions root. The [env] must be
  /// the same [ExecutionEnv] the session repo uses (the macOS project
  /// mount / sandbox env sharing the App Group container).
  static CliSessionPresence start(
    ExecutionEnv env,
    String sessionsRoot, {
    Duration pollInterval = const Duration(seconds: 3),
  }) {
    final store = FileSessionPresenceStore(env: env, root: sessionsRoot);
    final service = CliSessionPresence._(store);
    service._timer = Timer.periodic(pollInterval, (_) => service._refresh());
    unawaited(service._refresh());
    return service;
  }

  /// A test-friendly instance over an injected store: polls with
  /// [interval] when given, otherwise only on demand.
  CliSessionPresence.forTest(SessionPresenceStore store, {Duration? interval})
    : _store = store {
    if (interval != null) {
      _timer = Timer.periodic(interval, (_) => _refresh());
    }
    unawaited(_refresh());
  }

  final SessionPresenceStore _store;
  Timer? _timer;
  Map<String, SessionPresence> _live = const {};

  /// The live sessions, keyed by session id.
  Map<String, SessionPresence> get live => _live;

  /// Whether [sessionId] has a running CLI process attached to it.
  bool isLive(String sessionId) => _live.containsKey(sessionId);

  /// Test seam: forces a presence re-read now (the timer does this
  /// periodically in production).
  @visibleForTesting
  Future<void> refreshForTest() => _refresh();

  Future<void> _refresh() async {
    try {
      final next = await _store.list();
      if (next.keys.length == _live.keys.length &&
          next.keys.every(_live.containsKey)) {
        return; // no change
      }
      _live = next;
      notifyListeners();
    } on Object {
      // A failing store must never kill the app: keep the last snapshot.
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// The app-side attach transport bundle: the event source (transcript
/// tail) and the input channel (user input to the owning CLI). Built over
/// the same env/root as the session repo; interfaces all the way so a
/// network impl drops in later.
class SessionAttachTransport {
  SessionAttachTransport({required this.events, required this.input});

  final SessionEventSource events;
  final SessionInputChannel input;
}

/// Builds the file-backed attach transport: tails the session JSONL
/// read-only and sends user input through the messaging fabric colocated
/// with the sessions ([cwdSlug] is the encoded cwd both the CLI and the
/// app derive from the session's cwd).
SessionAttachTransport fileAttachTransport({
  required ExecutionEnv env,
  required String sessionsRoot,
  required String cwdSlug,
  required Future<String?> Function(String sessionId) resolvePath,
}) {
  return SessionAttachTransport(
    events: FileSessionEventSource(env: env, resolvePath: resolvePath),
    input: FileSessionInputChannel(
      repository: FileMessagingRepository(
        env: env,
        root: '$sessionsRoot/$cwdSlug/messages',
      ),
    ),
  );
}

/// The sessions root and cwd slug a session's fabric mailboxes live under,
/// derived from the session JSONL path: `<root>/<slug>/<file>.jsonl`.
///
/// Deriving from the path (instead of trusting the manager's default root
/// plus an encoded cwd) makes attach immune to every split-brain storage
/// scenario — App Group vs `~/.fah/sessions` fallback, multi-root listing,
/// a session from another workspace. The running CLI colocates its inbox at
/// exactly `<thisRoot>/<thisSlug>/messages/<sessionId>_main/inbox`, so the
/// app must write there and nowhere else.
(String, String) sessionRootAndSlugForPath({
  required String defaultRoot,
  required String? sessionPath,
  required String fallbackCwd,
}) {
  final path = sessionPath;
  if (path == null || path.isEmpty) {
    return (defaultRoot, encodeSessionCwd(fallbackCwd));
  }
  final fileNameSlash = path.lastIndexOf('/');
  final slugSlash = fileNameSlash > 0
      ? path.lastIndexOf('/', fileNameSlash - 1)
      : -1;
  if (fileNameSlash <= 0 || slugSlash <= 0) {
    return (defaultRoot, encodeSessionCwd(fallbackCwd));
  }
  return (
    path.substring(0, slugSlash),
    path.substring(slugSlash + 1, fileNameSlash),
  );
}
