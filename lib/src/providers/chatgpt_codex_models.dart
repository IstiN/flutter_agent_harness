/// The bundled ChatGPT Codex model catalog — mirrors what
/// `codex-rs/models-manager/models.json` ships. The Codex backend
/// (`https://chatgpt.com/backend-api/codex`) doesn't expose a public
/// `/models` endpoint, so the picker has to fall back to a hardcoded
/// list keyed off the canonical Codex CLI defaults.
///
/// The default ([chatGptCodexDefaultModel]) is the same `gpt-5.6-sol`
/// the original Codex CLI surfaces as the recommended entry point.
/// `chatGptCodexBaseUrl` lives in lib/src/providers/chatgpt_oauth.dart
/// (re-exported via flutter_agent_harness) — both layers read it from
/// there.
library;

const List<String> chatGptCodexModels = <String>[
  'gpt-5.6-sol',
  'gpt-5.6-terra',
  'gpt-5.6-luna',
  'gpt-5.5',
  'gpt-5.4',
  'gpt-5.4-mini',
  'gpt-5.2',
];

/// The default Codex model — the first entry in [chatGptCodexModels],
/// kept as a separate constant so the OAuth flow + the picker read the
/// same answer.
const String chatGptCodexDefaultModel = 'gpt-5.6-sol';