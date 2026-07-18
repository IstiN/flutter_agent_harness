import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'agent_service.dart';
import 'app_theme.dart';
import 'settings.dart';
import 'webllm/webllm_types.dart';

/// Width of the left sidebar (model picker + sessions) — side panel on wide
/// layouts, drawer on narrow ones.
const double kSessionSidebarWidth = 280;

/// The left sidebar of the chat screen.
///
/// Top: the active model/provider card — tapping it opens the
/// [SettingsDialog], and applying reconfigures the service mid-chat (the
/// transcript survives, see [AgentService.reconfigure]). Below: the persisted
/// sessions (newest first) with a "New session" action; tapping a session
/// loads it into the chat (see [AgentService.loadSession]).
///
/// The list reads only JSONL headers via [AgentService.listSessions], so
/// rows show what the header exposes cheaply: creation time and the model
/// recorded at session creation.
class SessionSidebar extends StatefulWidget {
  const SessionSidebar({super.key, required this.service, this.onAction});

  /// The chat service backing the model card and the session list.
  final AgentService service;

  /// Called after an action that replaces the chat content (session loaded,
  /// new session started) — the narrow drawer uses it to close itself.
  final VoidCallback? onAction;

  @override
  State<SessionSidebar> createState() => _SessionSidebarState();
}

class _SessionSidebarState extends State<SessionSidebar> {
  /// `null` while the first listing is in flight.
  List<SessionMetadata>? _sessions;
  String? _loadError;

  AgentService get _service => widget.service;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final sessions = await _service.listSessions();
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _loadError = null;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e.toString());
    }
  }

  Future<void> _newSession() async {
    await _service.reset();
    if (!mounted) return;
    widget.onAction?.call();
    await _reload();
  }

  Future<void> _open(SessionMetadata session) async {
    if (session.id != _service.currentSessionId) {
      await _service.loadSession(session);
      if (!mounted) return;
    }
    widget.onAction?.call();
    await _reload();
  }

  Future<void> _switchModel() async {
    await showDialog<void>(
      context: context,
      builder: (_) => SettingsDialog(service: _service),
    );
  }

  static String _providerLabel(String kind) => switch (kind) {
    'openai-completions' => 'OpenAI-compatible API',
    'anthropic' => 'Anthropic',
    'google' => 'Google',
    webLlmProviderKind => 'On-device (WebLLM)',
    _ => kind,
  };

  static String _formatTimestamp(DateTime createdAt) {
    final local = createdAt.toLocal();
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final time = '${two(local.hour)}:${two(local.minute)}';
    final sameDay =
        local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    if (sameDay) return 'Today $time';
    return '${local.year}-${two(local.month)}-${two(local.day)} $time';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Icon(Icons.smart_toy_outlined, size: 20, color: theme.hintColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Model', style: theme.textTheme.titleMedium),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: _buildModelCard(theme),
        ),
        const SizedBox(height: 8),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
          child: Row(
            children: [
              Icon(Icons.history, size: 20, color: theme.hintColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Sessions', style: theme.textTheme.titleMedium),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'New session',
                onPressed: _newSession,
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh sessions',
                onPressed: _reload,
              ),
            ],
          ),
        ),
        Expanded(child: _buildSessionsList(theme)),
      ],
    );
  }

  /// The current-backend card. Rebuilds on every service notification so a
  /// switch applied in the dialog is reflected immediately.
  Widget _buildModelCard(ThemeData theme) {
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        return Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: _switchModel,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.psychology_outlined, color: FahPalette.teal),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _service.modelId,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(
                          _providerLabel(_service.providerKind),
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: FahPalette.dim,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.tune, size: 18, color: FahPalette.dim),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSessionsList(ThemeData theme) {
    final error = _loadError;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Could not load sessions',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                error,
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: _reload,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    final sessions = _sessions;
    if (sessions == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (sessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('No sessions yet', style: theme.textTheme.bodySmall),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      itemCount: sessions.length,
      itemBuilder: (context, index) =>
          _buildSessionTile(theme, sessions[index]),
    );
  }

  Widget _buildSessionTile(ThemeData theme, SessionMetadata session) {
    final active = session.id == _service.currentSessionId;
    final model = (session.metadata?['model'] as String?) ?? '';
    return ListTile(
      dense: true,
      selected: active,
      selectedTileColor: FahPalette.indigo.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      leading: Icon(
        active ? Icons.chat_bubble : Icons.chat_bubble_outline,
        size: 18,
      ),
      title: Text(
        _formatTimestamp(session.createdAt),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        model.isNotEmpty ? model : 'session ${session.id.substring(0, 8)}',
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(color: FahPalette.dim),
      ),
      onTap: () => _open(session),
    );
  }
}
