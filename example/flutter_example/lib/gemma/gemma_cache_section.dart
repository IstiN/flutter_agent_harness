// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'gemma_service.dart';
import 'gemma_types.dart';

/// One row in the Gemma cache section: a preset (installed or not) or a
/// stale repository entry (orphan).
final class _CacheEntry {
  const _CacheEntry({
    required this.filename,
    required this.title,
    required this.subtitle,
    required this.sizeText,
    required this.deletable,
    this.presetId,
    this.orphan = false,
  });

  /// The repository id handed to [GemmaEngineApi.uninstall].
  final String filename;

  /// Row title (preset display name, or the orphan's file name).
  final String title;

  /// Row subtitle (installed state / leftover explanation + size).
  final String subtitle;

  /// Size mentioned in the confirm dialog.
  final String sizeText;

  /// Whether the row has a delete action (installed presets and orphans).
  final bool deletable;

  /// The preset id when this row is one of [gemmaModelPresets] — used to
  /// detect deleting the loaded model; `null` for orphans.
  final String? presetId;

  /// Whether this row is a stale repository entry, not a current preset.
  final bool orphan;
}

/// The "On-device models (Gemma)" settings section: lists each Gemma preset
/// with its installed state and size, plus any stale model files left in
/// the plugin's repository (e.g. a mobile-named build an older app version
/// cached in the browser's OPFS), each installed entry with a delete action
/// that frees the space.
///
/// Works on web and mobile (the plugin's uninstall is platform-uniform); on
/// desktop the section collapses to a one-line note. Deleting the currently
/// loaded model unloads it first (see [GemmaEngineApi.uninstall]), so the
/// next use re-downloads it.
class GemmaCacheSection extends StatefulWidget {
  const GemmaCacheSection({super.key, this.engine, this.isWeb});

  /// Engine override for tests; defaults to the platform singleton.
  final GemmaEngineApi? engine;

  /// Platform override for tests (host tests run with `kIsWeb == false`, so
  /// the web install file names are exercised through this seam).
  final bool? isWeb;

  @override
  State<GemmaCacheSection> createState() => _GemmaCacheSectionState();
}

class _GemmaCacheSectionState extends State<GemmaCacheSection> {
  late final GemmaEngineApi _engine = widget.engine ?? createGemmaService();
  late final bool _isWeb = widget.isWeb ?? kIsWeb;

  /// Repository entries from the last scan; `null` while the first scan
  /// runs.
  List<GemmaInstalledModel>? _installed;

  /// Set when the repository scan itself failed (corrupt store, plugin
  /// unavailable); shown instead of the list.
  Object? _scanError;

  bool _busy = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  /// Upper bound for one repository scan: a hung store (OPFS lock, dead
  /// plugin channel) must not pin the settings dialog on the spinner.
  static const _scanTimeout = Duration(seconds: 10);

  Future<void> _refresh() async {
    if (!_engine.isAvailable) return;
    try {
      final installed = await _engine.installedModels().timeout(_scanTimeout);
      if (mounted) {
        setState(() {
          _installed = installed;
          _scanError = null;
          _busy = false;
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _scanError = e;
          _busy = false;
        });
      }
    }
  }

  /// Maps the raw repository entries to display rows: one per preset
  /// (installed or not), then one per orphan — an entry no preset installs
  /// under on this platform (the stale mobile-named file on web is the
  /// motivating case).
  List<_CacheEntry> _entries(List<GemmaInstalledModel> installed) {
    final entries = <_CacheEntry>[];
    for (final preset in gemmaModelPresets) {
      final filename = preset.filenameFor(isWeb: _isWeb);
      final sizeLabel = preset.sizeLabelFor(isWeb: _isWeb);
      GemmaInstalledModel? match;
      for (final model in installed) {
        if (model.filename == filename) match = model;
      }
      final bytes = match?.sizeBytes;
      entries.add(
        _CacheEntry(
          filename: filename,
          title: preset.displayName,
          subtitle: match == null
              ? 'Not downloaded · $sizeLabel'
              : bytes != null
              ? '$sizeLabel · ${_formatBytes(bytes)} cached'
              : '$sizeLabel · installed',
          sizeText: bytes != null ? _formatBytes(bytes) : sizeLabel,
          deletable: match != null,
          presetId: preset.id,
        ),
      );
    }
    for (final model in installed) {
      final isPreset = gemmaModelPresets.any(
        (preset) => preset.filenameFor(isWeb: _isWeb) == model.filename,
      );
      if (isPreset) continue;
      final isStaleMobileBuild = gemmaModelPresets.any(
        (preset) => preset.filename == model.filename,
      );
      final size = model.sizeBytes != null
          ? _formatBytes(model.sizeBytes!)
          : 'unknown size';
      entries.add(
        _CacheEntry(
          filename: model.filename,
          title: model.filename,
          subtitle: isStaleMobileBuild
              ? 'Leftover mobile build — not used on web · $size'
              : 'Unrecognized model file · $size',
          sizeText: size,
          deletable: true,
          orphan: true,
        ),
      );
    }
    return entries;
  }

  Future<void> _delete(_CacheEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${entry.title}?'),
        content: Text(
          entry.orphan
              ? 'Removes the file (${entry.sizeText}) from '
                    '${_isWeb ? 'the browser storage' : 'the device'}. '
                    'Installed models are not affected.'
              : 'Removes the downloaded weights (${entry.sizeText}) from '
                    '${_isWeb ? 'the browser storage' : 'the device'}. The '
                    'model downloads again the next time you use it.',
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
      final presetId = entry.presetId;
      final wasLoaded = presetId != null && _engine.loadedModelId == presetId;
      await _engine.uninstall(entry.filename);
      _notice = wasLoaded
          ? '${entry.title} was the loaded model — it downloads again on '
                'next use.'
          : 'Deleted ${entry.title}.';
    } on Object catch (e) {
      _notice = 'Failed to delete ${entry.title}: $e';
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_engine.isAvailable) {
      return Text(
        'On-device (Gemma) models are available in the iOS/Android builds '
        'only (on web the transformers.js provider covers on-device Gemma).',
        style: theme.textTheme.bodySmall,
      );
    }
    final installed = _installed;
    final entries = installed == null || installed.isEmpty
        ? null
        : _entries(installed);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('On-device models (Gemma)', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Gemma weights stored ${_isWeb ? 'in your browser' : 'on this '
                    'device'}. Deleting frees space; a model re-downloads on next '
          'use.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (installed == null)
          _scanError != null
              ? Text(
                  'Could not scan the model cache: $_scanError',
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
        else if (entries == null)
          Text('No models downloaded yet.', style: theme.textTheme.bodySmall)
        else
          for (final entry in entries)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(entry.title),
              subtitle: Text(entry.subtitle),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete ${entry.title}',
                onPressed: _busy || !entry.deletable
                    ? null
                    : () => _delete(entry),
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

/// Human-readable byte count for cached-weights sizes (`2.6 GB`, `750 MB`).
String _formatBytes(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '${bytes ~/ (1 << 20)} MB';
  if (bytes >= 1 << 10) return '${bytes ~/ (1 << 10)} KB';
  return '$bytes B';
}
