/// Media-slot → tool-config adapters (gh-1984 AC5/AC8): the persisted
/// `models:` slots (`vision`, `transcription`) are the ONE source of truth
/// every host reads — the app writes them (its media-models store shares
/// the slot schema, see [MediaSlotModelConfig]), the CLI settings flow
/// writes them (`/models set vision <id>`, `/settings` → Media models),
/// and these resolvers turn them into the tool configs the plain CLI and
/// headless hosts register `inspect_image`/`transcribe_audio` with.
///
/// Precedence lives at the executable (`bin/fah.dart`): an explicit
/// `--vision-model`/`--transcribe-model` flag stays the override; without
/// one the persisted slot serves. Resolution runs per read/tool call via
/// the host's live resolver closures, so `/models set` edits (and a key
/// landing in the secure store) apply without a restart.
///
/// A `useMainConnection: true` slot resolves to null here BY DESIGN: the
/// main connection's model is the chat model — riding it would inspect
/// images with the very model that cannot see them (or with itself when it
/// can: redundant). The media generation tools (image/TTS/video) keep
/// their own explicit main-connection opt-in semantics.
library;

import '../model_roles/media_model_slots.dart';
import '../model_roles/models_config.dart';
import 'generate_image.dart' show MediaKeyResolver, resolveMediaSlotKey;
import 'inspect_image.dart';
import 'transcribe_audio.dart';

/// The `vision` slot as an [InspectImageConfig], or null when the slot is
/// unconfigured (no `models.slots.vision` override, or the
/// main-connection opt-in — see the library docs). An unresolvable key
/// still builds the config with an empty key: the slot IS configured (the
/// tool registers, /tools says so), and the call fails with the provider's
/// auth error — the read auto-route degrades to the omission note + reason
/// (gh-1984 AC6) instead of hiding the misconfiguration.
Future<InspectImageConfig?> resolveVisionSlotInspectConfig(
  ModelsConfig? modelsConfig, {
  required MediaKeyResolver resolveKey,
  String mainBaseUrl = '',
  String mainApiKey = '',
}) async {
  final override = modelsConfig?.slots['vision'];
  if (override == null || override.isMainConnectionOptIn) return null;
  final key = await resolveMediaSlotKey(
    override,
    mainBaseUrl: mainBaseUrl,
    mainApiKey: mainApiKey,
    resolveKey: resolveKey,
  );
  return InspectImageConfig(
    modelId: override.modelId,
    apiKey: key,
    baseUrl: override.baseUrl,
    providerKind: override.providerKind,
  );
}

/// The `transcription` slot as a [TranscribeAudioConfig], or null when the
/// slot is unconfigured (same rules as [resolveVisionSlotInspectConfig]).
/// The adapter family stays unset — the transcribe tool infers it from the
/// endpoint host (openai / groq / custom).
Future<TranscribeAudioConfig?> resolveTranscriptionSlotConfig(
  ModelsConfig? modelsConfig, {
  required MediaKeyResolver resolveKey,
  String mainBaseUrl = '',
  String mainApiKey = '',
}) async {
  final override = modelsConfig?.slots['transcription'];
  if (override == null || override.isMainConnectionOptIn) return null;
  final key = await resolveMediaSlotKey(
    override,
    mainBaseUrl: mainBaseUrl,
    mainApiKey: mainApiKey,
    resolveKey: resolveKey,
  );
  return TranscribeAudioConfig(
    modelId: override.modelId,
    apiKey: key,
    baseUrl: override.baseUrl,
  );
}

/// Builds the plain CLI host's live vision resolver (gh-1984 AC5/AC8): the
/// explicit `--vision-model` flag ([flagModel], with [flagBaseUrl]) is the
/// hard override — its boot config is built once by [flagConfig] (the
/// flag's own key resolution, unchanged); WITHOUT a flag the persisted
/// `models.slots.vision` serves, read LIVE from [modelsConfig] — the SAME
/// instance the host's `/models set` flow mutates, so a mid-session slot
/// edit (on a fresh install's empty fallback config included) applies
/// without a restart (review thread 6) — with the main connection in scope
/// ([mainBaseUrl]/[mainApiKey]) for the gh-184 same-host key reuse: one
/// rule with `generate_image`/`generate_video`, so the flagship
/// `/models set vision <id>` flow (no `apiKeyName`, main endpoint)
/// authenticates with the main key instead of an empty one (review
/// thread 2).
Future<InspectImageConfig?> Function() cliVisionSlotResolver({
  String? flagModel,
  String? flagBaseUrl,
  required ModelsConfig modelsConfig,
  required MediaKeyResolver resolveKey,
  required String mainBaseUrl,
  required String mainApiKey,
  required InspectImageConfig Function(String modelId, String? baseUrl)
  flagConfig,
}) {
  return () async {
    if (flagModel != null) return flagConfig(flagModel, flagBaseUrl);
    return resolveVisionSlotInspectConfig(
      modelsConfig,
      resolveKey: resolveKey,
      mainBaseUrl: mainBaseUrl,
      mainApiKey: mainApiKey,
    );
  };
}

/// Builds the plain CLI host's live transcription resolver — the
/// transcription twin of [cliVisionSlotResolver] (same flag override, same
/// live persisted slot, same main-connection scope).
Future<TranscribeAudioConfig?> Function() cliTranscriptionSlotResolver({
  String? flagModel,
  String? flagBaseUrl,
  required ModelsConfig modelsConfig,
  required MediaKeyResolver resolveKey,
  required String mainBaseUrl,
  required String mainApiKey,
  required TranscribeAudioConfig Function(String modelId, String? baseUrl)
  flagConfig,
}) {
  return () async {
    if (flagModel != null) return flagConfig(flagModel, flagBaseUrl);
    return resolveTranscriptionSlotConfig(
      modelsConfig,
      resolveKey: resolveKey,
      mainBaseUrl: mainBaseUrl,
      mainApiKey: mainApiKey,
    );
  };
}
