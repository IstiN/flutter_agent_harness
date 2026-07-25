// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';

import 'package:fa/ui/widgets/model_cache_section.dart';
import 'package:fa/webllm/webllm_service.dart';
import 'package:fa/webllm/webllm_types.dart';

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
    for (final preset in webLlmModelPresets) {
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
      unavailableNote: context.l10n.webllmCacheManagedByOs,
      title: context.l10n.webllmCacheTitle,
      subtitle: context.l10n.cacheBrowserSubtitle,
      controller: _controller,
    );
  }
}
