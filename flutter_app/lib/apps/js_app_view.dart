// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';

import 'apps_store.dart';
import 'js_app_engine.dart';

/// Payload delivered when the user talks to Fa from inside an app: their
/// message, the app's exported state, and a screenshot of the app.
class FaAppMessage {
  const FaAppMessage({required this.text, this.appStateJson, this.screenshot});

  final String text;
  final String? appStateJson;
  final Uint8List? screenshot;
}

/// Full-screen host for one JS app: renders the JS-driven UI via
/// [JsonWidgetRenderer], offers reload + permissions in the app bar, and a
/// floating Fa button that sends the agent a message with the app's current
/// state and a screenshot.
class JsAppView extends StatefulWidget {
  const JsAppView({
    super.key,
    required this.app,
    required this.env,
    required this.permissionsStore,
    this.llmHandler,
    this.platformHandler,
    this.onSendToAgent,
    this.fsRevision,
  });

  final JsAppInfo app;
  final ExecutionEnv env;
  final AppPermissionsStore permissionsStore;
  final FaLlmHandler? llmHandler;
  final FaPlatformHandler? platformHandler;

  /// Called with the composed Fa message; typically forwards to
  /// `AgentService.sendImage`/`sendText` of the active session.
  final Future<void> Function(FaAppMessage message)? onSendToAgent;

  /// Bumped when the agent edits files (AgentService.fsRevision) — the app
  /// reloads itself so agent-written code shows up live.
  final ValueNotifier<int>? fsRevision;

  @override
  State<JsAppView> createState() => _JsAppViewState();
}

class _JsAppViewState extends State<JsAppView> {
  JsAppEngine? _engine;
  Object? _startError;
  final _boundaryKey = GlobalKey();
  bool _faSheetOpen = false;
  Timer? _reloadDebounce;
  int _lastFsRevision = -1;

  @override
  void initState() {
    super.initState();
    widget.fsRevision?.addListener(_onFsRevision);
    unawaited(_restart());
  }

  @override
  void didUpdateWidget(JsAppView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fsRevision != widget.fsRevision) {
      oldWidget.fsRevision?.removeListener(_onFsRevision);
      widget.fsRevision?.addListener(_onFsRevision);
    }
  }

  @override
  void dispose() {
    widget.fsRevision?.removeListener(_onFsRevision);
    _reloadDebounce?.cancel();
    unawaited(_engine?.dispose() ?? Future.value());
    super.dispose();
  }

  void _onFsRevision() {
    final revision = widget.fsRevision?.value ?? 0;
    if (revision == _lastFsRevision) return;
    _lastFsRevision = revision;
    // Debounce: agent edits often write manifest + widget.js back to back.
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 600), () {
      if (mounted && !_faSheetOpen) unawaited(_restart());
    });
  }

  Future<void> _restart() async {
    final old = _engine;
    setState(() {
      _engine = null;
      _startError = null;
    });
    if (old != null) await old.dispose();
    try {
      final effective = widget.permissionsStore.forApp(widget.app).effective();
      final engine = JsAppEngine(
        app: widget.app,
        env: widget.env,
        permissions: effective,
        llmHandler: widget.llmHandler,
        platformHandler: widget.platformHandler,
      );
      await engine.start();
      if (!mounted) {
        await engine.dispose();
        return;
      }
      setState(() => _engine = engine);
    } on Object catch (error) {
      if (mounted) setState(() => _startError = error);
    }
  }

  Future<Uint8List?> _captureScreenshot() async {
    try {
      final boundary =
          _boundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return bytes?.buffer.asUint8List();
    } on Object {
      return null;
    }
  }

  Future<void> _openFaSheet() async {
    if (widget.onSendToAgent == null) return;
    setState(() => _faSheetOpen = true);
    try {
      final message = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        builder: (context) => _FaMessageSheet(app: widget.app),
      );
      if (message == null || message.trim().isEmpty || !mounted) return;
      final engine = _engine;
      final state = engine?.exportedState;
      final screenshot = await _captureScreenshot();
      await widget.onSendToAgent!(
        FaAppMessage(
          text: message.trim(),
          appStateJson: state == null ? null : jsonEncode(state),
          screenshot: screenshot,
        ),
      );
    } finally {
      if (mounted) setState(() => _faSheetOpen = false);
    }
  }

  Future<void> _openPermissions() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (context) => _AppPermissionsDialog(
        app: widget.app,
        store: widget.permissionsStore,
      ),
    );
    if (changed == true) await _restart();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text(widget.app.icon),
            const SizedBox(width: 8),
            Flexible(
              child: Text(widget.app.name, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.shield_outlined),
            tooltip: 'App permissions',
            onPressed: _openPermissions,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload app',
            onPressed: _restart,
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              key: _boundaryKey,
              child: ColoredBox(
                color: theme.scaffoldBackgroundColor,
                child: _buildBody(theme),
              ),
            ),
          ),
          if (widget.onSendToAgent != null)
            Positioned(
              right: 16,
              bottom: 16,
              child: FloatingActionButton.small(
                heroTag: 'fa-${widget.app.id}',
                tooltip: 'Ask Fa about this app',
                onPressed: _openFaSheet,
                child: const Text('Fa'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final error = _startError;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Failed to start ${widget.app.name}:\n$error',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
      );
    }
    final engine = _engine;
    if (engine == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ValueListenableBuilder<Map<String, dynamic>?>(
      valueListenable: engine.tree,
      builder: (context, tree, _) {
        if (tree == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final renderer = JsonWidgetRenderer(
          theme: JsonWidgetTheme.fromAccent(theme.colorScheme.primary),
          onEvent: (actionId, payload) {
            unawaited(engine.callEvent(actionId, payload));
          },
        );
        return ClipRect(child: renderer.build(tree, context));
      },
    );
  }
}

/// Bottom sheet collecting the user's message to Fa about the current app.
class _FaMessageSheet extends StatefulWidget {
  const _FaMessageSheet({required this.app});

  final JsAppInfo app;

  @override
  State<_FaMessageSheet> createState() => _FaMessageSheetState();
}

class _FaMessageSheetState extends State<_FaMessageSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Ask Fa about ${widget.app.name}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Fa gets your message, the app state and a screenshot.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText: 'e.g. make the buttons bigger and purple',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.send),
            label: const Text('Send to Fa'),
            onPressed: () => Navigator.of(context).pop(_controller.text),
          ),
        ],
      ),
    );
  }
}

/// Per-app permission toggles; writes overrides to [AppPermissionsStore].
class _AppPermissionsDialog extends StatefulWidget {
  const _AppPermissionsDialog({required this.app, required this.store});

  final JsAppInfo app;
  final AppPermissionsStore store;

  @override
  State<_AppPermissionsDialog> createState() => _AppPermissionsDialogState();
}

class _AppPermissionsDialogState extends State<_AppPermissionsDialog> {
  late AppPermissions _current;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _current = widget.store.forApp(widget.app).effective();
  }

  void _set(AppPermissions next) {
    setState(() {
      _current = next;
      _changed = true;
    });
    unawaited(widget.store.setOverride(widget.app.id, next));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.app.icon} ${widget.app.name} permissions'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _toggle(
            'Network',
            'jsr.fetchJson — let the app call HTTP APIs',
            _current.network,
            (v) => _set(_current.copyWith(network: v)),
          ),
          _toggle(
            'LLM',
            'jsr.fa.llm — let the app ask the connected model',
            _current.llm,
            (v) => _set(_current.copyWith(llm: v)),
          ),
          _toggle(
            'HomeKit',
            'jsr.fa.homekit — smart home devices (coming soon)',
            _current.homekit,
            (v) => _set(_current.copyWith(homekit: v)),
          ),
          _toggle(
            'Health',
            'jsr.fa.health — health data (coming soon)',
            _current.health,
            (v) => _set(_current.copyWith(health: v)),
          ),
          _toggle(
            'Contacts',
            'jsr.fa.contacts — address book (coming soon)',
            _current.contacts,
            (v) => _set(_current.copyWith(contacts: v)),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_changed),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _toggle(
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return SwitchListTile(
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
      dense: true,
      contentPadding: EdgeInsets.zero,
    );
  }
}
