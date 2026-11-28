// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The hosted on-device model cache verification helpers (gh-2466 rework
/// loc split): part of `settings.dart`'s library (gh-1232 god-file
/// ceiling — the sweep's extractions live here so the host file stays
/// under the loc gate). Extension members resolve statically inside the
/// library, so the callers in `settings.dart` are unchanged.
part of 'settings.dart';

/// Cache verification helpers of [_AgentSettingsFormState] for the
/// on-device WebLLM / transformers.js presets.
extension _WebLlmCacheHelpers on _AgentSettingsFormState {
  /// Falls the pre-selected WebLLM model back to the default preset when its
  /// weights were deleted from the cache meanwhile. An engine that cannot
  /// answer (unavailable platform, blocked storage) leaves the selection
  /// untouched — "unknown" must not cry "removed".
  Future<void> _verifyWebLlmCache(WebLlmModelPreset preset) async {
    final engine = widget.webLlmEngine ?? createWebLlmService();
    if (!engine.isAvailable) return;
    WebLlmCacheInfo? info;
    try {
      info = await engine.modelCacheInfo(preset.id);
    } on Object {
      return;
    }
    if (info == null || info.cached) return;
    if (!mounted) return;
    // The user moved on while the query ran — don't yank their selection.
    if (_selection != ProviderPreset.webllm || _webllmModel.id != preset.id) {
      return;
    }
    _formSetState(() {
      _webllmModel = webLlmModelPresets.first;
      _staleModelNote = context.l10n.settingsStaleModelCache(
        preset.displayName,
      );
    });
  }

  /// The transformers.js variant of [_verifyWebLlmCache].
  Future<void> _verifyTransformersJsCache(
    TransformersJsModelPreset preset,
  ) async {
    final engine = widget.transformersJsEngine ?? createTransformersJsService();
    if (!engine.isAvailable) return;
    TransformersJsCacheInfo? info;
    try {
      info = await engine.modelCacheInfo(preset.id);
    } on Object {
      return;
    }
    if (info == null || info.cached) return;
    if (!mounted) return;
    if (_selection != ProviderPreset.transformersJs ||
        _transformersJsModel.id != preset.id) {
      return;
    }
    _formSetState(() {
      _transformersJsModel = transformersJsModelPresets.first;
      _staleModelNote = context.l10n.settingsStaleModelCache(
        preset.displayName,
      );
    });
  }
}
