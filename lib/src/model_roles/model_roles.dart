/// Intent-based model roles (`default`/`smol`/`slow`/`plan`) with ordered
/// fallback chains, API-key rotation, and path-scoped overrides.
///
/// Ported (reduced) from oh-my-pi's model-resolver / model-roles /
/// non-compaction-retry-policy (see the file-level docs for the per-piece
/// mapping):
///
/// - [roles_config.dart](roles_config.dart) — `ModelRolesConfig`, `ModelRef`,
///   the retry policy, path-override matching, and yaml (de)serialization.
/// - [key_rotation.dart](key_rotation.dart) — `ApiKeyRing`: round-robin over
///   stacked keys (`NAME`, `NAME_2`, ...) with per-key backoff and session
///   affinity.
/// - [fallback_stream.dart](fallback_stream.dart) — `FallbackStreamFunction`:
///   mid-turn take-over on 429/quota with visible [FallbackNotice]s.
/// - [provider_catalog.dart](provider_catalog.dart) — the provider table and
///   the `providerStreamFunction` adapter factory.
/// - [model_resolver.dart](model_resolver.dart) — `ModelRolesResolver`: the
///   consumer surface (agent runs, compaction `smol`, `/model` display).
library;

export 'fallback_stream.dart';
export 'key_rotation.dart';
export 'model_resolver.dart';
export 'provider_catalog.dart';
export 'roles_config.dart';
