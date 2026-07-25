// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';

import 'package:fa/transformers_js/transformers_js_service.dart';
import 'package:fa/transformers_js/transformers_js_types.dart';
import 'package:fa/ui/widgets/model_cache_section.dart';

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
  late final ModelCacheSectionController _controller =
      ModelCacheSectionController(
        isAvailable: () => _engine.isAvailable,
        scan: _scan,
        setState: setState,
        mounted: () => mounted,
      );

  @override
  void initState() {
    super.initState();
    unawaited(_controller.refresh());
  }

  Future<List<ModelCacheRow>> _scan() async {
    final found = <ModelCacheRow>[];
    for (final preset in transformersJsModelPresets) {
      final info = await _engine.modelCacheInfo(preset.id);
      if (info != null && info.cached) {
        found.add(
          ModelCacheRow(
            title: preset.displayName,
            subtitle: (context) => info.bytes != null
                ? context.l10n.cacheEntryCached(
                    formatCacheBytes(info.bytes!),
                    preset.sizeLabel,
                  )
                : preset.sizeLabel,
            confirmContent: (dialogContext) =>
                dialogContext.l10n.cacheDeleteWeightsBrowser(preset.sizeLabel),
            delete: () => _engine.deleteCachedModel(preset.id),
            wasLoaded: () => _engine.loadedModelId == preset.id,
          ),
        );
      }
    }
    return found;
  }

  @override
  Widget build(BuildContext context) {
    return buildModelCacheSection(
      context,
      unavailableNote: context.l10n.tjsCacheWebOnly,
      title: context.l10n.tjsCacheTitle,
      subtitle: context.l10n.cacheBrowserSubtitle,
      controller: _controller,
    );
  }
}
