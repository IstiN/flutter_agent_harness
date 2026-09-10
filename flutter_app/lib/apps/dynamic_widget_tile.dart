// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/dynamic_messages.dart';
import 'package:fa/apps/fa_js3d_host.dart';
import 'package:fa/apps/fa_media_host.dart';
import 'package:fa/apps/js_app_view.dart' show AppPermissionsDialog;
import 'package:fa/apps/js_theme.dart';
import 'package:fa/apps/viewport_reporter.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa_ui/fa_ui.dart' show FaChatMessage;
import 'package:flutter/material.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';

/// The inline chat tile of one interactive dynamic message (issue #102):
/// a title bar (title + live badge + "save as app" + permissions +
/// collapse) over the live engine UI tree. The engine boots lazily on
/// first render and is owned by the session's [DynamicMessagesService];
/// boot failures render as an expandable error tile (AC9) instead of
/// crashing the chat.
class DynamicWidgetTile extends StatefulWidget {
  const DynamicWidgetTile({
    super.key,
    required this.service,
    required this.message,
    this.onSaveAsApp,
  });

  /// The session's dynamic-messages service owning engines and errors.
  final DynamicMessagesService service;

  /// The `widget`-role transcript message; [FaChatMessage.data] carries
  /// the widget id.
  final FaChatMessage message;

  /// Graduates the widget into an installed app (the host opens the
  /// publish sheet prefilled); null hides the affordance.
  final Future<void> Function(DynamicMessageDefinition definition)? onSaveAsApp;

  @override
  State<DynamicWidgetTile> createState() => _DynamicWidgetTileState();
}

class _DynamicWidgetTileState extends State<DynamicWidgetTile> {
  bool _expanded = true;
  bool _errorExpanded = true;
  bool _bootScheduled = false;

  String? get _widgetId => widget.message.data?.toString();

  @override
  Widget build(BuildContext context) {
    final definition = _resolve();
    if (definition == null) return const SizedBox.shrink();
    _scheduleBoot(definition);
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final definition = _resolve();
        if (definition == null) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _titleBar(context, definition),
              if (_expanded) _body(context, definition),
            ],
          ),
        );
      },
    );
  }

  DynamicMessageDefinition? _resolve() {
    final id = _widgetId;
    if (id == null) return null;
    return widget.service.byId(id);
  }

  void _scheduleBoot(DynamicMessageDefinition definition) {
    if (_bootScheduled) return;
    if (widget.service.engineFor(definition.id) != null) return;
    _bootScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bootScheduled = false;
      if (!mounted || _resolve()?.id != definition.id) return;
      unawaited(
        widget.service.ensureEngine(
          definition,
          locale: Localizations.localeOf(context).languageCode,
          theme: jsThemeMap(context),
        ),
      );
    });
  }

  Widget _titleBar(BuildContext context, DynamicMessageDefinition definition) {
    final live = widget.service.engineFor(definition.id) != null;
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            Text(
              '✦',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                definition.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (live) DynamicLiveBadge(),
            IconButton(
              tooltip: context.l10n.dynamicTileSaveAsApp,
              icon: const Icon(Icons.archive_outlined, size: 20),
              onPressed: widget.onSaveAsApp == null
                  ? null
                  : () => unawaited(widget.onSaveAsApp!(definition)),
            ),
            IconButton(
              tooltip: context.l10n.dynamicTilePermissions,
              icon: const Icon(Icons.shield_outlined, size: 20),
              onPressed: () => unawaited(_editPermissions(definition)),
            ),
            Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 20),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, DynamicMessageDefinition definition) {
    final error = widget.service.bootErrorFor(definition.id);
    if (error != null) return _errorTile(context, definition, error);
    final engine = widget.service.engineFor(definition.id);
    if (engine == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    // The height hint is a suggestion, not a command: clamped so one
    // widget can neither collapse to nothing nor eat the whole chat.
    final height = (definition.heightHint ?? 320).clamp(120.0, 560.0);
    return SizedBox(
      height: height,
      child: ValueListenableBuilder<Map<String, dynamic>?>(
        valueListenable: engine.tree,
        builder: (context, tree, _) {
          if (tree == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final scheme = Theme.of(context).colorScheme;
          final brightness = Theme.of(context).brightness;
          final renderer = JsonWidgetRenderer(
            theme: JsonWidgetTheme.fromAccent(
              scheme.primary,
              brightness: brightness,
            ),
            mediaHost: const FaMediaHost(),
            js3dHost: createFaJs3dHost(widget.service.env),
            onScene3dTap: (sceneId, payload) =>
                engine.dispatchHostEvent('scene3d.tap:$sceneId', payload),
            onEvent: (actionId, payload) =>
                unawaited(engine.callEvent(actionId, payload)),
          );
          Widget body;
          try {
            body = renderer.build(tree, context);
          } on Object catch (error) {
            // A tree the renderer cannot draw (replayed E6 definition, new
            // renderer against old node kinds) — error tile, never a crash.
            return _errorTile(context, definition, '$error');
          }
          return ViewportReporter(
            onSize: (size) => engine.dispatchHostEvent('viewport', {
              'width': size.width,
              'height': size.height,
            }),
            child: ClipRect(child: body),
          );
        },
      ),
    );
  }

  Widget _errorTile(
    BuildContext context,
    DynamicMessageDefinition definition,
    String error,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border.all(color: scheme.error),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline, size: 18, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.l10n.dynamicTileError,
                    style: Theme.of(
                      context,
                    ).textTheme.titleSmall?.copyWith(color: scheme.error),
                  ),
                ),
                IconButton(
                  tooltip: context.l10n.dynamicTileRetry,
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: () => _scheduleBoot(definition),
                ),
                IconButton(
                  tooltip: context.l10n.dynamicTileError,
                  icon: Icon(
                    _errorExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                  ),
                  onPressed: () =>
                      setState(() => _errorExpanded = !_errorExpanded),
                ),
              ],
            ),
            if (_errorExpanded)
              Text(
                error,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontFamily: 'JetBrainsMono',
                  color: scheme.error,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The app permission dialog, identical to an installed app's: grants
  /// persist into `apps_permissions.json` and apply on an engine restart
  /// (fresh boot — the same rule as the app view).
  Future<void> _editPermissions(DynamicMessageDefinition definition) async {
    final store = await AppPermissionsStore.load(widget.service.env);
    if (!mounted) return;
    final changed = await showDialog<bool>(
      context: context,
      builder: (context) => AppPermissionsDialog(
        app: widget.service.appInfoFor(definition),
        env: widget.service.env,
        store: store,
      ),
    );
    if (changed != true || !mounted) return;
    await widget.service.restartEngine(
      definition,
      locale: Localizations.localeOf(context).languageCode,
      theme: jsThemeMap(context),
    );
  }
}

/// The small "live" chip marking a widget with a running engine (the tile
/// title bar and the ✦ list).
class DynamicLiveBadge extends StatelessWidget {
  const DynamicLiveBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: Colors.green,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            context.l10n.dynamicMessagesLive,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}
