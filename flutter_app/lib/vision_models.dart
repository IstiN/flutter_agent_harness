/// Heuristic vision detection for free-form hosted model ids.
///
/// The app lets users type any model id on any OpenAI-compatible endpoint,
/// and most endpoints expose no modality metadata, so the agent's `Model`
/// would otherwise stay `input: ['text']` and the `read` tool would append
/// its "model does not support images" note for every picture. pi/oh-my-pi
/// populate `input` from provider metadata; where none exists this matcher
/// covers the well-known vision model families. A wrong `true` costs a
/// provider-side rejection of an image message (the model still works for
/// text); a wrong `false` makes the model blind — so the list errs on the
/// inclusive side for mainstream hosted models only.
library;

/// Vision-capable model families, matched case-insensitively against the
/// model id (including any `provider/` prefix OpenRouter adds).
const _visionMarkers = <String>[
  // OpenAI omni/reasoning families.
  'gpt-4o',
  'gpt-4.1',
  'gpt-4-turbo',
  'gpt-5',
  'chatgpt-4o',
  // Anthropic — every Claude 3+ is multimodal.
  'claude-3',
  'claude-4',
  'claude-sonnet',
  'claude-opus',
  'claude-haiku',
  // Google — all Gemini chat models are multimodal.
  'gemini-',
  // Qwen vision lines.
  'qwen-vl',
  'qwen2-vl',
  'qwen2.5-vl',
  'qvq',
  // Mistral vision lines.
  'pixtral',
  'mistral-small-3',
  'ministral',
  // Meta multimodal lines.
  'llama-3.2-11b',
  'llama-3.2-90b',
  'llama-4',
  // Community vision families.
  'llava',
  'moondream',
  'minicpm-v',
  'mini-cpm-v',
  'glm-4v',
  'glm-4.5v',
  'internvl',
  'cogvlm',
  'phi-3.5-vision',
  'phi-4-multimodal',
  // xAI.
  'grok-2-vision',
  'grok-4',
  // Gemma 3 multimodal sizes (the 1b is text-only).
  'gemma-3-4b',
  'gemma-3-12b',
  'gemma-3-27b',
];

/// Ids that match a marker above but are known text-only deployments.
const _textOnlyMarkers = <String>['embedding', 'gemma-3-1b'];

/// Whether [modelId] looks like a vision-capable hosted model.
bool modelIdSuggestsVision(String modelId) {
  final id = modelId.toLowerCase();
  if (id.isEmpty) return false;
  if (_textOnlyMarkers.any(id.contains)) return false;
  if (id.contains('vision')) return true;
  return _visionMarkers.any(id.contains);
}
