/// The shared per-model context-window registry (gh-1742 invariant 2:
/// ONE window per model identity, everywhere).
///
/// Today the resolved window lived only on the MAIN agent's `Model`
/// instance: endpoint detection (`/models`) and `/model-edit` mutated that
/// one instance, while every child resolved
/// `effectiveContextWindow(wiring.model.contextWindow, null)` at spawn —
/// a child spawned after a live detection still rode the stale catalog
/// window (the dmtools evidence: children compacted at 88–97% of a
/// 131,072-token window the same model really served at ≥478k). This
/// registry is the ONE place a detection or override is published, keyed
/// by the `(provider, modelId, baseUrl)` identity every provider request
/// already rides, so main, children, the smol summarizer and the ctx
/// meter resolve the same number (E2: a detection for one identity never
/// crosses to another).
///
/// The registry also answers AC6's verified/unverified question: an entry
/// means the window is backed by an endpoint report or a user pin; no
/// entry means the carried (catalog) window is unverified and the meter
/// marks it.
library;

import '../model.dart';

/// The identity a context window is registered under: the same
/// `(provider, modelId, baseUrl)` triple every provider request carries.
final class ModelWindowKey {
  /// Creates a key from explicit identity parts.
  const ModelWindowKey({
    required this.provider,
    required this.modelId,
    this.baseUrl,
  });

  /// Builds the key for [model] — provider case-folded, base URL
  /// trailing-slash-normalized (saved entries and pinned chains disagree
  /// on the trailing slash routinely; they are the same endpoint).
  factory ModelWindowKey.of(Model model) => ModelWindowKey(
    provider: model.provider.trim().toLowerCase(),
    modelId: model.id.trim(),
    baseUrl: _normalizeBaseUrl(model.baseUrl),
  );

  static String? _normalizeBaseUrl(String url) {
    var normalized = url.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized.isEmpty ? null : normalized;
  }

  /// The provider id (`openrouter`, `copilot`, …), case-folded.
  final String provider;

  /// The model id (`claude-sonnet-5-5`, `anthropic/…` on OpenRouter).
  final String modelId;

  /// The endpoint base URL, trailing-slash-normalized; null for blank.
  final String? baseUrl;

  @override
  bool operator ==(Object other) =>
      other is ModelWindowKey &&
      other.provider == provider &&
      other.modelId == modelId &&
      other.baseUrl == baseUrl;

  @override
  int get hashCode => Object.hash(provider, modelId, baseUrl);

  @override
  String toString() => '$provider/$modelId@$baseUrl';
}

/// Where a registered window came from — the AC6 verification ladder:
/// an endpoint report or a user pin VERIFIES the window; the absence of
/// both leaves the carried (catalog) value unverified.
enum ContextWindowSource {
  /// The provider's `/models`-family endpoint reported the window.
  endpointReport,

  /// The user pinned the window explicitly (`/model-edit`, a roles-chain
  /// entry) — wins over an endpoint report by publish order.
  userPin,
}

/// One registered window with its provenance.
final class RegisteredContextWindow {
  /// Creates a registration row.
  const RegisteredContextWindow({
    required this.window,
    required this.source,
    required this.at,
  });

  /// The registered context window, in tokens.
  final int window;

  /// What backed the value ([ContextWindowSource]).
  final ContextWindowSource source;

  /// When the value was published.
  final DateTime at;
}

/// The per-model window registry. One instance per session, shared by the
/// host (main + meter), the task executor (children) and any other
/// consumer of the effective window for a model identity.
final class ContextWindowRegistry {
  final Map<ModelWindowKey, RegisteredContextWindow> _entries = {};

  /// Publishes [window] for [model]'s identity. Later publishes win (an
  /// endpoint detection at boot, then a live `/model-edit`). Non-positive
  /// windows are ignored — they are never a resolution.
  void publish({
    required Model model,
    required int window,
    required ContextWindowSource source,
    DateTime? at,
  }) {
    if (window <= 0) return;
    _entries[ModelWindowKey.of(model)] = RegisteredContextWindow(
      window: window,
      source: source,
      at: at ?? DateTime.now(),
    );
  }

  /// The registered window for [model]'s identity, or `null` when nothing
  /// was published for it (the caller falls back to the carried value).
  int? windowFor(Model model) => _entries[ModelWindowKey.of(model)]?.window;

  /// Whether [model]'s window is backed by an endpoint report or a user
  /// pin (AC6): `false` means the carried window is unverified and the
  /// meters mark it.
  bool isVerified(Model model) =>
      _entries.containsKey(ModelWindowKey.of(model));

  /// Drops every registration (test seam; a host never calls this
  /// mid-session — E4 window shrinks arrive as new publishes).
  void clear() => _entries.clear();

  /// Read-only view for diagnostics/tests.
  Map<ModelWindowKey, RegisteredContextWindow> get entries =>
      Map.unmodifiable(_entries);
}

/// Returns [model] with its context window replaced by the registered
/// value when one exists — the child-wiring shape of invariant 2 (the
/// loop's over-window guard reads `model.contextWindow`, so the resolved
/// window must ride the Model instance itself). Pure: returns [model]
/// unchanged when nothing is registered or the value already matches.
Model withRegisteredContextWindow(
  Model model,
  ContextWindowRegistry? registry,
) {
  final registered = registry?.windowFor(model);
  // ignore: avoid_print
  print('DEBUG wRCW id=' + model.id + ' registered=' + registered.toString() + ' cur=' + model.contextWindow.toString());
  if (registered == null || registered == model.contextWindow) return model;
  // One shared field list (gh-1742 review round 1, comment 5): the copy
  // lives on [Model] itself.
  return model.copyWith(contextWindow: registered);
}
