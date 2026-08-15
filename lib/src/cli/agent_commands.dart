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
    final items = <MenuItem>[
      MenuItem(
        key: 'main',
        label: 'main (orchestrator)',
        description:
            '${_agent.state.model.id} · ${_agent.state.messages.length} messages',
      ),
      for (final h in children)
        MenuItem(
          key: 'child:${h.id}',
          label: '${_agentStatusIcon(h.status)} ${h.agentType}:${h.id}',
          description: _agentRowDescription(h),
        ),
    ];
    if (children.isEmpty) {
      items.add(
        const MenuItem(
          key: 'noop',
          label: '(no subagents yet)',
          description: 'spawn one with the task tool',
        ),
      );
    }
    _tuiController!.openPicker('agents', 'Agents', items);
  }

  /// Picker routing for the agents tree (main → info, child → observe view,
  /// noop → nothing).
  Future<void> pickAgentFromTree(String key) async {
    if (key == 'main') {
      await _printMainInfo();
      return;
    }
    if (key == 'noop') return;
    if (key.startsWith('child:')) {
      await _observeSubagent(key.substring(6));
    }
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
      io.writeln('  ${_agentStatusIcon(h.status)} '
          '${h.agentType}:${h.id} — ${_agentRowDescription(h)}');
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
    io.writeln('${_agentStatusIcon(handle.status)} '
        '${handle.agentType}:$id — ${_agentRowDescription(handle)}');
    final tail = await _readChildMessages(handle.sessionId, tail: 8);
    if (tail.isEmpty) {
      io.writeln('  (session transcript unavailable)');
    } else {
      for (final line in tail) {
        io.writeln('  $line');
      }
    }
    if (!_useTui || _tuiController == null) return;
    _tuiController!.openPicker('agentAction', 'agent $id', [
      MenuItem(
        key: 'send:$id',
        label: 'Send message',
        description: 'steer / resume this agent',
      ),
      const MenuItem(key: 'back', label: 'Back', description: 'agents tree'),
    ]);
  }

  /// Picker routing for the child action picker.
  Future<void> pickAgentAction(String key) async {
    if (key == 'back') {
      await _agentsTreePanel();
      return;
    }
    if (key.startsWith('send:')) {
      final id = key.substring(5);
      final message = await _askLine('message for $id: ');
      if (message == null || message.trim().isEmpty) return;
      await _sendToSubagent(id, message.trim());
    }
  }

  /// Delivers a message to a child: live sessions get it appended; the
  /// agent_message queue covers the sibling-family path.
  Future<void> _sendToSubagent(String id, String message) async {
    final handle = _subagentManager[id];
    if (handle == null) {
      io.writeln('no subagent "$id"');
      return;
    }
    if (handle.status == SubagentStatus.failed ||
        handle.status == SubagentStatus.aborted) {
      io.writeln('cannot send to ${handle.status.name} subagent "$id"');
      return;
    }
    final session = await _openChildSession(handle.sessionId);
    if (session == null) {
      // Fall back to the pending queue (sibling delivery semantics).
      await _subagentManager.enqueueMessage(
        id,
        SubagentMessage(
          fromId: 'parent',
          text: message,
          sentAt: DateTime.now().toUtc().toIso8601String(),
        ),
      );
      io.writeln('queued for "$id" (session unavailable)');
      return;
    }
    await session.appendMessage(UserMessage.text(message));
    await _subagentManager.update(id, status: SubagentStatus.running);
    io.writeln('sent to "$id" — agent resumed');
  }

  /// Reads the last [tail] messages of a child's session as
  /// `role: preview` lines (≤ 160 chars each).
  Future<List<String>> _readChildMessages(String sessionId, {int tail = 8}) async {
    final session = await _openChildSession(sessionId);
    if (session == null) return const [];
    final messages = await session.buildContextMessages();
    final last = messages.length > tail
        ? messages.sublist(messages.length - tail)
        : messages;
    return [
      for (final message in last) _previewMessageLine(message),
    ];
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
      AssistantMessage(:final content) => content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join(' '),
      _ => message.role,
    };
    final text = raw is String ? raw : '$raw';
    final flat = text.replaceAll('\n', ' ').trim();
    final preview = flat.length > 160 ? '${flat.substring(0, 160)}…' : flat;
    return '${message.role}: $preview';
  }

  static String _agentStatusIcon(SubagentStatus status) =>
      switch (status) {
        SubagentStatus.queued => '⏳',
        SubagentStatus.running => '🔄',
        SubagentStatus.idle => '⏸',
        SubagentStatus.completed => '✅',
        SubagentStatus.failed => '❌',
        SubagentStatus.aborted => '🛑',
      };

  String _agentRowDescription(SubagentHandle h) {
    final parts = <String>[h.status.name];
    if (h.task.isNotEmpty) {
      final task = h.task.replaceAll('\n', ' ');
      parts.add(
        task.length > 40 ? '${task.substring(0, 40)}…' : task,
      );
    }
    if (h.tokens > 0) parts.add('${h.tokens}t');
    if (h.modelId != null) parts.add(h.modelId!);
    return parts.join(' · ');
  }
}
