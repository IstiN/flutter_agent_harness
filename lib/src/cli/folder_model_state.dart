/// Per-folder model memory: the model/provider triple last used in a
/// project folder, so a `/model` switch in one workspace does not leak
/// into every other folder on the next `fa` launch.
///
/// The global `~/.fah/config.yaml` keeps doing what it did (last-switch
/// persistence for the DEFAULT); the folder state overrides it whenever
/// this launch carries no explicit provider choice (`--model`,
/// `--provider`, `--base-url`, or an `FA_PROVIDER_*` env preconfig). The
/// file lives under the sessions root next to the folder's sessions:
/// `<sessionsRoot>/<encodeSessionCwd(cwd)>/model-state.json`.
library;

import 'dart:convert';

import '../env/execution_env.dart';
import '../session/session_repo.dart';

/// The model/provider triple saved for one project folder.
final class FolderModelState {
  /// Creates a [FolderModelState].
  const FolderModelState({
    required this.providerKind,
    required this.modelId,
    required this.baseUrl,
  });

  /// The provider kind (e.g. `openai-completions`, `anthropic`).
  final String providerKind;

  /// The model id as shown in `/model`.
  final String modelId;

  /// The endpoint base URL (`null` for catalog-default endpoints).
  final String? baseUrl;

  @override
  bool operator ==(Object other) =>
      other is FolderModelState &&
      other.providerKind == providerKind &&
      other.modelId == modelId &&
      other.baseUrl == baseUrl;

  @override
  int get hashCode => Object.hash(providerKind, modelId, baseUrl);
}

/// Path of the per-folder model state file for [cwd].
String folderModelStatePath({
  required String sessionsRoot,
  required String cwd,
}) => '$sessionsRoot/${encodeSessionCwd(cwd)}/model-state.json';

/// Whether the saved per-folder state may override the global config for
/// this launch: only when the user pinned nothing explicitly (flags or
/// the `FA_PROVIDER_*` env preconfig are per-launch declarations and
/// always win).
bool folderModelStateApplies({
  required bool modelExplicit,
  required bool providerExplicit,
  required bool baseUrlExplicit,
  required bool hasProviderPreconfig,
}) =>
    !modelExplicit &&
    !providerExplicit &&
    !baseUrlExplicit &&
    !hasProviderPreconfig;

/// Saves the model/provider triple for the folder [cwd] lives in.
///
/// Never throws on storage failure: a broken sessions root must not kill
/// a model switch (the global config persistence reports on its own).
Future<void> saveFolderModelState(
  ExecutionEnv env, {
  required String sessionsRoot,
  required String cwd,
  required String providerKind,
  required String modelId,
  required String? baseUrl,
}) async {
  try {
    final dir = '$sessionsRoot/${encodeSessionCwd(cwd)}';
    await env.createDir(dir, recursive: true);
    final write = await env.writeFile(
      '$dir/model-state.json',
      jsonEncode({
        'providerKind': providerKind,
        'modelId': modelId,
        'baseUrl': ?baseUrl,
      }),
    );
    write.getOrThrow();
  } on Object {
    // Best-effort: the switch itself already succeeded.
  }
}

/// Loads the model/provider triple saved for the folder [cwd] lives in,
/// or `null` when absent/corrupt (the global config stays in charge).
Future<FolderModelState?> loadFolderModelState(
  ExecutionEnv env, {
  required String sessionsRoot,
  required String cwd,
}) async {
  final text = (await env
      .readTextFile(folderModelStatePath(sessionsRoot: sessionsRoot, cwd: cwd)))
      .valueOrNull;
  if (text == null || text.isEmpty) return null;
  try {
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) return null;
    final providerKind = decoded['providerKind'];
    final modelId = decoded['modelId'];
    final baseUrl = decoded['baseUrl'];
    if (providerKind is! String ||
        providerKind.isEmpty ||
        modelId is! String ||
        modelId.isEmpty) {
      return null;
    }
    if (baseUrl != null && baseUrl is! String) return null;
    return FolderModelState(
      providerKind: providerKind,
      modelId: modelId,
      baseUrl: baseUrl as String?,
    );
  } on FormatException {
    return null;
  }
}
