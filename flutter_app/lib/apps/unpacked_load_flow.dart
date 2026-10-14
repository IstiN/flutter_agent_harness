// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/unpacked_loader.dart';
import 'package:fa/apps/widget_payload_validator.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/app_log.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/folder_picker.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

/// The "Load unpacked" flow (gh-1616 AC1): pick a local `apps/<id>/`
/// folder → validate with the shared validator → confirm (declared
/// capabilities + replace) → store into the env → refresh the grid.
///
/// Every rejection is a NAMED error dialog (field + path from the shared
/// validator — never a raw engine string, AC2); replacing an existing id
/// requires an explicit confirmation naming the old install (AC4/E3); a
/// cancelled or vanished pick is an honest no-op (E1). The load
/// confirmation is the user grant for the widget's declared capability
/// surface — the network line is the exfiltration gate (E2).
Future<void> loadUnpackedWidget(
  BuildContext context, {
  required FlutterSessionManager manager,
  AppsStore? appsStore,
  FolderPicker? picker,
  UnpackedWidgetLoader? loader,
}) async {
  final folderPicker = picker ?? createFolderPicker();
  if (folderPicker == null) return; // host cannot pick folders — no-op
  final store = loader?.appsStore ?? appsStore ?? AppsStore(manager.env);
  final widgetLoader =
      loader ?? UnpackedWidgetLoader(env: manager.env, appsStore: store);

  // Pick. Empty = the user cancelled (or the folder vanished before the
  // read — E1): an honest no-op, no error dialog over nothing.
  final List<UnpackedPickedFile> picked;
  try {
    picked = await folderPicker.pickFolder();
  } on Object catch (error) {
    AppLog.i('apps', 'unpacked pick failed: $error');
    if (!context.mounted) return;
    showFahErrorSnack(context, context.l10n.unpackedLoadFailed('$error'));
    return;
  }
  if (picked.isEmpty || !context.mounted) return;

  // Validate (no writes yet).
  final inspection = await widgetLoader.inspect({
    for (final file in picked) file.name: file.bytes,
  });
  if (!context.mounted) return;
  if (!inspection.isValid) {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) =>
          UnpackedLoadIssuesDialog(issues: inspection.errors),
    );
    return;
  }

  // Replace check (AC4/E3): ANY app already occupying the id needs an
  // explicit confirm — including agent-created apps with no install
  // record (their code would be overwritten without the recorded hashes
  // protecting anything), so the warning keys off existence, not off the
  // install record. The unknown source is labeled honestly (see the
  // `agentCreatedSource` sentinel) instead of reading as a fresh load.
  final existing = await store.listApps();
  if (!context.mounted) return;
  final replaced = existing.where((app) => app.id == inspection.id).toList();
  final existingApp = replaced.isEmpty ? null : replaced.first;

  // Capability + replace confirmation (the user grant).
  final l10n = context.l10n;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => UnpackedLoadConfirmDialog(
      id: inspection.id!,
      name: inspection.name ?? inspection.id!,
      version: inspection.version,
      network: inspection.network,
      allowedCommands: inspection.allowedCommands,
      existingSource: existingApp == null
          ? null
          : (existingApp.installSource ??
                UnpackedWidgetLoader.agentCreatedSource),
      existingVersion: existingApp?.version,
    ),
  );
  if (confirmed != true || !context.mounted) return;

  try {
    await widgetLoader.install(inspection);
  } on Object catch (error) {
    AppLog.i('apps', 'unpacked install failed: $error');
    if (!context.mounted) return;
    showFahErrorSnack(context, l10n.unpackedLoadFailed('$error'));
    return;
  }
  // UI-side writes do not bump fsRevision themselves — the grid (and any
  // panel) reloads on this (the catalog sheet's same contract).
  manager.active?.service.fsRevision.value++;
  if (!context.mounted) return;
  showFahSnack(
    context,
    l10n.unpackedLoadDone(inspection.name ?? inspection.id!),
  );
}

/// The named-issues dialog (AC2): the shared validator's verbatim errors,
/// selectable so the user can paste them to Fa.
class UnpackedLoadIssuesDialog extends StatelessWidget {
  const UnpackedLoadIssuesDialog({super.key, required this.issues});

  final List<WidgetPayloadError> issues;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      icon: const Icon(Icons.folder_off_outlined),
      title: Text(l10n.unpackedLoadErrorTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final issue in issues)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SelectableText(
                    issue.message,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).okButtonLabel),
        ),
      ],
    );
  }
}

/// The load confirmation: WHO is loading (icon, name, version, id), WHAT
/// it declares (network / commands — the exfiltration gate, E2), and —
/// when the id already exists — the explicit replace warning (AC4/E3).
class UnpackedLoadConfirmDialog extends StatelessWidget {
  const UnpackedLoadConfirmDialog({
    super.key,
    required this.id,
    required this.name,
    this.version,
    this.network = false,
    this.allowedCommands = const [],
    this.existingSource,
    this.existingVersion,
  });

  final String id;
  final String name;
  final String? version;
  final bool network;
  final List<String> allowedCommands;

  /// The existing install this load replaces: its source
  /// (`catalog` | `unpacked`), the [UnpackedWidgetLoader.agentCreatedSource]
  /// sentinel for an app with no install record (agent-created), or null
  /// when the id is fresh.
  final String? existingSource;
  final String? existingVersion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final replaces = existingSource != null;
    final sourceLabel = switch (existingSource) {
      UnpackedWidgetLoader.origin => l10n.unpackedSourceUnpacked,
      UnpackedWidgetLoader.agentCreatedSource => l10n.unpackedSourceAgent,
      _ => l10n.unpackedSourceCatalog,
    };
    return AlertDialog(
      icon: const Icon(Icons.folder_open),
      title: Text(l10n.unpackedLoadTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                l10n.unpackedLoadIdLine(id),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              if (replaces) ...[
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_outlined,
                      size: 18,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.unpackedLoadReplaceNote(
                          sourceLabel,
                          existingVersion ?? '',
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (network || allowedCommands.isNotEmpty) ...[
                const SizedBox(height: 12),
                if (network)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.wifi, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.unpackedLoadNetworkNote,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                if (allowedCommands.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.terminal, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.unpackedLoadCommandsNote(
                            allowedCommands.join(', '),
                          ),
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(
            replaces
                ? l10n.unpackedLoadReplaceConfirm
                : l10n.unpackedLoadConfirm,
          ),
        ),
      ],
    );
  }
}
