/// Agent discovery and listing commands split from [AgentCli] to keep
/// agent_cli.dart under the repo's 2800-line size gate.
/// Same library (a `part of`), so the extension sees the class's private members.
part of 'agent_cli.dart';

/// Implementation members of [AgentCli] for agent-type discovery and listing.
extension AgentCliAgentExt on AgentCli {
  /// Fire-and-forget discovery: scans project + user roots for agent .md files.
  Future<void> discoverAgentsFromRoots(
    ({List<String> projectRoots, List<String> userRoots}) roots,
  ) async {
    final result = await discoverTaskAgents(
      config.env,
      projectRoots: roots.projectRoots,
      userRoots: roots.userRoots,
    );
    _discoveredAgents = result.agents;
    for (final note in result.notes) {
      io.writeln('  agent discovery: $note');
    }
  }

  /// `/agents`: lists all available agent types (built-in + discovered).
  void listAgentTypes() {
    io.writeln('agent types:');
    _listBuiltinAgentTypes();
    _listDiscoveredAgentTypes();
  }

  void _listBuiltinAgentTypes() {
    for (final name in ['task', 'explore', 'review']) {
      io.writeln('  $name (built-in)');
    }
  }

  void _listDiscoveredAgentTypes() {
    for (final agent in _discoveredAgents) {
      io.writeln('  ${agent.name} — ${agent.description}');
    }
    if (_discoveredAgents.isEmpty) {
      io.writeln(
        '  (no discovered types — add .fah/agents/<name>.md to extend)',
      );
    }
  }

  /// `/agents [types|<id>]` — the agents tree panel (Variant B):
  /// - bare: the live tree — main + retained children with statuses; a TUI
  ///   picker when interactive, a text tree in line mode;
  /// - `types`: the agent-type catalog (built-in + discovered);
  /// - `<id>`: observe one child's session tail directly.
  Future<void> handleAgentsCommand(String rest) async {
    final arg = rest.split(RegExp(r'\s+')).first.trim();
    if (arg == 'types') {
      listAgentTypes();
      return;
    }
    if (arg.isNotEmpty && arg != 'types') {
      await _observeSubagent(arg);
      return;
    }
    await _agentsTreePanel();
  }

  /// The live agents tree: TUI picker of main + children, or a text dump in
  /// line mode.
  Future<void> _agentsTreePanel() async {
    final children = _subagentManager.handles;
    if (!_useTui || _tuiController == null) {
      _printAgentsTree(children);
      return;
    }
    _tuiController!.openPicker(
      'agents',
      'Agents',
      buildAgentTreeItems(
        children,
        modelId: _agent.state.model.id,
        messageCount: _agent.state.messages.length,
      ),
    );
  }

  /// Picker routing for the agents tree (main → info, child → observe view,
  /// noop → nothing).
  Future<void> pickAgentFromTree(String key) async {
    if (key == 'main') return _printMainInfo();
    if (key.startsWith('child:')) return _observeSubagent(key.substring(6));
  }

  /// Prints the main session's summary (bare selection of "main").
  Future<void> _printMainInfo() async {
    final model = _agent.state.model;
    io.writeln('[main]');
    io.writeln('  model: ${model.id} (${model.provider})');
    io.writeln('  messages: ${_agent.state.messages.length}');
    final session = _session;
    if (session != null) {
      final metadata = await session.getMetadata();
      io.writeln('  session: ${metadata.path}');
    }
    io.writeln('  children: ${_subagentManager.handles.length}');
  }

  /// Text-mode agents tree (line mode or non-TUI fallback).
  void _printAgentsTree(List<SubagentHandle> children) {
    io.writeln('main (orchestrator) · ${_agent.state.model.id}');
    if (children.isEmpty) {
      io.writeln('  (no subagents yet)');
      return;
    }
    for (final h in children) {
      io.writeln(
        '  ${agentStatusIcon(h.status)} '
        '${h.agentType}:${h.id} — ${agentRowDescription(h)}',
      );
    }
    io.writeln('  /agents <id> to observe · /agents types for the catalog');
  }

  /// Observes one child: prints its session tail, then (TUI) opens the
  /// action picker (send / back).
  Future<void> _observeSubagent(String id) async {
    final handle = _subagentManager[id];
    if (handle == null) {
      io.writeln(
        'no subagent "$id" — available: '
        '${_subagentManager.handles.map((h) => h.id).join(', ')}',
      );
      return;
    }
    await _printSubagentObservation(handle);
    if (!_useTui || _tuiController == null) return;
    _tuiController!.openPicker('agentAction', 'agent $id', [
      MenuItem(
        key: 'open:$id',
        label: 'Open session',
        description: 'switch into this agent\'s session (/sessions to go back)',
      ),
      MenuItem(
        key: 'send:$id',
        label: 'Send message',
        description: 'steer / resume this agent',
      ),
      const MenuItem(key: 'back', label: 'Back', description: 'agents tree'),
    ]);
  }

  /// Prints one child's status row plus its session tail (the observe view's
  /// transcript part).
  Future<void> _printSubagentObservation(SubagentHandle handle) async {
    io.writeln(
      '${agentStatusIcon(handle.status)} '
      '${handle.agentType}:${handle.id} — ${agentRowDescription(handle)}',
    );
    final tail = await _readChildMessages(handle.sessionId, tail: 8);
    if (tail.isEmpty) {
      io.writeln('  (session transcript unavailable)');
      return;
    }
    for (final line in tail) {
      io.writeln('  $line');
    }
  }

  /// Picker routing for the child action picker.
  Future<void> pickAgentAction(String key) async {
    if (key == 'back') return _agentsTreePanel();
    if (key.startsWith('send:')) {
      await _askAndSendSubagent(key.substring(5));
      return;
    }
    if (key.startsWith('open:')) {
      await _openSubagentSession(key.substring(5));
    }
  }

  /// Switches the CLI session into the child's session (Variant B "select"):
  /// the user watches the subagent's transcript live and returns to the
  /// parent with `/sessions` or `/resume`.
  Future<void> _openSubagentSession(String id) async {
    final handle = _subagentManager[id];
    final session = handle == null
        ? null
        : await _openChildSession(handle.sessionId);
    if (handle == null || session == null) {
      io.writeln('cannot open session for "$id" (unavailable)');
      return;
    }
    final metadata = await session.getMetadata();
    await _switchToMetadata(metadata, 'subagent ${handle.agentType}:$id');
  }

  /// The send flow of the child action picker: prompt for the message and
  /// deliver it to the child.
  Future<void> _askAndSendSubagent(String id) async {
    final message = await _askLine('message for $id: ');
    if (message == null || message.trim().isEmpty) return;
    await _sendToSubagent(id, message.trim());
  }

  /// Delivers a message to a child: live sessions get it appended; the
  /// agent_message queue covers the sibling-family path.
  Future<void> _sendToSubagent(String id, String message) async {
    final handle = _subagentManager[id];
    final guard = subagentReceiveGuard(handle, id);
    if (guard != null) {
      io.writeln(guard);
      return;
    }
    if (await _appendToChildSession(handle!, message)) {
      await _subagentManager.update(id, status: SubagentStatus.running);
      io.writeln('sent to "$id" — agent resumed');
    } else {
      await _queueSubagentMessage(id, message);
      io.writeln('queued for "$id" (session unavailable)');
    }
  }

  /// Appends [message] to the child's session file; false when the session
  /// is unavailable (caller falls back to the pending queue).
  Future<bool> _appendToChildSession(
    SubagentHandle handle,
    String message,
  ) async {
    final session = await _openChildSession(handle.sessionId);
    if (session == null) return false;
    await session.appendMessage(UserMessage.text(message));
    return true;
  }

  /// Queues [message] for [id] through the sibling pending queue (the
  /// fallback when the child session file cannot be opened).
  Future<void> _queueSubagentMessage(String id, String message) async {
    await _subagentManager.enqueueMessage(
      id,
      SubagentMessage(
        fromId: 'parent',
        text: message,
        sentAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
  }

  /// Reads the last [tail] messages of a child's session as
  /// `role: preview` lines (≤ 160 chars each).
  Future<List<String>> _readChildMessages(
    String sessionId, {
    int tail = 8,
  }) async {
    final session = await _openChildSession(sessionId);
    if (session == null) return const [];
    final messages = await session.buildContextMessages();
    final last = messages.length > tail
        ? messages.sublist(messages.length - tail)
        : messages;
    return [for (final message in last) _previewMessageLine(message)];
  }

  Future<Session?> _openChildSession(String sessionId) async {
    try {
      final metadata = SessionMetadata(
        id: sessionId,
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        cwd: config.env.cwd,
        path: sessionId,
      );
      final exists = await config.env.fileInfo(sessionId);
      if (exists.valueOrNull == null) return null;
      return await _repo.open(metadata);
    } on Object {
      return null;
    }
  }

  String _previewMessageLine(Message message) {
    final Object raw = switch (message) {
      UserMessage(:final content) => content,
      AssistantMessage(:final content) =>
        content.whereType<TextContent>().map((b) => b.text).join(' '),
      _ => message.role,
    };
    final text = raw is String ? raw : '$raw';
    final flat = text.replaceAll('\n', ' ').trim();
    final preview = flat.length > 160 ? '${flat.substring(0, 160)}…' : flat;
    return '${message.role}: $preview';
  }
}
