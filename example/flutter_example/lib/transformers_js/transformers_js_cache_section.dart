// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';

import 'transformers_js_service.dart';
import 'transformers_js_types.dart';

/// The "Downloaded models (transformers.js)" settings section for the
/// on-device transformers.js provider: lists the models whose ONNX weights
/// sit in the browser's CacheStorage, each with a delete action that frees
/// the space.
///
/// Web only — on other platforms the section collapses to a one-line note.
/// Deleting the currently loaded model resets the engine (see
/// [TransformersJsEngineApi.deleteCachedModel]), so the next use
/// re-downloads it.
class TransformersJsCacheSection extends StatefulWidget {
  const TransformersJsCacheSection({super.key, this.engine});

  /// Engine override for tests; defaults to the platform singleton.
  final TransformersJsEngineApi? engine;

  @override
  State<TransformersJsCacheSection> createState() =>
      _TransformersJsCacheSectionState();
}

class _TransformersJsCacheSectionState
    extends State<TransformersJsCacheSection> {
  late final TransformersJsEngineApi _engine =
      widget.engine ?? createTransformersJsService();

  /// Cached models from the last scan; `null` while the first scan runs.
  List<({TransformersJsModelPreset preset, TransformersJsCacheInfo info})>?
  _cached;

  bool _busy = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (!_engine.isAvailable) return;
    final found =
        <({TransformersJsModelPreset preset, TransformersJsCacheInfo info})>[];
    for (final preset in transformersJsModelPresets) {
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

  Future<void> _delete(TransformersJsModelPreset preset) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${preset.displayName}?'),
        content: Text(
          'Removes the downloaded weights (${preset.sizeLabel}) from the '
          'browser cache. The model downloads again the next time you use '
          'it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
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
          ? '${preset.displayName} was the loaded model — it downloads '
                'again on next use.'
          : 'Deleted ${preset.displayName}.';
    } on Object catch (e) {
      _notice = 'Failed to delete ${preset.displayName}: $e';
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_engine.isAvailable) {
      return Text(
        'On-device (transformers.js) models are available in the web build '
        'only.',
        style: theme.textTheme.bodySmall,
      );
    }
    final cached = _cached;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Downloaded models (transformers.js)',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          'On-device model weights cached in your browser. Deleting frees '
          'space; a model re-downloads on next use.',
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
          Text('No models downloaded yet.', style: theme.textTheme.bodySmall)
        else
          for (final entry in cached)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(entry.preset.displayName),
              subtitle: Text(
                entry.info.bytes != null
                    ? '${entry.preset.sizeLabel} · '
                          '${_formatBytes(entry.info.bytes!)} cached'
                    : entry.preset.sizeLabel,
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete ${entry.preset.displayName}',
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

/// Human-readable byte count for cached-weights sizes (`3.2 GB`, `750 MB`).
String _formatBytes(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '${bytes ~/ (1 << 20)} MB';
  if (bytes >= 1 << 10) return '${bytes ~/ (1 << 10)} KB';
  return '$bytes B';
}
