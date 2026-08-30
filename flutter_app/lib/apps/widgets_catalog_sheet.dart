// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/catalog_service.dart';
import 'package:fa/apps/js_app_navigation.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/app_log.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;

/// Bottom sheet over the fa_widgets catalog: browse entries, install
/// widgets into `apps/` through [AppsStore.installWidget] (ownership-aware,
/// `storage.json` untouched), update ones with newer versions.
///
/// The service is built by the caller (it needs the shared env); the sheet
/// owns fetch → render → download → install progress states.
Future<void> showWidgetsCatalogSheet(
  BuildContext context, {
  required ExecutionEnv env,
  FlutterSessionManager? manager,
  AppsStore? appsStore,
  CatalogService? catalogService,
  http.Client? httpClient,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => WidgetsCatalogSheet(
      env: env,
      manager: manager,
      appsStore: appsStore,
      catalogService: catalogService,
      httpClient: httpClient,
    ),
  );
}

/// The widgets catalog browser.
class WidgetsCatalogSheet extends StatefulWidget {
  const WidgetsCatalogSheet({
    super.key,
    required this.env,
    this.manager,
    this.appsStore,
    this.catalogService,
    this.httpClient,
    this.onOpenApp,
  });

  final ExecutionEnv env;

  /// Session manager used to open installed/previewed widgets through the
  /// same [pushJsApp] navigation the launcher uses. Nullable: without it
  /// (or in tests) [onOpenApp] is consulted instead.
  final FlutterSessionManager? manager;

  /// Injectable store; defaults to one over [env].
  final AppsStore? appsStore;

  /// Injectable service; defaults to one over [env] and [httpClient].
  final CatalogService? catalogService;
  final http.Client? httpClient;

  /// Test/host hook invoked instead of the default [pushJsApp] navigation
  /// when a widget is opened from the sheet.
  final Future<void> Function(BuildContext context, JsAppInfo app)? onOpenApp;

  @override
  State<WidgetsCatalogSheet> createState() => _WidgetsCatalogSheetState();
}

class _WidgetsCatalogSheetState extends State<WidgetsCatalogSheet> {
  late final AppsStore _appsStore;
  late final CatalogService _catalog;

  CatalogFetchResult? _result;
  Object? _loadError;
  var _loading = true;

  /// Ids currently installing (button spinner).
  final Set<String> _installing = {};

  /// Installed apps on disk: id → installed version (refreshed on load and
  /// after every install). Drives the Install/Update/Open button states.
  Map<String, String> _installed = {};

  /// Per-entry icon futures (memoized so rebuilds don't refetch).
  final Map<String, Future<String?>> _iconFutures = {};

  @override
  void initState() {
    super.initState();
    _appsStore = widget.appsStore ?? AppsStore(widget.env);
    _catalog =
        widget.catalogService ??
        CatalogService(widget.env, httpClient: widget.httpClient);
    _reload();
  }

  Future<void> _refreshInstalled() async {
    try {
      final apps = await _appsStore.listApps();
      _installed = {for (final app in apps) app.id: app.version};
    } on Object {
      _installed = {};
    }
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    await _refreshInstalled();
    try {
      final result = await _catalog.fetchCatalog();
      if (mounted) {
        setState(() {
          _result = result;
          _loadError = null;
          _loading = false;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _loadError = error;
          _loading = false;
        });
      }
    }
  }

  /// Installs [entry]; returns true on success.
  Future<bool> _install(CatalogEntry entry) async {
    if (_installing.contains(entry.id)) return false;
    setState(() => _installing.add(entry.id));
    AppAnalytics.instance.widgetEvent(
      'install_start',
      params: {'id': entry.id, 'sizeBytes': entry.zipSizeBytes},
    );
    final watch = Stopwatch()..start();
    try {
      final files = await _catalog.downloadWidget(entry);
      await _appsStore.installWidget(
        id: entry.id,
        version: entry.version,
        files: files,
      );
      AppAnalytics.instance.widgetEvent(
        'install_done',
        params: {'id': entry.id, 'durationMs': watch.elapsedMilliseconds},
      );
      await _refreshInstalled();
      if (mounted) setState(() => _installing.remove(entry.id));
      return true;
    } on Object catch (error) {
      AppLog.i('apps', 'widget install failed: ${entry.id} — $error');
      AppAnalytics.instance.widgetEvent(
        'install_fail',
        params: {
          'id': entry.id,
          'durationMs': watch.elapsedMilliseconds,
          'errorClass': error.runtimeType.toString(),
        },
      );
      if (mounted) {
        setState(() => _installing.remove(entry.id));
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(context.l10n.widgetsCatalogInstallFailed('$error')),
          ),
        );
      }
      return false;
    }
  }

  /// Opens the installed widget through the same [pushJsApp] navigation the
  /// launcher uses (or the [WidgetsCatalogSheet.onOpenApp] hook in tests).
  Future<void> _open(CatalogEntry entry) async {
    final apps = await _appsStore.listApps();
    JsAppInfo? app;
    for (final candidate in apps) {
      if (candidate.id == entry.id) app = candidate;
    }
    if (app == null) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Widget is not installed yet.')),
        );
      }
      return;
    }
    AppAnalytics.instance.widgetEvent(
      'open',
      params: {'id': entry.id, 'source': 'catalog'},
    );
    if (!mounted) return;
    final hook = widget.onOpenApp;
    if (hook != null) {
      await hook(context, app);
      return;
    }
    final manager = widget.manager;
    if (manager == null) return;
    await pushJsApp(context, manager: manager, app: app, source: 'catalog');
  }

  /// Try-before-you-decide: install (when missing/outdated) then open
  /// immediately — the macOS/iOS counterpart of the website's Preview.
  Future<void> _preview(CatalogEntry entry) async {
    final installed = _installed[entry.id];
    final needsInstall =
        installed == null || semverNewer(installed, entry.version);
    if (needsInstall) {
      AppAnalytics.instance.widgetEvent(
        'preview_install',
        params: {'id': entry.id},
      );
      final ok = await _install(entry);
      if (!ok) return;
    } else {
      AppAnalytics.instance.widgetEvent('preview', params: {'id': entry.id});
    }
    await _open(entry);
  }

  Future<String?> _loadIcon(CatalogEntry entry) {
    return _iconFutures[entry.id] ??= () async {
      final icon = entry.iconFile;
      if (icon == null || icon.isEmpty) return null;
      try {
        final response = await (widget.httpClient ?? http.Client()).get(
          Uri.parse('${kDefaultWidgetsRawBaseUrl}widgets/${entry.id}/$icon'),
        );
        if (response.statusCode != 200) return null;
        return utf8.decode(response.bodyBytes);
      } on Object {
        return null;
      }
    }();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Column(
        children: [
          // Drag handle + title row, the same chrome the sessions sheet uses.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Widgets catalog',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildBody(theme, scrollController)),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme, ScrollController scrollController) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return _ErrorView(error: _loadError!, onRetry: _reload);
    }
    final result = _result!;
    if (result.entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'The catalog is empty right now.',
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }
    return Column(
      children: [
        if (result.stale)
          Material(
            color: theme.colorScheme.errorContainer.withValues(alpha: 0.25),
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.cloud_off, size: 20),
              title: Text(
                context.l10n.widgetsCatalogOffline,
                style: const TextStyle(fontSize: 13),
              ),
              trailing: TextButton(
                onPressed: _reload,
                child: Text(context.l10n.widgetsCatalogRetry),
              ),
            ),
          ),
        Expanded(
          child: ListView.builder(
            controller: scrollController,
            itemCount: result.entries.length,
            itemBuilder: (context, index) {
              final entry = result.entries[index];
              return _CatalogTile(
                entry: entry,
                busy: _installing.contains(entry.id),
                installedVersion: _installed[entry.id],
                iconFuture: _loadIcon(entry),
                onInstall: () => _install(entry),
                onOpen: () => _open(entry),
                onPreview: () => _preview(entry),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// One catalog row: icon, name/version/description, permission chips and
/// the action buttons — Preview (install-if-needed + open) plus the state
/// button Install / Update / Open (spinner while downloading+writing).
class _CatalogTile extends StatelessWidget {
  const _CatalogTile({
    required this.entry,
    required this.busy,
    required this.installedVersion,
    required this.iconFuture,
    required this.onInstall,
    required this.onOpen,
    required this.onPreview,
  });

  final CatalogEntry entry;
  final bool busy;

  /// Version installed on disk; null when the widget is not installed.
  final String? installedVersion;
  final Future<String?> iconFuture;
  final VoidCallback onInstall;
  final VoidCallback onOpen;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chips = <String>[
      for (final tag in entry.tags.take(2)) tag,
      if (entry.network) 'network',
      if (entry.allowedCommands.isNotEmpty) 'commands',
    ];
    final hasUpdate =
        installedVersion != null &&
        semverNewer(installedVersion!, entry.version);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CatalogIcon(entry: entry, iconFuture: iconFuture),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${entry.name}  ·  v${entry.version}',
                  style: theme.textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
                if (entry.description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      entry.description,
                      style: theme.textTheme.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (chips.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 6,
                      children: [
                        for (final chip in chips)
                          Chip(
                            label: Text(
                              chip,
                              style: const TextStyle(fontSize: 11),
                            ),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FilledButton.tonal(
                onPressed: busy
                    ? null
                    : (installedVersion == null || hasUpdate)
                    ? onInstall
                    : onOpen,
                child: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        installedVersion == null
                            ? 'Install'
                            : hasUpdate
                            ? 'Update'
                            : 'Open',
                      ),
              ),
              TextButton.icon(
                onPressed: busy ? null : onPreview,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Preview'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The tile's leading icon: the widget's SVG from the fa_widgets raw mirror
/// when the manifest declares one; the first name letter as the fallback
/// (same look the tile had before icons loaded).
class _CatalogIcon extends StatelessWidget {
  const _CatalogIcon({required this.entry, required this.iconFuture});

  final CatalogEntry entry;
  final Future<String?> iconFuture;

  @override
  Widget build(BuildContext context) {
    if (entry.iconFile == null || entry.iconFile!.isEmpty) {
      return _fallback();
    }
    return FutureBuilder<String?>(
      future: iconFuture,
      builder: (context, snapshot) {
        final markup = snapshot.data;
        if (markup == null || markup.trim().isEmpty) return _fallback();
        return SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: SizedBox(
              width: 26,
              height: 26,
              child: SvgPicture.string(markup, fit: BoxFit.contain),
            ),
          ),
        );
      },
    );
  }

  Widget _fallback() => CircleAvatar(
    radius: 20,
    child: Text(entry.name.isEmpty ? '?' : entry.name.characters.first),
  );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off),
            const SizedBox(height: 8),
            Text(
              context.l10n.widgetsCatalogLoadFailed(error.toString()),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: onRetry,
              child: Text(context.l10n.widgetsCatalogRetry),
            ),
          ],
        ),
      ),
    );
  }
}
