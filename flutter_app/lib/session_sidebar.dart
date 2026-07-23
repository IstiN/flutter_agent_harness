import 'dart:async';

import 'package:flutter/material.dart';

import 'agent_service.dart';
import 'app_theme.dart';
import 'apps/apps_grid.dart';
import 'apps/apps_store.dart';
import 'apps/js_app_view.dart';
import 'flutter_session_manager.dart';
import 'last_connection.dart';
import 'provider_registry.dart';
import 'settings.dart';
import 'webllm/webllm_types.dart';

/// Width of the left sidebar (model picker + sessions) — side panel on wide
/// layouts, drawer on narrow ones.
const double kSessionSidebarWidth = 280;

/// The left sidebar of the chat screen.
///
/// Top: the active model/provider card — tapping it opens the
/// [SettingsScreen], and applying reconfigures the service mid-chat (the
/// transcript survives, see [AgentService.reconfigure]). Below: the active
/// sessions (newest first) with a "New session" action; tapping a session
/// switches to it without aborting its run.
class SessionSidebar extends StatefulWidget {
  const SessionSidebar({
    super.key,
    required this.manager,
    this.onAction,
    this.registry,
    this.lastConnectionStore,
  });

  /// The multi-session manager backing the model card and the session list.
  final FlutterSessionManager manager;

  /// Called after an action that replaces the chat content (session switched,
  /// new session started) — the narrow drawer uses it to close itself.
  final VoidCallback? onAction;

  /// The custom-provider registry handed to the [SettingsScreen] opened from
  /// the model card; `null` falls back to an in-memory one (tests).
  final ProviderRegistry? registry;

  /// The last-connection store handed to the [SettingsScreen]: applies
  /// update it (see [LastConnectionStore]); `null` skips prefill and
  /// persistence (tests).
  final LastConnectionStore? lastConnectionStore;

  @override
  State<SessionSidebar> createState() => _SessionSidebarState();
}

class _SessionSidebarState extends State<SessionSidebar> {
  /// `null` while the first listing is in flight.
  List<FlutterManagedSession>? _sessions;
  String? _loadError;

  /// JS apps discovered in the env's `apps/` folder (`null` = not loaded).
  List<JsAppInfo>? _apps;
  AppPermissionsStore? _permissionsStore;

  FlutterSessionManager get _manager => widget.manager;

  @override
  void initState() {
    super.initState();
    _reload();
    unawaited(_loadApps());
  }

  Future<void> _reload() async {
    try {
      final sessions = _manager.sessions;
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

  /// (Re)loads the JS app list from the shared env, seeding the bundled demo
  /// apps on first run.
  Future<void> _loadApps() async {
    final service = _manager.active?.service;
    if (service == null) return;
    try {
      _permissionsStore ??= await AppPermissionsStore.load(service.env);
      final store = AppsStore(service.env);
      await store.seedBundledApps();
      final apps = await store.listApps();
      if (mounted) setState(() => _apps = apps);
    } on Object {
      // Apps are optional — a broken apps folder must not break the sidebar.
    }
  }

  Future<void> _openAppsGrid() async {
    final service = _manager.active?.service;
    final permissionsStore = _permissionsStore;
    if (service == null || permissionsStore == null) return;
    widget.onAction?.call();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AppsGridView(
          env: service.env,
          permissionsStore: permissionsStore,
          llmHandler: service.completeOnce,
          onSendToAgent: _sendAppMessageToAgent,
          fsRevision: service.fsRevision,
        ),
      ),
    );
    await _loadApps();
  }

  Future<void> _openApp(JsAppInfo app) async {
    final service = _manager.active?.service;
    final permissionsStore = _permissionsStore;
    if (service == null || permissionsStore == null) return;
    widget.onAction?.call();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => JsAppView(
          app: app,
          env: service.env,
          permissionsStore: permissionsStore,
          llmHandler: service.completeOnce,
          onSendToAgent: _sendAppMessageToAgent,
          fsRevision: service.fsRevision,
        ),
      ),
    );
    await _loadApps();
  }

  /// Forwards an in-app Fa message (text + app state + screenshot) to the
  /// active session's agent.
  Future<void> _sendAppMessageToAgent(FaAppMessage message) async {
    final service = _manager.active?.service;
    if (service == null) return;
    final buffer = StringBuffer(message.text);
    final stateJson = message.appStateJson;
    if (stateJson != null) {
      buffer.write('\n\nCurrent app state:\n```json\n$stateJson\n```');
    }
    final screenshot = message.screenshot;
    if (screenshot != null) {
      await service.sendImage(
        bytes: screenshot,
        mimeType: 'image/png',
        text: buffer.toString(),
      );
    } else {
      await service.sendText(buffer.toString());
    }
  }

  Future<void> _newSession() async {
    // The manager creates the new AgentService via its factory; the factory
    // is injected by the chat screen (see ChatScreen).
    final config = _manager.active!.service.configForClone;
    if (config == null) {
      // Pre-constructed Agent (tests): create a fresh AgentService directly.
      await _manager.createSession(
        config: AgentConfig(
          providerKind: _manager.active!.service.providerKind,
          modelId: _manager.active!.service.modelId,
          baseUrl: '',
          apiKey: '',
        ),
        serviceFactory: () async => _manager.active!.service.clone(),
      );
    } else {
      await _manager.createSession(
        config: config,
        serviceFactory: () async => _manager.active!.service.clone(),
      );
    }
    if (!mounted) return;
    widget.onAction?.call();
    await _reload();
  }

  Future<void> _open(FlutterManagedSession session) async {
    if (session.id != _manager.activeId) {
      _manager.switchTo(session.id);
      if (!mounted) return;
    }
    widget.onAction?.call();
    await _reload();
  }

  /// Per-row delete, behind a confirmation dialog. Deleting the active
  /// session switches to the most recent remaining session, or none if the
  /// manager is empty.
  Future<void> _delete(FlutterManagedSession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete session?'),
        content: const Text('This removes the saved session permanently.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final wasActive = session.id == _manager.activeId;
    try {
      await _manager.closeSession(session.id, deleteFile: true);
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('Could not delete session: $e'),
              duration: const Duration(seconds: 3),
            ),
          );
      }
      return;
    }
    if (!mounted) return;
    if (wasActive) widget.onAction?.call();
    await _reload();
  }

  Future<void> _switchModel() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          service: _manager.active!.service,
          registry: widget.registry,
          lastConnectionStore: widget.lastConnectionStore,
        ),
      ),
    );
  }

  static String _providerLabel(String kind) => switch (kind) {
    'openai-completions' => 'OpenAI-compatible API',
    'anthropic' => 'Anthropic',
    'google' => 'Google',
    webLlmProviderKind => 'On-device (WebLLM)',
    _ => kind,
  };

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
        _buildAppsSection(theme),
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

  /// The JS-apps section: header with a grid-launcher button plus up to five
  /// app tiles that open their [JsAppView] directly.
  Widget _buildAppsSection(ThemeData theme) {
    final apps = _apps ?? const <JsAppInfo>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
          child: Row(
            children: [
              Icon(Icons.widgets_outlined, size: 20, color: theme.hintColor),
              const SizedBox(width: 8),
              Expanded(child: Text('Apps', style: theme.textTheme.titleMedium)),
              IconButton(
                icon: const Icon(Icons.grid_view_rounded),
                tooltip: 'Open apps grid',
                onPressed: _openAppsGrid,
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh apps',
                onPressed: _loadApps,
              ),
            ],
          ),
        ),
        for (final app in apps.take(5))
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: Text(app.icon, style: const TextStyle(fontSize: 20)),
            title: Text(app.name, overflow: TextOverflow.ellipsis),
            onTap: () => _openApp(app),
          ),
        if (apps.length > 5)
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: const Icon(Icons.more_horiz),
            title: Text('All apps (${apps.length})'),
            onTap: _openAppsGrid,
          ),
      ],
    );
  }

  /// The current-backend card. Rebuilds on every manager notification so a
  /// switch applied in the dialog is reflected immediately.
  Widget _buildModelCard(ThemeData theme) {
    return ListenableBuilder(
      listenable: _manager,
      builder: (context, _) {
        final service = _manager.active?.service;
        if (service == null) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text('No active session'),
            ),
          );
        }
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
                          service.modelId,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(
                          _providerLabel(service.providerKind),
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

  Widget _buildSessionTile(ThemeData theme, FlutterManagedSession session) {
    final active = session.id == _manager.activeId;
    final model = session.service.modelId;
    final streaming = session.service.isStreaming;
    return ListTile(
      dense: true,
      selected: active,
      selectedTileColor: FahPalette.indigo.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      leading: Icon(
        streaming
            ? Icons.sync
            : active
            ? Icons.chat_bubble
            : Icons.chat_bubble_outline,
        size: 18,
      ),
      title: Text(
        'session ${session.id.substring(0, 8)}',
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        model.isNotEmpty ? model : 'no model',
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(color: FahPalette.dim),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline, size: 18),
        tooltip: 'Delete session',
        onPressed: () => _delete(session),
      ),
      onTap: () => _open(session),
    );
  }
}
