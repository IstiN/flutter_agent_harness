// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

part of 'agent_service.dart';

/// Background-execution + Live Activity helpers of [AgentService]
/// (the iOS Dynamic Island / lock-screen run status): the
/// [isStreaming] setter that drives them is an `@override` and stays
/// on the class; these helpers share its private state (same
/// library).
extension AgentServiceBackground on AgentService {
  Future<void> _beginBackgroundTask() async {
    _backgroundTaskId = await BackgroundExecution.begin('agent-run');
  }

  /// Shows the final run state on the Live Activity briefly, then ends it.
  /// The microtask hop (NOT a zero-delay timer — it would linger as a
  /// pending FakeTimer in tests) lets the error paths assign [error]
  /// first — they flip [isStreaming] and set the message right after,
  /// synchronously. The end timer is tracked so [dispose] can cancel it
  /// (and skipped entirely under widget tests, where a pending 4 s timer
  /// fails the binding).
  Future<void> _finishLiveActivity() async {
    await Future<void>.microtask(() {});
    final failed = error != null;
    await LiveActivity.update(
      statusText: failed ? 'run failed' : 'done',
      isError: failed,
      isDone: true,
    );
    if (AgentService._inWidgetTest) {
      await LiveActivity.end();
      return;
    }
    _liveActivityEndTimer?.cancel();
    _liveActivityEndTimer = Timer(const Duration(seconds: 4), () {
      unawaited(LiveActivity.end());
    });
  }

  /// The Live Activity status line — mirrors the FaWorkBar derivation
  /// (current tool call, thinking, writing) so both surfaces agree.
  String _liveActivityStatusText() {
    for (final message in messages.reversed) {
      switch (message.role) {
        case 'system':
          return message.content.split('\n').first;
        case 'tool':
          return '[${message.toolName}] ✓';
        case 'thinking':
          return 'thinking…';
        case 'assistant':
          return 'writing…';
      }
    }
    return 'working…';
  }

  /// Pushes the current status line to the Live Activity; cheap no-op when
  /// no activity is live (and always off iOS).
  void _pushLiveActivityStatus() {
    if (!_isStreaming) return;
    unawaited(LiveActivity.update(statusText: _liveActivityStatusText()));
  }
}
