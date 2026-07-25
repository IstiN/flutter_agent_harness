// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';

/// One row in a "downloaded models" cache settings section: a cached model
/// (or a stale store entry) with a delete action.
final class ModelCacheRow {
  const ModelCacheRow({
    required this.title,
    required this.subtitle,
    required this.confirmContent,
    required this.delete,
    required this.wasLoaded,
    this.deletable = true,
  });

  /// Row title (model display name, or the entry's file name).
  final String title;

  /// Row subtitle (installed state / leftover explanation + size), resolved
  /// with the build context so l10n-backed labels follow the locale.
  final String Function(BuildContext context) subtitle;

  /// Confirm-dialog body, resolved with the dialog's context.
  final String Function(BuildContext dialogContext) confirmContent;

  /// Deletes the cached weights behind this row.
  final Future<void> Function() delete;

  /// Whether this row's model is the currently loaded one — the post-delete
  /// notice then mentions the re-download on next use.
  final bool Function() wasLoaded;

  /// Whether the row has a delete action.
  final bool deletable;
}

/// Shared state and behavior behind the engine-specific "downloaded models"
/// settings sections (Gemma, WebLLM, transformers.js): scan the store, list
/// the rows, delete with a confirm dialog, show a notice, rescan.
final class ModelCacheSectionController {
  ModelCacheSectionController({
    required this.isAvailable,
    required this.scan,
    required this.setState,
    required this.mounted,
    this.scanTimeout,
    this.scanErrorText,
  });

  /// Whether the engine's cache store is usable on this platform; when
  /// false the section collapses to a one-line note.
  final bool Function() isAvailable;

  /// Produces the rows to list.
  final Future<List<ModelCacheRow>> Function() scan;

  /// The host `State.setState`, applied to every mutation below.
  final void Function(VoidCallback fn) setState;

  /// The host `State.mounted` getter, checked before touching state after
  /// an await.
  final bool Function() mounted;

  /// Upper bound for one scan: a hung store (OPFS lock, dead plugin
  /// channel) must not pin the settings dialog on the spinner.
  final Duration? scanTimeout;

  /// Renders a scan failure (corrupt store, plugin unavailable) shown
  /// instead of the list; when null, scan errors propagate.
  final String Function(BuildContext context, Object error)? scanErrorText;

  /// Rows from the last scan; `null` while the first scan runs.
  List<ModelCacheRow>? rows;

  /// Set when the scan itself failed; shown instead of the list.
  Object? scanError;

  bool busy = false;
  String? notice;

  Future<void> refresh() async {
    if (!isAvailable()) return;
    try {
      var future = scan();
      final timeout = scanTimeout;
      if (timeout != null) future = future.timeout(timeout);
      final found = await future;
      if (mounted()) {
        setState(() {
          rows = found;
          scanError = null;
          busy = false;
        });
      }
    } on Object catch (e) {
      if (scanErrorText == null) rethrow;
      if (mounted()) {
        setState(() {
          scanError = e;
          busy = false;
        });
      }
    }
  }

  Future<void> deleteRow(BuildContext context, ModelCacheRow row) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.cacheDeleteTitle(row.title)),
        content: Text(row.confirmContent(dialogContext)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(dialogContext.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(dialogContext.l10n.commonDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      busy = true;
      notice = null;
    });
    try {
      final wasLoaded = row.wasLoaded();
      await row.delete();
      notice = wasLoaded
          ? l10n.cacheNoticeLoadedModel(row.title)
          : l10n.cacheNoticeDeleted(row.title);
    } on Object catch (e) {
      notice = l10n.cacheNoticeDeleteFailed(e.toString(), row.title);
    }
    await refresh();
  }
}

/// The shared section layout: title, subtitle, then the scan spinner / scan
/// error / empty note / delete-able rows, and the transient notice.
Widget buildModelCacheSection(
  BuildContext context, {
  required String unavailableNote,
  required String title,
  required String subtitle,
  required ModelCacheSectionController controller,
}) {
  final theme = Theme.of(context);
  if (!controller.isAvailable()) {
    return Text(unavailableNote, style: theme.textTheme.bodySmall);
  }
  final rows = controller.rows;
  final scanError = controller.scanError;
  final scanErrorText = controller.scanErrorText;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(title, style: theme.textTheme.titleSmall),
      const SizedBox(height: 4),
      Text(subtitle, style: theme.textTheme.bodySmall),
      const SizedBox(height: 8),
      if (rows == null)
        scanError != null && scanErrorText != null
            ? Text(
                scanErrorText(context, scanError),
                style: theme.textTheme.bodySmall,
              )
            : const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
      else if (rows.isEmpty)
        Text(context.l10n.cacheNoModels, style: theme.textTheme.bodySmall)
      else
        for (final row in rows)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(row.title),
            subtitle: Text(row.subtitle(context)),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: context.l10n.cacheDeleteTooltip(row.title),
              onPressed: controller.busy || !row.deletable
                  ? null
                  : () => controller.deleteRow(context, row),
            ),
          ),
      if (controller.notice != null) ...[
        const SizedBox(height: 4),
        Text(controller.notice!, style: theme.textTheme.bodySmall),
      ],
    ],
  );
}

/// Human-readable byte count for cached-weights sizes (`2.6 GB`, `750 MB`).
String formatCacheBytes(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '${bytes ~/ (1 << 20)} MB';
  if (bytes >= 1 << 10) return '${bytes ~/ (1 << 10)} KB';
  return '$bytes B';
}
