import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'cli_session_presence.dart';

/// Drives the attached-session view: follows the session transcript
/// through a [SessionEventSource] and hands composer input to the owning
/// CLI process through a [SessionInputChannel]. Pure state on top of the
/// attach interfaces — no Flutter dependencies beyond ChangeNotifier, so
/// tests drive it directly with fakes.
class AttachedSessionController extends ChangeNotifier {
  // ignore_for_file: prefer_initializing_formals

  AttachedSessionController({
    required this.sessionId,
    required this.title,
    required SessionAttachTransport transport,
  }) : _transport = transport {
    _sub = _transport.events.watch(sessionId).listen(_onEvent);
  }

  final String sessionId;
  final String title;
  final SessionAttachTransport _transport;
  StreamSubscription<AttachedSessionEvent>? _sub;

  final List<AttachedMessage> rows = [];
  var sending = false;

  void _onEvent(AttachedSessionEvent event) {
    rows.addAll(event.appended);
    notifyListeners();
  }

  /// Hands [text] to the owning CLI process as user input. The CLI's
  /// inbox watcher picks it up (~2s) and runs the turn; the transcript
  /// follows through the watch stream.
  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    sending = true;
    notifyListeners();
    try {
      await _transport.input.send(sessionId, trimmed);
    } finally {
      sending = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }
}
