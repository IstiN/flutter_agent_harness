/// Public surface for the bundled Codex model catalog. The actual data
/// is generated from the official codex-rs models.json by
/// `scripts/sync_codex_models.dart` (committed alongside this file).
///
/// Re-run that script when codex-rs ships a new catalog — the picker,
/// the OAuth default, and the per-model context-window/maxTokens maps
/// all flow from the generated `chatGptCodexBundledModels` list below.
library;

import 'chatgpt_codex_models_data.dart';

/// Slugs only — same shape callers used to read from the hand-rolled
/// list before the sync script existed.
final List<String> chatGptCodexModels = <String>[
  for (final m in chatGptCodexBundledModels) m.slug,
];

/// Default model — first entry of [chatGptCodexBundledModels],
/// kept as a separate constant so the OAuth flow and the picker agree.
final String chatGptCodexDefaultModel = chatGptCodexBundledDefault;

/// Per-model context window (input cap) keyed by slug.
final Map<String, int> chatGptCodexContextWindows = <String, int>{
  for (final m in chatGptCodexBundledModels)
    if (m.contextWindow > 0) m.slug: m.contextWindow,
};

/// Per-model output cap (max tokens) keyed by slug.
final Map<String, int> chatGptCodexMaxTokens = <String, int>{
  for (final m in chatGptCodexBundledModels)
    if (m.maxTokens > 0) m.slug: m.maxTokens,
};
