// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/catalog_service.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/app_log.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
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
    this.appsStore,
    this.catalogService,
    this.httpClient,
  });

  final ExecutionEnv env;

  /// Injectable store; defaults to one over [env].
  final AppsStore? appsStore;

  /// Injectable service; defaults to one over [env] and [httpClient].
  final CatalogService? catalogService;
  final http.Client? httpClient;

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

  /// Ids installed during this session (button → Installed ✓).
  final Set<String> _freshlyInstalled = {};

  @override
  void initState() {
    super.initState();
    _appsStore = widget.appsStore ?? AppsStore(widget.env);
    _catalog =
        widget.catalogService ??
        CatalogService(widget.env, httpClient: widget.httpClient);
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
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

  Future<void> _install(CatalogEntry entry) async {
    if (_installing.contains(entry.id)) return;
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
      if (mounted) {
        setState(() {
          _installing.remove(entry.id);
          _freshlyInstalled.add(entry.id);
        });
      }
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
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text('Install failed: $error')));
      }
    }
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
              title: const Text(
                'Offline — showing the last known catalog.',
                style: TextStyle(fontSize: 13),
              ),
              trailing: TextButton(
                onPressed: _reload,
                child: const Text('Retry'),
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
                fresh: _freshlyInstalled.contains(entry.id),
                onInstall: () => _install(entry),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// One catalog row: avatar, name/version/description, permission chips and
/// the install button (spinner while downloading+writing).
class _CatalogTile extends StatelessWidget {
  const _CatalogTile({
    required this.entry,
    required this.busy,
    required this.fresh,
    required this.onInstall,
  });

  final CatalogEntry entry;
  final bool busy;
  final bool fresh;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chips = <String>[
      for (final tag in entry.tags.take(2)) tag,
      if (entry.network) 'network',
      if (entry.allowedCommands.isNotEmpty) 'commands',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 20,
            child: Text(entry.name.isEmpty ? '?' : entry.name.characters.first),
          ),
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
          FilledButton.tonal(
            onPressed: busy ? null : onInstall,
            child: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(fresh ? 'Installed ✓' : 'Install'),
          ),
        ],
      ),
    );
  }
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
              'Could not load the widgets catalog.\n$error',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
