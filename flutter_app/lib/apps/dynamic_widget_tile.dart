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
import 'package:fa/apps/widget_overflow_watch.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa_ui/fa_ui.dart' show FaChatMessage;
import 'package:flutter/material.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';

/// The inline chat tile of one interactive dynamic message (issue #102):
/// a title bar (title + live badge + ⋮ overflow menu, issue #378) over the
/// live engine UI tree. The engine boots lazily on first render and is
/// owned by the session's [DynamicMessagesService]; boot failures render
/// as an expandable error tile (AC9) instead of crashing the chat.
/// Viewport width (logical px) at or below which the dynamic-widget tile
/// goes edge-to-edge — zero horizontal margin (issue #457 AC1). Above it
/// the desktop padding stays (the #379 breakpoint discipline).
const double kDynamicTileFullWidthBreakpoint = 600;

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

  String? get _widgetId => widget.message.data?.toString();

  @override
  Widget build(BuildContext context) {
    final definition = _resolve();
    if (definition == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final definition = _resolve();
        if (definition == null) return const SizedBox.shrink();
        // Issue #457 AC1: edge-to-edge on narrow (phone) viewports, the
        // desktop margin preserved on wider canvases.
        return Container(
          margin: EdgeInsets.symmetric(
            horizontal:
                MediaQuery.sizeOf(context).width <=
                    kDynamicTileFullWidthBreakpoint
                ? 0
                : 12,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _titleBar(context, definition),
              // Issue #692 C: once the canvas reported a viewport overflow,
              // an error-colored strip says so — the clipping is never
              // silent and the agent has been told (one-shot note).
              if (widget.service.overflowNotedFor(definition.id))
                _overflowStrip(context),
              if (_expanded)
                DynamicWidgetCanvas(
                  service: widget.service,
                  definition: definition,
                ),
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

  /// The overflow strip (issue #692 C): the canvas reported content
  /// wider than the viewport; the agent got a one-shot note. Renders in
  /// the error colors (errorContainer/error) — not an amber tone.
  Widget _overflowStrip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.35),
        border: Border(
          top: BorderSide(color: scheme.error.withValues(alpha: 0.4)),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.unfold_more, size: 14, color: scheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              context.l10n.dynamicTileOverflow,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onErrorContainer.withValues(alpha: 0.9),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The title bar (issues #378+#457 AC2): the primary "open as app
  /// (without saving)" icon, the chevron, and the ⋮ overflow menu — each
  /// owning its taps outside the collapse zone. The live status renders
  /// as a minimal dot (the pill spent header width for near-zero value,
  /// #457 AC2). The title tap still toggles collapse (#377 contract).
  Widget _titleBar(BuildContext context, DynamicMessageDefinition definition) {
    final live = widget.service.engineFor(definition.id) != null;
    final bootBroken = widget.service.bootErrorFor(definition.id) != null;
    // Hit-test isolation (issue #377): the collapse tap zone covers ONLY
    // the title zone (spark, title, status dot); the action buttons and
    // the chevron live outside its gesture scope, so an action tap can
    // never reach the collapse handler — including the promoted
    // open-as-app icon (issue #457 AC2 REG).
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(12),
              ),
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
                  // Issue #457 AC2: the `● live` pill minimized to a dot
                  // (tooltip keeps the meaning); still updated live by
                  // the service listenable (E2).
                  if (live)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Tooltip(
                        message: context.l10n.dynamicMessagesLive,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Colors.green,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            // 28px zone = the old [Icon, SizedBox(8)] footprint, so the
            // chevron (and everything left of it) sits pixel-identical.
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 8, 8),
              child: Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                size: 20,
              ),
            ),
          ),
          // The promoted primary action (issue #457 AC2): opens the
          // ephemeral runtime without saving. Owns its taps — it sits
          // outside every collapse gesture zone (#377 isolation). A
          // failed boot disables it with the reason in the tooltip,
          // matching the ⋮ row's E1 rule.
          IconButton(
            tooltip: bootBroken
                ? context.l10n.dynamicTileOpenUnavailable
                : context.l10n.dynamicTileOpenAsApp,
            icon: const Icon(Icons.open_in_new, size: 20),
            onPressed: bootBroken
                ? null
                : () => unawaited(
                    pushEphemeralDynamicApp(
                      context,
                      widget.service,
                      definition,
                    ),
                  ),
          ),
          // Owns its taps: the ⋮ never toggles the title-tap collapse
          // (issue #378; the #377 isolation contract holds — the menu
          // sits outside every collapse gesture zone).
          dynamicWidgetMenuButton(
            context: context,
            service: widget.service,
            definition: definition,
            onSaveAsApp: widget.onSaveAsApp,
          ),
        ],
      ),
    );
  }
}

/// The live UI of one dynamic widget definition: lazy boot, boot spinner,
/// the expandable AC9 error tile, or the rendered engine tree. Shared by
/// the transcript tile body and the ephemeral full-screen view (issue
/// #378) so both surfaces render — and boot — identically.
class DynamicWidgetCanvas extends StatefulWidget {
  const DynamicWidgetCanvas({
    super.key,
    required this.service,
    required this.definition,
    this.fillAvailable = false,
  });

  /// The session's dynamic-messages service owning engines and errors.
  final DynamicMessagesService service;

  /// The widget definition to boot and render.
  final DynamicMessageDefinition definition;

  /// Issue #457 AC4: fill the surrounding box (the ephemeral full-screen
  /// runtime) instead of the clamped height hint. Either way the inner
  /// viewport scrolls, so content is never clipped.
  final bool fillAvailable;

  @override
  State<DynamicWidgetCanvas> createState() => _DynamicWidgetCanvasState();
}

class _DynamicWidgetCanvasState extends State<DynamicWidgetCanvas> {
  bool _errorExpanded = true;
  bool _bootScheduled = false;
  final ScrollController _scroll = ScrollController();

  @override
  void didUpdateWidget(DynamicWidgetCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Issue #457 AC4: opening (or re-targeting) the canvas starts at the
    // top — content is reachable by scrolling, never pre-clipped mid-view.
    if (widget.definition.id != oldWidget.definition.id && _scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scheduleBoot() {
    if (_bootScheduled) return;
    if (widget.service.engineFor(widget.definition.id) != null) return;
    _bootScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bootScheduled = false;
      if (!mounted) return;
      unawaited(
        widget.service.ensureEngine(
          widget.definition,
          locale: Localizations.localeOf(context).languageCode,
          theme: jsThemeMap(context),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    // A cached boot failure is only cleared by the explicit retry —
    // otherwise every scroll-driven rebuild re-boots a broken widget.
    if (!widget.service.bootFailed(widget.definition.id)) {
      _scheduleBoot();
    }
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final error = widget.service.bootErrorFor(widget.definition.id);
        if (error != null) return _errorTile(context, error);
        final engine = widget.service.engineFor(widget.definition.id);
        if (engine == null) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        // The height hint is a suggestion, not a command: clamped so one
        // widget can neither collapse to nothing nor eat the whole chat.
        final height = (widget.definition.heightHint ?? 320).clamp(
          120.0,
          560.0,
        );
        // Issue #457 AC4: the inner viewport SCROLLS — a widget taller
        // than the canvas is fully reachable (E1: the scroll wrapper wins
        // over a widget-declared fixed height), never clipped mid-control.
        // The renderer's scroll/list nodes default to shrinkWrap, so the
        // outer scroll never fights them.
        Widget sizedViewport(Widget child) => widget.fillAvailable
            ? SizedBox.expand(child: child)
            : SizedBox(height: height, child: child);
        return sizedViewport(
          ViewportReporter(
            onSize: (size) => engine.dispatchHostEvent('viewport', {
              'width': size.width,
              'height': size.height,
            }),
            // Reports the VISIBLE viewport (the engine relayouts to it);
            // the content inside is free to be taller and scroll.
            child: SingleChildScrollView(
              controller: _scroll,
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
                    onScene3dTap: (sceneId, payload) => engine
                        .dispatchHostEvent('scene3d.tap:$sceneId', payload),
                    onEvent: (actionId, payload) =>
                        unawaited(engine.callEvent(actionId, payload)),
                  );
                  Widget body;
                  try {
                    body = renderer.build(tree, context);
                  } on Object catch (error) {
                    // A tree the renderer cannot draw (replayed E6
                    // definition, new renderer against old node kinds) —
                    // error tile, never a crash.
                    return _errorTile(context, '$error');
                  }
                  // Issue #692 C: the runtime overflow backstop — content
                  // painting wider than the viewport reports to the
                  // service, which notes the agent (one-shot per widget).
                  return WidgetOverflowWatch(
                    onOverflow: (overflowPx, viewportWidth) =>
                        widget.service.noteViewportOverflow(
                          widget.definition,
                          overflowPx,
                          viewportWidth,
                        ),
                    child: body,
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _errorTile(BuildContext context, String error) {
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
                  onPressed: () => unawaited(
                    widget.service.retryBoot(
                      widget.definition,
                      locale: Localizations.localeOf(context).languageCode,
                      theme: jsThemeMap(context),
                    ),
                  ),
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
}

/// The ⋮ overflow menu of the dynamic-widget surfaces (issue #378): one
/// visible affordance carrying the secondary actions. Order is most-used
/// first; "Save as app" stays the highlighted default (AC3), the new
/// ephemeral "Open as app" never persists anything (AC2), and a failed
/// boot disables Open with the reason (E1). Shared by the transcript tile
/// title bar and the ✦ list sheet rows so every surface exposing the tile
/// also exposes the menu (AC4).
PopupMenuButton<String> dynamicWidgetMenuButton({
  required BuildContext context,
  required DynamicMessagesService service,
  required DynamicMessageDefinition definition,
  Future<void> Function(DynamicMessageDefinition definition)? onSaveAsApp,
}) {
  final l10n = context.l10n;
  // E1 (issue #378): the degraded state the user SEES is the error tile —
  // a boot failure cached for this widget. Open cannot work from it; Save
  // still can (it persists the definition as-is).
  final bootBroken = service.bootErrorFor(definition.id) != null;
  return PopupMenuButton<String>(
    tooltip: l10n.dynamicTileMenu,
    initialValue: 'save',
    icon: const Icon(Icons.more_vert, size: 22),
    onSelected: (action) => switch (action) {
      'save' when onSaveAsApp != null => unawaited(onSaveAsApp(definition)),
      'open' => unawaited(
        pushEphemeralDynamicApp(context, service, definition),
      ),
      'permissions' => unawaited(
        editDynamicWidgetPermissions(context, service, definition),
      ),
      _ => {},
    },
    itemBuilder: (_) => [
      // Issue #457 AC3: never silently disabled — an unwired graduation
      // hides the row instead of greying it out.
      if (onSaveAsApp != null)
        PopupMenuItem(
          value: 'save',
          child: _menuRow(
            context,
            Icons.archive_outlined,
            l10n.dynamicTileSaveAsApp,
          ),
        ),
      PopupMenuItem(
        value: 'open',
        enabled: !bootBroken,
        child: _menuRow(
          context,
          Icons.open_in_new,
          l10n.dynamicTileOpenAsApp,
          enabled: !bootBroken,
          subtitle: bootBroken ? l10n.dynamicTileOpenUnavailable : null,
        ),
      ),
      PopupMenuItem(
        value: 'permissions',
        child: _menuRow(
          context,
          Icons.shield_outlined,
          l10n.dynamicTilePermissions,
        ),
      ),
    ],
  );
}

Widget _menuRow(
  BuildContext context,
  IconData icon,
  String label, {
  bool enabled = true,
  String? subtitle,
}) {
  final color = enabled ? null : Theme.of(context).disabledColor;
  return Row(
    children: [
      Icon(icon, size: 20, color: color),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: color),
            ),
            if (subtitle != null)
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

/// Opens [definition] full-screen ephemerally (issue #378 AC2): the view
/// renders the SAME engine instance the transcript tile runs (booted on
/// demand through the session's service), with no `apps/<id>` write, no
/// launcher-grid registration, and no session binding. Popping the route
/// discards the view — widget state lives in the engine runtime, which
/// stays owned by the session's [DynamicMessagesService] exactly as
/// before the open, so nothing is left behind to leak.
Future<void> pushEphemeralDynamicApp(
  BuildContext context,
  DynamicMessagesService service,
  DynamicMessageDefinition definition,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  await navigator.push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'ephemeral-dynamic-app'),
      builder: (_) =>
          EphemeralDynamicAppView(service: service, definition: definition),
    ),
  );
}

/// The ephemeral full-screen view: an app bar (title + close) over the
/// shared [DynamicWidgetCanvas]. Deliberately minimal — no chat bar, no
/// persistence, E4 relayout is the engine's normal viewport reporting.
class EphemeralDynamicAppView extends StatelessWidget {
  const EphemeralDynamicAppView({
    super.key,
    required this.service,
    required this.definition,
  });

  final DynamicMessagesService service;
  final DynamicMessageDefinition definition;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: const ValueKey('ephemeral-dynamic-app'),
      child: Scaffold(
        appBar: AppBar(title: Text(definition.title)),
        body: SafeArea(
          // Issue #457 AC4: the full-screen runtime fills the screen and
          // scrolls its content — no fixed hint box, no clipping.
          child: DynamicWidgetCanvas(
            service: service,
            definition: definition,
            fillAvailable: true,
          ),
        ),
      ),
    );
  }
}

/// The app permission dialog for a dynamic widget, identical to an
/// installed app's: grants persist into `apps_permissions.json` and apply
/// on an engine restart (fresh boot — the same rule as the app view).
/// Shared by the tile menu and the ✦ list sheet (issue #378 AC4).
Future<void> editDynamicWidgetPermissions(
  BuildContext context,
  DynamicMessagesService service,
  DynamicMessageDefinition definition,
) async {
  final store = await AppPermissionsStore.load(service.env);
  if (!context.mounted) return;
  final changed = await showDialog<bool>(
    context: context,
    builder: (context) => AppPermissionsDialog(
      app: service.appInfoFor(definition),
      env: service.env,
      store: store,
    ),
  );
  if (changed != true || !context.mounted) return;
  await service.restartEngine(
    definition,
    locale: Localizations.localeOf(context).languageCode,
    theme: jsThemeMap(context),
  );
}

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
