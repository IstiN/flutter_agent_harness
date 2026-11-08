// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/services/agent_service.dart';
import 'package:fa/apps/app_icon.dart';
import 'package:fa/apps/app_load_error.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:fa/ui/widgets/fah_wallpaper.dart';

/// Grid launcher for the JS apps living in the env's `apps/` folder.
///
/// Opened from the sidebar's Apps section; tapping a card pushes a
/// [JsAppView]. The folder is shared with the Fa agent, so apps the agent
/// creates show up here after a refresh.
class AppsGridView extends StatefulWidget {
  const AppsGridView({
    super.key,
    required this.env,
    required this.permissionsStore,
    this.appsStore,
    this.llmHandler,
    this.platformHandler,
    this.onSendToAgent,
    this.fsRevision,
    this.agentService,
    this.resolveAppService,
  });

  final ExecutionEnv env;
  final AppPermissionsStore permissionsStore;
  final AppsStore? appsStore;
  final FaLlmHandler? llmHandler;
  final FaPlatformHandler? platformHandler;
  final Future<AgentService?> Function(FaAppMessage message)? onSendToAgent;
  final ValueNotifier<int>? fsRevision;

  /// The active session's service — forwarded to [JsAppView] so the compact
  /// [FaWorkBar] works for apps opened from the grid too.
  final AgentService? agentService;

  /// Resolves the session bound to an app (`apps/<id>/session.json`) —
  /// apps opened from the grid resume their own session.
  final Future<AgentService?> Function(String appId)? resolveAppService;

  @override
  State<AppsGridView> createState() => _AppsGridViewState();
}

class _AppsGridViewState extends State<AppsGridView> {
  late final AppsStore _store;
  List<JsAppInfo>? _apps;
  Object? _error;

  /// Whether we're on macOS desktop (traffic lights float over the band).
  static bool get _isMacOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void initState() {
    super.initState();
    _store = widget.appsStore ?? AppsStore(widget.env);
    widget.fsRevision?.addListener(_reload);
    unawaited(_reload());
  }

  @override
  void dispose() {
    widget.fsRevision?.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      await _store.seedBundledApps();
      final apps = await _store.listApps();
      if (mounted) {
        setState(() {
          _apps = apps;
          _error = null;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Scaffold(
      // Styleguide chrome: the shell's scaffold tone, the Fa 2.0 wallpaper
      // beneath, and ONE messenger-style band on top — no raw AppBar.
      backgroundColor: colors.bg,
      body: Stack(
        children: [
          const Positioned.fill(child: FahWallpaper()),
          Positioned.fill(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [_buildChrome(context), Expanded(child: _buildBody())],
            ),
          ),
        ],
      ),
    );
  }

  /// The one chrome band: [FaAdaptiveHeader] (title + refresh circle) over
  /// a single hairline — the same vocabulary as the Files panel's header.
  /// Pushed routes sit under the macOS titlebar (fullSizeContentView), so
  /// the band keeps the traffic-light clearance the old AppBar baked in.
  Widget _buildChrome(BuildContext context) {
    final colors = FahColors.of(context);
    final tokens = FaDesignTokens.of(context);
    final glass = tokens.direction == FaVisualDirection.glass;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: glass ? Colors.transparent : colors.panel,
          padding: EdgeInsets.fromLTRB(16, _isMacOS ? 34 : 10, 8, 6),
          child: SizedBox(
            height: 40,
            child: FaAdaptiveHeader(
              title: context.l10n.appsGridTitle,
              titleStyle: TextStyle(
                color: colors.text,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
              actions: [
                FaHeaderAction(
                  key: const ValueKey('appsGridRefresh'),
                  icon: Icons.refresh,
                  label: context.l10n.appsRefreshTooltip,
                  onPressed: _reload,
                  pinned: true,
                ),
              ],
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              actionGap: 8,
              actionBuilder: (context, action, button) =>
                  FaHeaderCircularAction(child: button),
            ),
          ),
        ),
        Divider(height: 1, color: colors.border.withValues(alpha: .55)),
      ],
    );
  }

  Widget _buildBody() {
    final theme = Theme.of(context);
    final error = _error;
    if (error != null) {
      return Center(child: Text(context.l10n.appsLoadError('$error')));
    }
    final apps = _apps;
    if (apps == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (apps.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            context.l10n.appsEmptyState,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge,
          ),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.1,
      ),
      itemCount: apps.length,
      itemBuilder: (context, index) => _AppCard(
        app: apps[index],
        env: widget.env,
        onTap: () => _openApp(apps[index]),
      ),
    );
  }

  Future<void> _openApp(JsAppInfo app) async {
    // Same broken-app guard as every launch surface (issue #866): the
    // card's red line is the short label; the dialog carries the parser
    // detail the user can copy for Fa.
    if (await guardBrokenApp(context, app)) return;
    if (!mounted) return;
    final appService =
        (await widget.resolveAppService?.call(app.id)) ?? widget.agentService;
    await _openAppViewIfMounted(app, appService);
  }

  /// Opens [app] fullscreen after the resolver's await gap — only while
  /// the grid is still mounted (gh-1848 split).
  Future<void> _openAppViewIfMounted(
    JsAppInfo app,
    AgentService? appService,
  ) async {
    if (!mounted) return;
    // Wide screens: push inside the apps panel's nested Navigator and hide
    // the in-app Fa chrome (the main chat is always visible alongside).
    final inPanel = FaChatHost.jsAppNavigatorKey?.currentState != null;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => JsAppView(
          app: app,
          env: widget.env,
          permissionsStore: widget.permissionsStore,
          llmHandler: widget.llmHandler,
          platformHandler: widget.platformHandler,
          onSendToAgent: widget.onSendToAgent,
          fsRevision: widget.fsRevision,
          agentService: appService,
          embeddedInPanel: inPanel,
        ),
      ),
    );
  }
}

class _AppCard extends StatelessWidget {
  const _AppCard({required this.app, required this.env, required this.onTap});

  final JsAppInfo app;
  final ExecutionEnv env;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final colors = FahColors.of(context);
    return FaSurface(
      key: const ValueKey('appsGridCard'),
      color: colors.panelAlt,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppIcon(app: app, env: env, size: 32),
              const Spacer(),
              Text(
                app.displayName(locale),
                style: TextStyle(
                  color: colors.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                // Issue #866: a manifest the agent broke is a visible
                // error state on the card — a localized label here (the
                // raw parser output goes to the tap's copyable dialog,
                // so the pixels stay locale-agnostic).
                app.error != null
                    ? AppLocalizations.of(context).appsManifestErrorLabel
                    : app.displayDescription(locale),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: app.error == null ? colors.dim : colors.error,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
