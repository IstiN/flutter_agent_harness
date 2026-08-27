// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/catalog_service.dart';
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
        return _list(arguments, action == 'search', service);
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
) async {
  try {
    final result = await service.fetchCatalog();
    var entries = result.entries;
    if (isSearch) {
      final query = (arguments['query'] ?? '').toString().trim().toLowerCase();
      if (query.isEmpty) {
        return ToolExecutionResult.text('Provide a "query" for search.');
      }
      bool matches(CatalogEntry e) =>
          e.id.contains(query) ||
          e.name.toLowerCase().contains(query) ||
          e.description.toLowerCase().contains(query) ||
          e.tags.any((tag) => tag.contains(query));
      entries = entries.where(matches).toList();
    }
    if (entries.isEmpty) return ToolExecutionResult.text('No widgets found.');
    final suffix = result.stale ? '\n(offline — cached catalog)' : '';
    return ToolExecutionResult.text(
      entries
              .map(
                (e) =>
                    '${e.id} v${e.version}'
                    '${e.description.isEmpty ? '' : ' — ${e.description}'}',
              )
              .join('\n') +
          suffix,
    );
  } on CatalogError catch (error) {
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
  if (action == 'remove') {
    if (id.isEmpty) return ToolExecutionResult.text('Provide a widget "id".');
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
    final files = await service.downloadWidget(entry);
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
