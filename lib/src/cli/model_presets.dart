/// The offline model-preset table: known model ids per catalog provider,
/// shown by the CLI's `/model` fallback and rendered into the installer
/// wizard's model menus.
///
/// Split out of the `agent_cli` library (gh-1596 AC6): the installer
/// generator (`scripts/gen_installers.dart`) renders the setup wizard's
/// model presets from THIS table, so a preset change fails the installer
/// golden test until the artifacts are regenerated — the wizard can never
/// drift from the CLI's own offline fallback.
///
/// TDD note: providers whose chat endpoint actually serves a `/v1/models`
/// response (MiniMax, OpenAI, OpenRouter, Google, Anthropic) are NOT
/// listed here — `/v1/models` is the source of truth. The list below is
/// a LAST-RESORT offline fallback only — picked when the live endpoint
/// fetch fails AND the remote catalog hasn't shipped an entry for that
/// provider. If you're adding a provider here because `/models` is
/// empty in the UI, first try `/v1/models` against the real endpoint
/// with the right auth — adding here is a temporary band-aid.
library;

/// Known model ids per provider name, in preference order — the FIRST
/// entry is the preset the surfaces mark `(recommended)`.
const knownModelPresets = <String, List<String>>{
  'openrouter': [
    'anthropic/claude-sonnet-4',
    'openai/gpt-4o-mini',
    'google/gemini-2.5-pro',
    'anthropic/claude-opus-4',
    'openai/gpt-4.1-mini',
  ],
  'kimi': ['k3', 'kimi-for-coding', 'kimi-for-coding-highspeed', 'k3-256k'],
  'anthropic': ['claude-sonnet-4-5', 'claude-opus-4', 'claude-haiku-4'],
  'google': ['gemini-2.5-pro', 'gemini-2.0-flash'],
  'openai': ['gpt-4o-mini', 'gpt-4o', 'gpt-4.1-mini'],
};

/// Model ids the CLI can put on screen WITHOUT any user config — the
/// offline fallback catalog above. The cli_visual leak guard subtracts
/// these from the real-config markers so a hermetic screen is never
/// flagged for bundled-catalog content (issue #508).
Set<String> get bundledCatalogModelIds => {
  for (final ids in knownModelPresets.values) ...ids,
};
