// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import '../agent_service.dart';
import 'app_icon.dart';
import 'apps_store.dart';
import 'js_app_engine.dart';
import 'js_app_view.dart';

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
  final Future<void> Function(FaAppMessage message)? onSendToAgent;
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
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Apps'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _reload,
          ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final error = _error;
    if (error != null) {
      return Center(child: Text('Failed to load apps: $error'));
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
            'No apps yet. Ask Fa to build one —\nit will land in the apps/ folder.',
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
    final appService =
        (await widget.resolveAppService?.call(app.id)) ?? widget.agentService;
    if (!mounted) return;
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
    return Card(
      clipBehavior: Clip.antiAlias,
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
                app.name,
                style: theme.textTheme.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                app.description,
                style: theme.textTheme.bodySmall,
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
