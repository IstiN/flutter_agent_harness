// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';

import 'package:fa/gemma/gemma_service.dart';
import 'package:fa/gemma/gemma_types.dart';
import 'package:fa/ui/widgets/model_cache_section.dart';

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
  late final ModelCacheSectionController _controller =
      ModelCacheSectionController(
        isAvailable: () => _engine.isAvailable,
        scan: _scan,
        scanTimeout: const Duration(seconds: 10),
        scanErrorText: (context, error) =>
            context.l10n.gemmaCacheScanError(error.toString()),
        setState: setState,
        mounted: () => mounted,
      );

  @override
  void initState() {
    super.initState();
    unawaited(_controller.refresh());
  }

  /// Maps the raw repository entries to display rows: one per preset
  /// (installed or not), then one per orphan — an entry no preset installs
  /// under on this platform (the stale mobile-named file on web is the
  /// motivating case).
  Future<List<ModelCacheRow>> _scan() async {
    final installed = await _engine.installedModels();
    if (installed.isEmpty) return const [];
    final rows = <ModelCacheRow>[];
    for (final preset in gemmaModelPresets) {
      final filename = preset.filenameFor(isWeb: _isWeb);
      final sizeLabel = preset.sizeLabelFor(isWeb: _isWeb);
      GemmaInstalledModel? match;
      for (final model in installed) {
        if (model.filename == filename) match = model;
      }
      final bytes = match?.sizeBytes;
      final sizeText = bytes != null ? formatCacheBytes(bytes) : sizeLabel;
      rows.add(
        ModelCacheRow(
          title: preset.displayName,
          subtitle: (context) => match == null
              ? 'Not downloaded · $sizeLabel'
              : bytes != null
              ? '$sizeLabel · ${formatCacheBytes(bytes)} cached'
              : '$sizeLabel · installed',
          confirmContent: (dialogContext) => dialogContext.l10n
              .gemmaCacheDeleteWeights(sizeText, _storageFrom(dialogContext)),
          delete: () => _engine.uninstall(filename),
          wasLoaded: () => _engine.loadedModelId == preset.id,
          deletable: match != null,
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
          ? formatCacheBytes(model.sizeBytes!)
          : 'unknown size';
      rows.add(
        ModelCacheRow(
          title: model.filename,
          subtitle: (context) => isStaleMobileBuild
              ? 'Leftover mobile build — not used on web · $size'
              : 'Unrecognized model file · $size',
          confirmContent: (dialogContext) => dialogContext.l10n
              .gemmaCacheDeleteOrphan(size, _storageFrom(dialogContext)),
          delete: () => _engine.uninstall(model.filename),
          wasLoaded: () => false,
        ),
      );
    }
    return rows;
  }

  String _storageFrom(BuildContext context) => _isWeb
      ? context.l10n.gemmaStorageFromBrowser
      : context.l10n.gemmaStorageFromDevice;

  String _storageIn(BuildContext context) => _isWeb
      ? context.l10n.gemmaStorageInBrowser
      : context.l10n.gemmaStorageOnDevice;

  @override
  Widget build(BuildContext context) {
    return buildModelCacheSection(
      context,
      unavailableNote: context.l10n.gemmaCacheMobileOnly,
      title: context.l10n.gemmaCacheTitle,
      subtitle: context.l10n.gemmaCacheSubtitle(_storageIn(context)),
      controller: _controller,
    );
  }
}
