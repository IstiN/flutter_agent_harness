part of 'agent_cli.dart';

// Session-persistence members of [AgentCli] — split out of `agent_cli.dart`
// to keep it under the repo's 2800-line size gate. Same library (a `part
// of`), so the extension sees the class's private fields (`_session`,
// `_persistedCount`) with no visibility change.

extension AgentCliPersist on AgentCli {
  /// Persists a single message as soon as the agent adds it to the transcript.
  /// Keeps [_persistedCount] aligned so [_afterRun] only writes anything the
  /// listener may have missed (e.g. a crash between the append and the await).
  Future<void> _persistIncremental(AgentEvent event) async {
    if (event is! MessageEndEvent) return;
    final message = event.message;
    // Aborted assistant streams are incomplete; TTSR's discard mode prunes
    // them from memory and they should not survive in the session either.
    // EXCEPT backend agent mode (issue #155): a graceful SIGTERM cancel
    // must leave a resumable partial transcript on disk.
    if (message is AssistantMessage &&
        message.stopReason == StopReason.aborted &&
        !config.persistAbortedPartials) {
      return;
    }
    final session = _session;
    if (session == null) return;
    final messages = _agent.state.messages;
    if (_persistedCount >= messages.length) return;
    await session.appendMessage(message);
    _persistedCount++;
  }

  /// Handles a CodeMie auth-session expiry if [message] matches one. Returns
  /// `true` when the expiry was handled and the turn is finished.

  Future<void> _persistMessages() async {
    final session = _session;
    if (session == null) return;
    final messages = _agent.state.messages;
    for (final message in messages.skip(_persistedCount)) {
      await session.appendMessage(message);
    }
    _persistedCount = messages.length;
  }

  /// Persists one in-memory [message] at the session leaf on demand (the
  /// checkpoint/rewind controller's sink), keeping [_persistedCount] aligned
  /// so the run-end batch persistence skips it. Returns the new record id.
  Future<String> _persistOneMessage(Message message) async {
    final session = _session;
    if (session == null) return '';
    final id = await session.appendMessage(message);
    _persistedCount++;
    return id;
  }

  /// Persists a TTSR injection at the session leaf (the TTSR controller's
  /// sink): the reminder as a hidden `ttsr-injection` custom message (it
  /// projects into context as a user message and survives compaction) plus a
  /// `ttsr_injection` record of the rule names for session restore. Bumps
  /// [_persistedCount] by one — the in-memory injection message then counts
  /// as persisted.
  Future<void> _persistTtsrInjection(
    String content,
    List<String> ruleNames,
  ) async {
    final session = _session;
    if (session == null) return;
    await session.appendCustomMessageEntry(
      customType: ttsrInjectionCustomType,
      content: content,
      display: false,
      details: {'rules': ruleNames},
    );
    await session.appendCustomEntry(
      customType: ttsrInjectionRecordType,
      data: {'rules': ruleNames},
    );
    _persistedCount++;
  }
}
