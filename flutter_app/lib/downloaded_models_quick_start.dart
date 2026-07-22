// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'agent_service.dart';
import 'gemma/gemma_service.dart';
import 'gemma/gemma_types.dart';
import 'transformers_js/transformers_js_service.dart';
import 'transformers_js/transformers_js_types.dart';
import 'webllm/webllm_service.dart';
import 'webllm/webllm_types.dart';

/// Which on-device engine a quick-start row belongs to.
enum _QuickStartKind { webllm, gemma, transformersJs }

/// One row in the quick-start section: a model whose weights are already on
/// this device/browser, ready to load without a download.
final class _QuickStartEntry {
  const _QuickStartEntry({
    required this.kind,
    required this.preset,
    required this.title,
    required this.sizeLabel,
    this.bytes,
  });

  final _QuickStartKind kind;

  /// The model preset (`WebLlmModelPreset` / `GemmaModelPreset` /
  /// `TransformersJsModelPreset`, matched by [kind]).
  final Object preset;

  /// Row title (the preset's display name).
  final String title;

  /// Approximate download size, shown when no exact byte count is known.
  final String sizeLabel;

  /// Exact cached/installed byte count when cheaply known.
  final int? bytes;
}

/// The "Downloaded models" section on the setup screen: one row per
/// on-device model whose weights are already cached/installed here (WebLLM
/// and transformers.js CacheStorage on web, the flutter_gemma repository on
/// mobile), each with a one-tap "Use" action that loads the model (no
/// download, no API key) and connects straight away.
///
/// The section is hidden while the scan runs and when nothing is downloaded
/// — first-run users never see it. The scan only queries cache state; it
/// never loads a model into the (singleton) engines, so the engines stay
/// cold until a "Use" tap warms exactly the picked model (which the later
/// chat stream function then reuses).
class DownloadedModelsQuickStart extends StatefulWidget {
  const DownloadedModelsQuickStart({
    super.key,
    required this.onConnect,
    this.webLlmEngine,
    this.gemmaEngine,
    this.transformersJsEngine,
    this.isWeb,
  });

  /// Called with the assembled [AgentConfig] after the picked model loaded.
  /// Throw to surface an error in the section; return normally on success.
  final Future<void> Function(AgentConfig config) onConnect;

  /// Engine overrides for tests; default to the platform singletons.
  final WebLlmEngineApi? webLlmEngine;
  final GemmaEngineApi? gemmaEngine;
  final TransformersJsEngineApi? transformersJsEngine;

  /// Platform override for tests (the Gemma install file names differ per
  /// platform — the same seam as `GemmaCacheSection.isWeb`).
  final bool? isWeb;

  @override
  State<DownloadedModelsQuickStart> createState() =>
      _DownloadedModelsQuickStartState();
}

class _DownloadedModelsQuickStartState
    extends State<DownloadedModelsQuickStart> {
  late final WebLlmEngineApi _webLlm =
      widget.webLlmEngine ?? createWebLlmService();
  late final GemmaEngineApi _gemma = widget.gemmaEngine ?? createGemmaService();
  late final TransformersJsEngineApi _transformersJs =
      widget.transformersJsEngine ?? createTransformersJsService();
  late final bool _isWeb = widget.isWeb ?? kIsWeb;

  /// Rows from the last scan; `null` while the scan runs (section hidden).
  List<_QuickStartEntry>? _entries;

  /// The manual timer behind [_installedModelsBounded] — cancelled on
  /// dispose so a wedged plugin never leaves a pending timer behind
  /// (`Future.timeout`'s internal timer cannot be cancelled).
  Timer? _gemmaScanTimer;

  bool _busy = false;
  double? _loadFraction;
  String? _loadStatus;
  String? _error;

  /// Upper bound for the Gemma repository scan: a hung store (OPFS lock,
  /// dead plugin channel) must not pin the section (same bound as the Gemma
  /// cache section).
  static const _scanTimeout = Duration(seconds: 10);

  @override
  void initState() {
    super.initState();
    unawaited(_scan());
  }

  @override
  void dispose() {
    _gemmaScanTimer?.cancel();
    super.dispose();
  }

  /// [GemmaEngineApi.installedModels] with the [_scanTimeout] bound, but on
  /// a [Timer] this State owns (and cancels in [dispose]).
  Future<List<GemmaInstalledModel>> _installedModelsBounded(
    GemmaEngineApi engine,
  ) {
    final completer = Completer<List<GemmaInstalledModel>>();
    _gemmaScanTimer = Timer(_scanTimeout, () {
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('Gemma repository scan timed out', _scanTimeout),
        );
      }
    });
    unawaited(
      engine.installedModels().then(
        (models) {
          if (!completer.isCompleted) completer.complete(models);
        },
        onError: (Object error) {
          if (!completer.isCompleted) completer.completeError(error);
        },
      ),
    );
    return completer.future;
  }

  Future<void> _scan() async {
    final entries = <_QuickStartEntry>[];
    if (_webLlm.isAvailable) {
      for (final preset in webLlmModelPresets) {
        final info = await _queryCache(() => _webLlm.modelCacheInfo(preset.id));
        if (info != null && info.cached) {
          entries.add(
            _QuickStartEntry(
              kind: _QuickStartKind.webllm,
              preset: preset,
              title: preset.displayName,
              sizeLabel: preset.sizeLabel,
              bytes: info.bytes,
            ),
          );
        }
      }
    }
    if (_transformersJs.isAvailable) {
      for (final preset in transformersJsModelPresets) {
        final info = await _queryCache(
          () => _transformersJs.modelCacheInfo(preset.id),
        );
        if (info != null && info.cached) {
          entries.add(
            _QuickStartEntry(
              kind: _QuickStartKind.transformersJs,
              preset: preset,
              title: preset.displayName,
              sizeLabel: preset.sizeLabel,
              bytes: info.bytes,
            ),
          );
        }
      }
    }
    if (_gemma.isAvailable) {
      try {
        final installed = await _installedModelsBounded(_gemma);
        for (final preset in gemmaModelPresets) {
          final filename = preset.filenameFor(isWeb: _isWeb);
          GemmaInstalledModel? match;
          for (final model in installed) {
            if (model.filename == filename) match = model;
          }
          if (match != null) {
            entries.add(
              _QuickStartEntry(
                kind: _QuickStartKind.gemma,
                preset: preset,
                title: preset.displayName,
                sizeLabel: preset.sizeLabelFor(isWeb: _isWeb),
                bytes: match.sizeBytes,
              ),
            );
          }
        }
      } on Object {
        // A failed repository scan yields no Gemma rows, not an error — the
        // full connection form below still offers every provider.
      } finally {
        _gemmaScanTimer?.cancel();
      }
    }
    if (mounted) setState(() => _entries = entries);
  }

  /// Cache queries are best effort: a blocked storage API hides the row
  /// rather than breaking the scan (mirrors the cache sections' `null`
  /// handling).
  Future<T?> _queryCache<T>(Future<T?> Function() query) async {
    try {
      return await query();
    } on Object {
      return null;
    }
  }

  Future<void> _use(_QuickStartEntry entry) async {
    setState(() {
      _busy = true;
      _error = null;
      _loadFraction = null;
      _loadStatus = null;
    });
    try {
      final config = await switch (entry.kind) {
        _QuickStartKind.webllm => _loadWebLlm(
          entry.preset as WebLlmModelPreset,
        ),
        _QuickStartKind.gemma => _loadGemma(entry.preset as GemmaModelPreset),
        _QuickStartKind.transformersJs => _loadTransformersJs(
          entry.preset as TransformersJsModelPreset,
        ),
      };
      if (!mounted) return;
      await widget.onConnect(config);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is StateError ? e.message : e.toString());
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _loadFraction = null;
          _loadStatus = null;
        });
      }
    }
  }

  /// Loads a cached WebLLM model (weights already in CacheStorage, so this
  /// pays shader compilation only) and builds its [AgentConfig] — the same
  /// shape the settings form's on-device connect produces.
  Future<AgentConfig> _loadWebLlm(WebLlmModelPreset preset) async {
    final sub = _webLlm.progressEvents.listen(_onWebLlmProgress);
    try {
      await _webLlm.loadModel(preset);
    } finally {
      // Not awaited — see the settings form's connect flow (zone-scheduled
      // cancel futures can stall widget tests).
      unawaited(sub.cancel());
    }
    return AgentConfig(
      providerKind: webLlmProviderKind,
      modelId: preset.id,
      baseUrl: '',
      apiKey: '',
      contextWindow: preset.contextWindow,
      maxTokens: 1024,
    );
  }

  /// Marks an installed Gemma model active and loads it (install skips what
  /// is already on disk — no token, no download) and builds its
  /// [AgentConfig].
  Future<AgentConfig> _loadGemma(GemmaModelPreset preset) async {
    final sub = _gemma.progressEvents.listen(_onGemmaProgress);
    try {
      await _gemma.installModel(preset);
      await _gemma.loadModel(preset);
    } finally {
      unawaited(sub.cancel());
    }
    return AgentConfig(
      providerKind: gemmaProviderKind,
      modelId: preset.id,
      baseUrl: '',
      apiKey: '',
      contextWindow: preset.contextWindow,
      maxTokens: 1024,
    );
  }

  /// Loads a cached transformers.js model (ONNX weights already in
  /// CacheStorage) and builds its [AgentConfig].
  Future<AgentConfig> _loadTransformersJs(
    TransformersJsModelPreset preset,
  ) async {
    final sub = _transformersJs.progressEvents.listen(
      _onTransformersJsProgress,
    );
    try {
      await _transformersJs.loadModel(preset);
    } finally {
      unawaited(sub.cancel());
    }
    return AgentConfig(
      providerKind: transformersJsProviderKind,
      modelId: preset.id,
      baseUrl: '',
      apiKey: '',
      contextWindow: preset.contextWindow,
      maxTokens: 1024,
    );
  }

  void _onWebLlmProgress(WebLlmProgress report) {
    if (!mounted) return;
    setState(() {
      _loadFraction = report.fraction;
      _loadStatus = report.text;
    });
  }

  void _onGemmaProgress(GemmaProgress report) {
    if (!mounted) return;
    setState(() {
      _loadFraction = report.fraction;
      _loadStatus = report.text;
    });
  }

  void _onTransformersJsProgress(TransformersJsProgress report) {
    if (!mounted) return;
    setState(() {
      _loadFraction = report.fraction;
      _loadStatus = report.text;
    });
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    // Hidden while scanning and when nothing is downloaded.
    if (entries == null || entries.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Downloaded models', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Already on this device — one tap, no API key needed.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        for (final entry in entries)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(entry.title),
            subtitle: Text(
              entry.bytes != null
                  ? '${entry.sizeLabel} · ${_formatBytes(entry.bytes!)} cached'
                  : entry.sizeLabel,
            ),
            trailing: FilledButton.tonal(
              onPressed: _busy ? null : () => _use(entry),
              child: const Text('Use'),
            ),
          ),
        if (_busy) ...[
          const SizedBox(height: 4),
          LinearProgressIndicator(value: _loadFraction),
          const SizedBox(height: 4),
          Text(
            _loadStatus != null && _loadStatus!.isNotEmpty
                ? _loadStatus!
                : 'Loading model…',
            style: theme.textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 4),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 8),
        const Divider(),
        const SizedBox(height: 16),
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
