// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa_ui/src/utils/page_presentation.dart';

/// The settings "Agents" section: the live subagent tree — the main
/// orchestrator row plus every retained child with its status, task preview,
/// token usage, and model. Tapping a child opens [AgentDetailPage] (session
/// tail + a follow-up message field, the CLI `/agents` panel parity).
///
/// Data flows through callbacks so the section stays host-agnostic:
/// [mainDescription] renders the orchestrator row, [observe] tails a
/// child's session, [send] delivers a follow-up message.
class AgentsSection extends StatelessWidget {
  const AgentsSection({
    super.key,
    required this.manager,
    required this.mainDescription,
    required this.observe,
    required this.send,
  });

  /// The session's retained-subagent registry.
  final SubagentManager manager;

  /// Renders the main orchestrator row's description (model + session size).
  final String mainDescription;

  /// Reads the last messages of a child's session as `(role, text)` pairs.
  final Future<List<(String, String)>> Function(String id, {int tail}) observe;

  /// Delivers a follow-up message to a child.
  final Future<void> Function(String id, String message) send;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final children = manager.handles;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _MainRow(description: mainDescription, theme: theme),
        if (children.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'No subagents yet — the task tool spawns them', // l10n:ignore
              style: theme.textTheme.bodySmall,
            ),
          )
        else
          for (final handle in children)
            _ChildRow(
              handle: handle,
              theme: theme,
              onTap: () => _openDetail(context, handle),
            ),
      ],
    );
  }

  Future<void> _openDetail(BuildContext context, SubagentHandle handle) {
    return pushFaPage(
      context,
      AgentDetailPage(handle: handle, observe: observe, send: send),
    );
  }
}

class _MainRow extends StatelessWidget {
  const _MainRow({required this.description, required this.theme});
  final String description;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            Icons.account_tree_outlined,
            size: 20,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('main (orchestrator)'), // l10n:ignore
                Text(
                  description,
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChildRow extends StatelessWidget {
  const _ChildRow({
    required this.handle,
    required this.theme,
    required this.onTap,
  });

  final SubagentHandle handle;
  final ThemeData theme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Text(
              agentStatusEmoji(handle.status),
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${handle.agentType}:${handle.id}'),
                  Text(
                    _description,
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  String get _description {
    final parts = <String>[handle.status.name];
    if (handle.task.isNotEmpty) {
      final task = handle.task.replaceAll('\n', ' ');
      parts.add(task.length > 48 ? '${task.substring(0, 48)}…' : task);
    }
    if (handle.tokens > 0) parts.add('${handle.tokens}t');
    if (handle.modelId != null) parts.add(handle.modelId!);
    return parts.join(' · ');
  }
}

/// One emoji per subagent status (shared by the section and the detail page).
String agentStatusEmoji(SubagentStatus status) => switch (status) {
  SubagentStatus.queued => '⏳',
  SubagentStatus.running => '🔄',
  SubagentStatus.idle => '⏸',
  SubagentStatus.completed => '✅',
  SubagentStatus.failed => '❌',
  SubagentStatus.aborted => '🛑',
};

/// One child's detail page: status header, session tail (via [observe]),
/// and a follow-up message field (via [send]).
class AgentDetailPage extends StatefulWidget {
  const AgentDetailPage({
    super.key,
    required this.handle,
    required this.observe,
    required this.send,
  });

  /// The child being inspected.
  final SubagentHandle handle;

  /// Reads the last messages of the child's session.
  final Future<List<(String, String)>> Function(String id, {int tail}) observe;

  /// Delivers a follow-up message to the child.
  final Future<void> Function(String id, String message) send;

  @override
  State<AgentDetailPage> createState() => _AgentDetailPageState();
}

class _AgentDetailPageState extends State<AgentDetailPage> {
  late final TextEditingController _messageCtrl;
  List<(String, String)>? _messages;
  String? _error;
  var _sending = false;

  @override
  void initState() {
    super.initState();
    _messageCtrl = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _messageCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final messages = await widget.observe(widget.handle.id, tail: 20);
      if (mounted) {
        setState(() {
          _messages = messages;
          _error = null;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _send() async {
    final message = _messageCtrl.text.trim();
    if (message.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.send(widget.handle.id, message);
      _messageCtrl.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Message sent — agent resumed'), // l10n:ignore
            duration: Duration(seconds: 2),
          ),
        );
      }
      await _load();
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('error: $error')), // l10n:ignore
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final handle = widget.handle;
    final terminal = handle.isTerminal;
    return Scaffold(
      appBar: AppBar(
        title: Text('${handle.agentType}:${handle.id}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
            tooltip: 'Reload', // l10n:ignore
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        agentStatusEmoji(handle.status),
                        style: const TextStyle(fontSize: 20),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        handle.status.name,
                        style: theme.textTheme.titleMedium,
                      ),
                      if (handle.tokens > 0) ...[
                        const SizedBox(width: 12),
                        Text(
                          '${handle.tokens}t · ${handle.requests} req',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                  if (handle.task.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(handle.task, style: theme.textTheme.bodySmall),
                  ],
                  if (handle.error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      handle.error!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _messages == null
                  ? const Center(child: CircularProgressIndicator())
                  : _messages!.isEmpty
                  ? Center(
                      child: Text(
                        _error ?? 'No transcript yet', // l10n:ignore
                        style: theme.textTheme.bodySmall,
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _messages!.length,
                      itemBuilder: (context, index) {
                        final (role, text) = _messages![index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                role,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(text),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageCtrl,
                      enabled: !terminal && !_sending,
                      decoration: InputDecoration(
                        hintText: terminal
                            ? 'Agent finished' // l10n:ignore
                            : 'Follow-up message…', // l10n:ignore
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: terminal || _sending ? null : _send,
                    child: Text('Send'), // l10n:ignore
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
