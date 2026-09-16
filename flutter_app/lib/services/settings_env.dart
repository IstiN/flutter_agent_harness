// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Compile-time and runtime configuration resolution for the flutter app:
/// `--dart-define` constants, the dev `.env` file, and the saved-keys store
/// overlay. Pure Dart (no widget imports) so boot-path code (see
/// `package:fa/boot/boot_config_codec.dart`) can resolve keys without
/// dragging the settings UI in.
library;

import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'session_keys_store.dart';

/// Compile-time configuration injected via `--dart-define`. Values fall back
/// to the `.env` file (local dev) at runtime — see [settingsEnv].
const settingsDartDefines = <String, String>{
  'OPENROUTER_API_KEY': String.fromEnvironment('OPENROUTER_API_KEY'),
  'MODEL_ID': String.fromEnvironment('MODEL_ID'),
  'BASE_URL': String.fromEnvironment('BASE_URL'),
  'HUGGINGFACE_TOKEN': String.fromEnvironment('HUGGINGFACE_TOKEN'),
};

/// Resolves a configuration default: `--dart-define` wins, then `.env`, then
/// [fallback].
String settingsEnv(String name, String fallback) {
  final dartValue = settingsDartDefines[name];
  if (dartValue != null && dartValue.isNotEmpty) return dartValue;
  if (dotenv.isInitialized && dotenv.env.containsKey(name)) {
    return dotenv.env[name]!;
  }
  return fallback;
}

/// Resolves a key default with the saved-keys store between `--dart-define`
/// and `.env` (overlay semantics, like `DotEnvSecretsStore`): an explicitly
/// saved key shadows the dev `.env`, a compile-time define shadows both.
String settingsKeyEnv(String name, SessionKeysStore? keysStore) {
  final dartValue = settingsDartDefines[name];
  if (dartValue != null && dartValue.isNotEmpty) return dartValue;
  final stored = keysStore?.valueOf(name);
  if (stored != null && stored.isNotEmpty) return stored;
  if (dotenv.isInitialized && dotenv.env.containsKey(name)) {
    return dotenv.env[name]!;
  }
  return '';
}
