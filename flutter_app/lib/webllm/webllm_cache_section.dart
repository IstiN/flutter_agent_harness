// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';

import 'webllm_service.dart';
import 'webllm_types.dart';

/// The "Downloaded models" settings section for the on-device (WebLLM)
/// provider: lists the models whose weights sit in the browser's
/// CacheStorage, each with a delete action that frees the space.
///
/// Web only — on other platforms the section collapses to a one-line note.
/// Deleting the currently loaded model resets the engine (see
/// [WebLlmEngineApi.deleteCachedModel]), so the next use re-downloads it.
class WebLlmCacheSection extends StatefulWidget {
  const WebLlmCacheSection({super.key, this.engine});

  /// Engine override for tests; defaults to the platform singleton.
  final WebLlmEngineApi? engine;

  @override
  State<WebLlmCacheSection> createState() => _WebLlmCacheSectionState();
}

class _WebLlmCacheSectionState extends State<WebLlmCacheSection> {
  late final WebLlmEngineApi _engine = widget.engine ?? createWebLlmService();

  /// Cached models from the last scan; `null` while the first scan runs.
  List<({WebLlmModelPreset preset, WebLlmCacheInfo info})>? _cached;

  bool _busy = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (!_engine.isAvailable) return;
    final found = <({WebLlmModelPreset preset, WebLlmCacheInfo info})>[];
    for (final preset in webLlmModelPresets) {
      final info = await _engine.modelCacheInfo(preset.id);
      if (info != null && info.cached) {
        found.add((preset: preset, info: info));
      }
    }
    if (mounted) {
      setState(() {
        _cached = found;
        _busy = false;
      });
    }
  }

  Future<void> _delete(WebLlmModelPreset preset) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.cacheDeleteTitle(preset.displayName)),
        content: Text(
          dialogContext.l10n.cacheDeleteWeightsBrowser(preset.sizeLabel),
        ),
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
      _busy = true;
      _notice = null;
    });
    try {
      final wasLoaded = _engine.loadedModelId == preset.id;
      await _engine.deleteCachedModel(preset.id);
      _notice = wasLoaded
          ? l10n.cacheNoticeLoadedModel(preset.displayName)
          : l10n.cacheNoticeDeleted(preset.displayName);
    } on Object catch (e) {
      _notice = l10n.cacheNoticeDeleteFailed(e.toString(), preset.displayName);
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_engine.isAvailable) {
      return Text(
        context.l10n.webllmCacheManagedByOs,
        style: theme.textTheme.bodySmall,
      );
    }
    final cached = _cached;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(context.l10n.webllmCacheTitle, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          context.l10n.cacheBrowserSubtitle,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (cached == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (cached.isEmpty)
          Text(context.l10n.cacheNoModels, style: theme.textTheme.bodySmall)
        else
          for (final entry in cached)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(entry.preset.displayName),
              subtitle: Text(
                entry.info.bytes != null
                    ? context.l10n.cacheEntryCached(
                        _formatBytes(entry.info.bytes!),
                        entry.preset.sizeLabel,
                      )
                    : entry.preset.sizeLabel,
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: context.l10n.cacheDeleteTooltip(
                  entry.preset.displayName,
                ),
                onPressed: _busy ? null : () => _delete(entry.preset),
              ),
            ),
        if (_notice != null) ...[
          const SizedBox(height: 4),
          Text(_notice!, style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }
}

/// Human-readable byte count for cached-weights sizes (`1.2 GB`, `750 MB`).
String _formatBytes(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '${bytes ~/ (1 << 20)} MB';
  if (bytes >= 1 << 10) return '${bytes ~/ (1 << 10)} KB';
  return '$bytes B';
}
