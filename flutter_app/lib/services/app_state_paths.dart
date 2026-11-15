/// The ONE runtime-state home for the app's UI/session stores (gh-2185):
/// `<cwd>/.fah/state/` under the sandbox root — never the repo root.
///
/// The stores used to persist `chat_read_cursors.json`,
/// `launcher_layout.json`, `network_mode.json`, `session_ui_prefs.json`,
/// `onboarding_seen.json`, `chat_list_pins.json` and `theme.json` straight
/// into `[ExecutionEnv.cwd]` — which, in a development checkout, is the
/// repository root. Runtime state ended up tracked in git (gh-2185). Every
/// writer now resolves through [appStateFilePath]; the `.fah/*` gitignore
/// rules keep the directory local-only. The pre-gh-2185 root location
/// stays readable for ONE release ([legacyAppStateFilePath] via
/// [readAppStateText]) so existing checkouts keep their state; the
/// fallback drops in a follow-up release.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The state-root path for [fileName]: `<cwd>/.fah/state/<fileName>`.
String appStateFilePath(ExecutionEnv env, String fileName) =>
    '${env.cwd}/.fah/state/$fileName';

/// The legacy (pre-gh-2185) root location — read-only fallback only.
String legacyAppStateFilePath(ExecutionEnv env, String fileName) =>
    '${env.cwd}/$fileName';

/// Reads [fileName] from the state root, falling back to the legacy root
/// location when the state-root copy is absent (gh-2185 migration). Null
/// when neither location has the file.
Future<String?> readAppStateText(ExecutionEnv env, String fileName) async {
  final current = (await env.readTextFile(
    appStateFilePath(env, fileName),
  )).valueOrNull;
  if (current != null) return current;
  return (await env.readTextFile(
    legacyAppStateFilePath(env, fileName),
  )).valueOrNull;
}
