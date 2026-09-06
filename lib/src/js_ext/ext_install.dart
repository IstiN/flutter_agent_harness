/// Install planners for JS extensions — local directory, local zip, GitHub
/// repo, and catalog — plus the trust-gated [applyInstall] (TOFU on first
/// install, re-prompt on capability diff, silent re-grant on hash-only
/// change).
///
/// All network access goes through the injected `package:http` [http.Client]
/// so tests can serve fake GitHub/catalog servers; all file access goes
/// through [ExecutionEnv] (no dart:io).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../env/execution_env.dart';
import 'ext_catalog.dart';
import 'ext_manifest.dart';
import 'extension_store.dart';
import 'trust.dart';

/// Where an install plan was produced from.
enum ExtInstallSourceKind { localDir, localZip, github, catalog, bundled }

/// Everything [applyInstall] needs: resolved files, parsed manifest, and the
/// provenance the trust record should carry.
final class ExtInstallPlan {
  /// Extension name (from the manifest).
  final String name;

  /// Relative path -> text content; must contain `manifest.json`+`main.js`.
  final Map<String, String> files;

  /// Parsed `manifest.json`.
  final ExtensionManifest manifest;

  /// Provenance for the trust record.
  final ExtTrustSource trustSource;

  /// Source-specific reference (see [ExtTrustSource]).
  final String trustRef;

  /// Creates a plan.
  const ExtInstallPlan({
    required this.name,
    required this.files,
    required this.manifest,
    required this.trustSource,
    required this.trustRef,
  });
}

/// Install planning or application failure.
class ExtInstallException implements Exception {
  /// Human-readable failure description.
  final String message;

  /// Creates an exception with [message].
  const ExtInstallException(this.message);

  @override
  String toString() => 'ExtInstallException: $message';
}

/// Result of [applyInstall]: whether files were written, why not, and
/// whether the user was re-prompted.
final class ExtInstallOutcome {
  /// Whether the extension files (and trust) were written this call.
  final bool installed;

  /// Why nothing was installed (`null` when [installed]).
  final String? reason;

  /// Whether the decision involved a capability-diff re-prompt.
  final bool rePrompted;

  /// Creates an outcome.
  const ExtInstallOutcome({
    required this.installed,
    this.reason,
    this.rePrompted = false,
  });
}

/// Plans an install from a local [path]: a directory containing
/// `manifest.json`+`main.js` (plus extra TEXT files; dotfiles and binary
/// files are skipped), or a `.zip` archive extracted with the shared
/// hostile-zip rules. `trustRef` is the absolute path.
Future<ExtInstallPlan> planLocalInstall(String path, ExecutionEnv env) async {
  final absolute = (await env.absolutePath(path)).getOrThrow();
  final info = await env.fileInfo(absolute);
  if (info.isErr) {
    throw ExtInstallException(
      'cannot inspect $path: ${info.errorOrNull!.message}',
    );
  }
  final kind = info.valueOrNull!.kind;
  final files = kind == FileKind.directory
      ? await _readExtDir(absolute, env)
      : await _readExtZipFile(absolute, env);
  return _planFromFiles(files, ExtTrustSource.local, absolute, label: absolute);
}

/// Plans an install from `owner/repo`: resolves the default branch, reads
/// the ROOT `manifest.json` via raw.githubusercontent.com (v1 layout only),
/// then downloads the branch archive from codeload and extracts the subdir
/// containing the manifest. `trustRef` is `owner/repo@<gitSha|branch>` — the
/// resolved commit sha when the refs lookup succeeds, the branch otherwise
/// (`HEAD` when even the default branch is unknown).
Future<ExtInstallPlan> planGithubInstall(
  String ownerSlashRepo,
  http.Client client, {
  String githubApiBase = 'https://api.github.com',
}) async {
  final (owner, repo) = _validateGithubSource(ownerSlashRepo);
  final base = _trimTrailingSlash(githubApiBase);
  final (:branch, :sha) = await _resolveGithubBranch(
    client,
    base,
    owner,
    repo,
    ownerSlashRepo,
  );

  _expectOk(
    await client.get(
      Uri.parse(
        'https://raw.githubusercontent.com/$owner/$repo/$branch/manifest.json',
      ),
    ),
    (code) =>
        'repo root must contain manifest.json+main.js '
        '(HTTP $code for $owner/$repo/manifest.json)',
  );
  final archiveResponse = await client.get(
    Uri.parse('https://codeload.github.com/$owner/$repo/zip/$branch'),
  );
  _expectOk(
    archiveResponse,
    (code) => 'failed to download $ownerSlashRepo archive (HTTP $code)',
  );

  final files = extractExtensionZip(
    archiveResponse.bodyBytes,
    label: ownerSlashRepo,
  );
  return _planFromFiles(
    files,
    ExtTrustSource.github,
    '$ownerSlashRepo@${sha ?? branch}',
    label: ownerSlashRepo,
  );
}

(String, String) _validateGithubSource(String ownerSlashRepo) {
  final parts = ownerSlashRepo.split('/');
  if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) {
    throw ExtInstallException(
      'github source must be "owner/repo", got "$ownerSlashRepo"',
    );
  }
  return (parts[0], parts[1]);
}

String _trimTrailingSlash(String url) =>
    url.endsWith('/') ? url.substring(0, url.length - 1) : url;

/// Resolves the default branch (falling back to `HEAD`) and its commit sha
/// when the refs lookup succeeds.
Future<({String branch, String? sha})> _resolveGithubBranch(
  http.Client client,
  String base,
  String owner,
  String repo,
  String ownerSlashRepo,
) async {
  final repoJson = await _getJson(
    client,
    Uri.parse('$base/repos/$owner/$repo'),
    ownerSlashRepo,
  );
  var branch = repoJson['default_branch'];
  if (branch is! String || branch.isEmpty) branch = 'HEAD';
  return (
    branch: branch,
    sha: await _refSha(client, base, owner, repo, branch, ownerSlashRepo),
  );
}

Future<String?> _refSha(
  http.Client client,
  String base,
  String owner,
  String repo,
  String branch,
  String ownerSlashRepo,
) async {
  try {
    final ref = await _getJson(
      client,
      Uri.parse('$base/repos/$owner/$repo/git/refs/heads/$branch'),
      ownerSlashRepo,
    );
    final value = (ref['object'] as Map?)?['sha'];
    if (value is String && value.isNotEmpty) return value;
  } on Object {
    // Unresolvable ref (branch renamed, offline mirror…) — fall back to
    // the branch name.
  }
  return null;
}

/// Throws [ExtInstallException] with [message] unless the response is 200.
void _expectOk(http.Response response, String Function(int code) message) {
  if (response.statusCode != 200) {
    throw ExtInstallException(message(response.statusCode));
  }
}

/// Plans an install from the catalog: fetches it, finds [catalogId], and
/// downloads the entry's verified zip. `trustRef` is the catalog id.
Future<ExtInstallPlan> planCatalogInstall(
  String catalogId, {
  required String baseUrl,
  required http.Client client,
}) async {
  final catalog = await fetchExtCatalog(baseUrl, client);
  for (final entry in catalog.entries) {
    if (entry.id != catalogId) continue;
    final files = await downloadExtZip(
      baseUrl: baseUrl,
      entry: entry,
      client: client,
    );
    return _planFromFiles(
      files,
      ExtTrustSource.catalog,
      entry.id,
      label: catalogId,
    );
  }
  throw ExtInstallException('catalog has no extension "$catalogId"');
}

/// Applies a plan to [store].
///
/// - A [pinSha256] mismatch over `extContentHash(plan.files)` rejects loudly
///   ([ExtInstallException]) before anything is written.
/// - TOFU: no existing trust => grant via [prompt]; a null prompt (or a
///   `false` answer) denies with nothing written. [trustFlag] approves the
///   FIRST grant without a prompt (it does not bypass update re-prompts).
/// - Existing install at the same content hash => up-to-date, no write.
/// - Capability diff vs the granted snapshot => re-prompt (denial keeps the
///   existing install); hash-only change => silent re-grant.
Future<ExtInstallOutcome> applyInstall(
  ExtInstallPlan plan,
  ExtensionStore store, {
  ExtTrustPrompt? prompt,
  String? pinSha256,
  bool trustFlag = false,
}) async {
  final contentSha = extContentHash(plan.files);
  if (pinSha256 != null && contentSha != pinSha256) {
    throw ExtInstallException(
      'pinned hash mismatch for ${plan.name}: expected $pinSha256, '
      'content is $contentSha',
    );
  }
  final capabilities = plan.manifest.capabilities.toJson();
  final existingTrust = (await store.find(plan.name))?.trust;

  if (existingTrust == null) {
    final approved =
        trustFlag || await _ask(prompt, plan, contentSha, capabilities);
    if (!approved) {
      return const ExtInstallOutcome(
        installed: false,
        reason: 'trust required, nothing written',
      );
    }
    await _grant(store, plan, contentSha, capabilities);
    return const ExtInstallOutcome(installed: true);
  }

  if (existingTrust.contentSha256 == contentSha) {
    return const ExtInstallOutcome(installed: false, reason: 'up-to-date');
  }
  if (!extCapabilitiesEqual(existingTrust.capabilities, capabilities)) {
    final request = _request(
      plan,
      contentSha,
      capabilities,
      previous: existingTrust.capabilities,
    );
    final approved = prompt != null && await prompt(request);
    if (!approved) {
      return const ExtInstallOutcome(
        installed: false,
        reason: 'capability change not approved, existing install kept',
      );
    }
    await _grant(store, plan, contentSha, capabilities);
    return const ExtInstallOutcome(installed: true, rePrompted: true);
  }
  await _grant(store, plan, contentSha, capabilities);
  return const ExtInstallOutcome(installed: true);
}

Future<bool> _ask(
  ExtTrustPrompt? prompt,
  ExtInstallPlan plan,
  String contentSha,
  Map<String, dynamic> capabilities,
) async {
  if (prompt == null) return false;
  return prompt(_request(plan, contentSha, capabilities));
}

ExtTrustRequest _request(
  ExtInstallPlan plan,
  String contentSha,
  Map<String, dynamic> capabilities, {
  Map<String, dynamic>? previous,
}) {
  return ExtTrustRequest(
    name: plan.name,
    source: plan.trustSource,
    sourceRef: plan.trustRef,
    contentSha256: contentSha,
    capabilities: capabilities,
    previousCapabilities: previous,
  );
}

Future<void> _grant(
  ExtensionStore store,
  ExtInstallPlan plan,
  String contentSha,
  Map<String, dynamic> capabilities,
) {
  return store.write(
    plan.name,
    files: plan.files,
    trust: TrustRecord(
      source: plan.trustSource,
      sourceRef: plan.trustRef,
      contentSha256: contentSha,
      capabilities: capabilities,
      grantedAt: DateTime.now().toUtc(),
    ),
  );
}

ExtInstallPlan _planFromFiles(
  Map<String, String> files,
  ExtTrustSource source,
  String trustRef, {
  required String label,
}) {
  final manifest = _parseManifest(files, label);
  return ExtInstallPlan(
    name: manifest.name,
    files: files,
    manifest: manifest,
    trustSource: source,
    trustRef: trustRef,
  );
}

ExtensionManifest _parseManifest(Map<String, String> files, String label) {
  final text = files[ExtensionStore.kManifestFile];
  if (text == null) {
    throw ExtInstallException('$label: archive misses manifest.json/main.js');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (error) {
    throw ExtInstallException(
      '$label: invalid manifest.json: ${error.message}',
    );
  }
  if (decoded is! Map<String, dynamic>) {
    throw ExtInstallException('$label: manifest.json must be a JSON object');
  }
  try {
    return ExtensionManifest.fromJson(decoded);
  } on ExtManifestException catch (error) {
    throw ExtInstallException('$label: $error');
  }
}

/// GETs [uri] and decodes the JSON object body; non-200 or a non-object
/// body throws [ExtInstallException] naming [label].
Future<Map<String, dynamic>> _getJson(
  http.Client client,
  Uri uri,
  String label,
) async {
  final response = await client.get(uri);
  if (response.statusCode != 200) {
    throw ExtInstallException('$label HTTP ${response.statusCode} ($uri)');
  }
  final decoded = jsonDecode(utf8.decode(response.bodyBytes));
  if (decoded is! Map) {
    throw ExtInstallException('$label: unexpected response from $uri');
  }
  return {for (final entry in decoded.entries) '${entry.key}': entry.value};
}

Future<Map<String, String>> _readExtDir(String dir, ExecutionEnv env) async {
  final files = await _walkExtDir(dir, env);
  if (!files.containsKey(ExtensionStore.kManifestFile) ||
      !files.containsKey(ExtensionStore.kMainFile)) {
    throw ExtInstallException('$dir must contain manifest.json and main.js');
  }
  return files;
}

/// Recursive walker; the required-files check lives in [_readExtDir] at the
/// TOP level only (subdirectories are ordinary extra files).
Future<Map<String, String>> _walkExtDir(
  String dir,
  ExecutionEnv env, [
  String prefix = '',
]) async {
  final listing = await env.listDir(dir);
  if (listing.isErr) {
    throw ExtInstallException(
      'cannot list $dir: ${listing.errorOrNull!.message}',
    );
  }
  final files = <String, String>{};
  for (final entry in listing.valueOrNull!) {
    if (entry.name.startsWith('.')) continue;
    final rel = prefix.isEmpty ? entry.name : '$prefix/${entry.name}';
    switch (entry.kind) {
      case FileKind.directory:
        files.addAll(await _walkExtDir(entry.path, env, rel));
      case FileKind.file:
        final text = (await env.readTextFile(entry.path)).valueOrNull;
        if (text == null) continue; // unreadable/binary — v1 is text-only
        files[rel] = text;
      case FileKind.symlink:
        break; // never follow symlinks out of the extension dir
    }
  }
  return files;
}

Future<Map<String, String>> _readExtZipFile(
  String path,
  ExecutionEnv env,
) async {
  final bytes = await env.readBinaryFile(path);
  if (bytes.isErr) {
    throw ExtInstallException(
      'cannot read $path: ${bytes.errorOrNull!.message}',
    );
  }
  return extractExtensionZip(bytes.valueOrNull!, label: path);
}
