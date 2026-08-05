// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The read-only view of the host's active chat connection that fa_ui's
/// provider UI needs: which provider kind and endpoint it serves (for the
/// current-provider marks) and its model id (for summaries). Host apps
/// implement it over their agent service — the interface is a [Listenable]
/// so sections rebuild when the connection changes.
abstract interface class FaChatConnection implements Listenable {
  /// The active backend's provider kind (`openai-completions`, …).
  String get providerKind;

  /// The active endpoint's base URL (empty for on-device backends).
  String get activeBaseUrl;

  /// The active provider's stable id: the [CustomProvider] id or the
  /// provider preset's name, whatever the host's apply received as
  /// [FaChatModelConfig.providerId]. Null when the host does not track
  /// provider ids — the provider UI then matches "current" by base URL,
  /// which conflates providers sharing one host.
  String? get activeProviderId;

  /// The active chat model id.
  String get modelId;
}

/// The connection settings assembled by fa_ui's model pickers and handed to
/// the host's apply callback — the host maps it onto its own agent config
/// type (it owns the agent service).
final class FaChatModelConfig {
  /// Creates a connection config.
  const FaChatModelConfig({
    required this.providerKind,
    required this.modelId,
    required this.baseUrl,
    required this.apiKey,
    this.contextWindow = fallbackContextWindow,
    this.maxTokens = fallbackMaxTokens,
    this.supportsImages,
    this.providerId,
  });

  /// Provider adapter kind (fa_ui's endpoint pickers always produce
  /// `openai-completions`; on-device routes produce the host's own kinds).
  final String providerKind;

  /// Model id passed to the provider.
  final String modelId;

  /// Provider base URL. Empty for on-device providers.
  final String baseUrl;

  /// API key for the provider. Empty for on-device providers.
  final String apiKey;

  /// Context window reported to the agent loop (drives overflow/compaction
  /// heuristics).
  final int contextWindow;

  /// Output-token cap reported to the agent loop.
  final int maxTokens;

  /// Whether the model accepts image input; null defers to the host's own
  /// vision heuristic.
  final bool? supportsImages;

  /// The picked provider's stable id: the [CustomProvider] id or the
  /// provider preset's name; null for on-device routes. Lets hosts tell
  /// providers apart when several share one base URL.
  final String? providerId;

  @override
  String toString() => 'FaChatModelConfig($providerKind, $baseUrl, $modelId)';
}
