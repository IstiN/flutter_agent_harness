// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/catalog_service.dart';
import 'package:fa/services/app_log.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Name of the agent tool wrapping the widgets catalog.
const appsCatalogToolName = 'apps_catalog';

/// Where `get-source` unpacks canonical widget sources for the agent to
/// read (never the live `apps/` copy, which may be user-modified).
const widgetSourcesDir = '.fah/widget-sources';

/// Creates the `apps_catalog` tool: lets the agent search the widgets
/// catalog, install/remove widgets into the shared `apps/` workspace, and
/// — before AUTHORING a new widget — fetch canonical example sources into
/// the project so it can study real, reference code instead of guessing
/// from a possibly-customized installed copy.
///
/// `list`/`search` are read tier; the mutating actions (`install`,
/// `remove`, `get-source` — it writes into the project) return a guidance
/// line telling the agent to re-invoke through the write-tier tool when
/// the approval mode requires it (see [appsCatalogWriteTool] twin).
AgentTool appsCatalogTool({
  required ExecutionEnv env,
  CatalogService? catalog,
  AppsStore? apps,
}) {
  final service = catalog ?? CatalogService(env);
  final store = apps ?? AppsStore(env);

  Future<ToolExecutionResult> execute(
    Map<String, dynamic> arguments,
    CancelToken? cancelToken,
    ToolUpdateCallback? onUpdate,
  ) async {
    final action = (arguments['action'] ?? 'list').toString().trim();
    switch (action) {
      case 'list':
      case 'search':
        return _list(arguments, action == 'search', service, store);
      case 'get-source':
      case 'install':
      case 'remove':
        return _mutate(arguments, action, service, store, env);
      default:
        return ToolExecutionResult.text(
          "Unknown action '$action'. Use list|search|get-source|install|remove.",
        );
    }
  }

  return AgentTool(
    name: appsCatalogToolName,
    label: appsCatalogToolName,
    tier: ApprovalTier.read,
    description:
        'Browse and manage the Fa widgets catalog. Actions: "list" (all '
        'widgets), "search" (keyword in id/name/description/tags), '
        '"get-source" (unpack reference sources into $widgetSourcesDir/<id>/ '
        '— DO THIS before writing a new widget: installed copies may be '
        'user-modified), "install"/"remove" (manage widgets in apps/). '
        'Returns concise text lists.',
    parameters: const {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['list', 'search', 'get-source', 'install', 'remove'],
          'description': 'What to do (default: list).',
        },
        'query': {
          'type': 'string',
          'description': 'Search keyword for the "search" action.',
        },
        'id': {
          'type': 'string',
          'description': 'Widget id for get-source/install/remove.',
        },
      },
      'required': [],
    },
    execute: execute,
  );
}

/// Write-tier twin of [appsCatalogTool]: same surface, gated as a write so
/// install/remove/get-source prompt under always-ask/write approval modes.
AgentTool appsCatalogWriteTool({
  required ExecutionEnv env,
  CatalogService? catalog,
  AppsStore? apps,
}) {
  final readTool = appsCatalogTool(env: env, catalog: catalog, apps: apps);
  return AgentTool(
    name: '${appsCatalogToolName}_write',
    label: '${appsCatalogToolName}_write',
    tier: ApprovalTier.write,
    description: readTool.description,
    parameters: readTool.parameters,
    execute: readTool.execute,
  );
}

Future<ToolExecutionResult> _list(
  Map<String, dynamic> arguments,
  bool isSearch,
  CatalogService service,
  AppsStore store,
) async {
  final query = (arguments['query'] ?? '').toString().trim().toLowerCase();
  if (isSearch && query.isEmpty) {
    return ToolExecutionResult.text('Provide a "query" for search.');
  }
  bool matches(String id, String name, String description) =>
      !isSearch ||
      id.contains(query) ||
      name.toLowerCase().contains(query) ||
      description.toLowerCase().contains(query);
  final lines = <String>[];
  final localAppById = <String, JsAppInfo>{};
  final localLineByAppId = <String, int>{};
  // The local workspace FIRST (issue #866): apps the agent just wrote
  // under apps/ exist before the remote catalog ever hears of them — a
  // fresh creation must be visible to the agent that wrote it.
  try {
    for (final app in await store.listApps()) {
      if (!matches(app.id, app.name, app.description)) continue;
      localLineByAppId[app.id] = lines.length;
      localAppById[app.id] = app;
      lines.add(
        app.error != null
            ? '${app.id} — BROKEN: ${app.error}'
            : '${app.id} v${app.version}'
                  '${app.description.isEmpty ? '' : ' — ${app.description}'}'
                  ' (installed in apps/)',
      );
    }
  } on Object catch (e) {
    // A store scan failure must not hide the remote catalog — but stay
    // diagnosable (issue #866 review).
    AppLog.i('apps', 'apps_catalog local scan failed: $e');
  }
  final annotated = <String>{};
  try {
    final result = await service.fetchCatalog();
    final entries = result.entries.where((e) {
      if (!matches(e.id, e.name, e.description)) {
        if (!isSearch) return false;
        // Remote search also matches tags (pre-#866 behavior, kept).
        return e.tags.any((tag) => tag.contains(query));
      }
      return true;
    }).toList();
    for (final e in entries) {
      // Same id locally and remotely is ONE widget, not two (issue #866
      // review): the local line wins; a newer remote version is surfaced
      // as an update annotation on it — at most once per id, even if a
      // bad catalog lists the same id twice (issue #866 review r2).
      final localLine = localLineByAppId[e.id];
      if (localLine != null) {
        final local = localAppById[e.id];
        if (local != null &&
            semverNewer(local.version, e.version) &&
            annotated.add(e.id)) {
          lines[localLine] =
              '${lines[localLine]} (update available: v${e.version})';
        }
        continue;
      }
      lines.add(
        '${e.id} v${e.version}'
        '${e.description.isEmpty ? '' : ' — ${e.description}'}',
      );
    }
    if (lines.isEmpty) return ToolExecutionResult.text('No widgets found.');
    final suffix = result.stale ? '\n(offline — cached catalog)' : '';
    return ToolExecutionResult.text(lines.join('\n') + suffix);
  } on CatalogError catch (error) {
    // Remote unavailable: the local listing still answers.
    if (lines.isNotEmpty) return ToolExecutionResult.text(lines.join('\n'));
    return ToolExecutionResult.text('Catalog unavailable: $error');
  }
}

Future<ToolExecutionResult> _mutate(
  Map<String, dynamic> arguments,
  String action,
  CatalogService service,
  AppsStore store,
  ExecutionEnv env,
) async {
  final id = (arguments['id'] ?? '').toString().trim();
  if (id.isEmpty) return ToolExecutionResult.text('Provide a widget "id".');
  if (action == 'remove') {
    final removed = await store.removeWidget(id);
    return ToolExecutionResult.text(
      removed
          ? 'Removed $id (user data in apps/$id/storage.json kept).'
          : 'Nothing catalog-installed under "$id".',
    );
  }

  CatalogEntry? entry;
  try {
    final result = await service.fetchCatalog();
    for (final candidate in result.entries) {
      if (candidate.id == id) {
        entry = candidate;
        break;
      }
    }
  } on CatalogError catch (error) {
    return ToolExecutionResult.text('Catalog unavailable: $error');
  }
  if (entry == null) {
    return ToolExecutionResult.text(
      'Widget "$id" is not in the catalog. Run action "list" first.',
    );
  }

  try {
    final files = await service.downloadWidgetHealing(entry);
    if (action == 'get-source') {
      for (final file in files.entries) {
        await env.writeFile(
          '$widgetSourcesDir/${entry.id}/${file.key}',
          utf8.decode(file.value, allowMalformed: true),
        );
      }
      return ToolExecutionResult.text(
        'Reference sources for ${entry.id} v${entry.version} written to '
        '$widgetSourcesDir/${entry.id}/ (${files.length} files). Read them '
        'with the read tool before authoring a similar widget.',
      );
    }
    await store.installWidget(
      id: entry.id,
      version: entry.version,
      files: files,
    );
    return ToolExecutionResult.text(
      'Installed ${entry.id} v${entry.version} into apps/${entry.id}/.',
    );
  } on CatalogError catch (error) {
    return ToolExecutionResult.text('Failed: $error');
  }
}
