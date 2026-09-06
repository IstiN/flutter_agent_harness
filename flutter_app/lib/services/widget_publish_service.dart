// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/services/github_account_store.dart';
import 'package:fa/services/github_api_client.dart';
import 'package:fa/services/widget_publication_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// One static pre-flight failure, with an actionable fix hint.
final class WidgetPreflightIssue {
  const WidgetPreflightIssue(this.code, this.message);

  /// Stable machine-readable code (e.g. `entry_missing`).
  final String code;

  /// Human-readable, actionable message (what to fix and how).
  final String message;

  @override
  String toString() => 'WidgetPreflightIssue($code): $message';
}

/// The outcome of a successful [WidgetPublishService.publish].
final class WidgetPublishResult {
  const WidgetPublishResult({
    required this.publication,
    required this.reusedPr,
  });

  /// The ledger record after the publish (step `pr_opened`).
  final WidgetPublication publication;

  /// True when the open PR from a previous publish was reused instead of
  /// creating a duplicate (AC6).
  final bool reusedPr;

  /// The opened (or reused) catalog pull request number.
  int? get prNumber => publication.prNumber;

  /// Browser URL of the opened (or reused) catalog pull request.
  String get prUrl => publication.prUrl;
}

/// Thrown by [WidgetPublishService.publish] when no GitHub account is
/// connected — the UI opens the connect sheet instead (AC8).
final class GithubNotConnectedException implements Exception {
  const GithubNotConnectedException();

  @override
  String toString() =>
      'GithubNotConnectedException: connect a GitHub account to publish';
}

/// Publish orchestration (card `goal/widget-publishing-github.md`, issue
/// #35): pre-flight validation → user repo create-or-update → commit widget
/// sources → fork `IstiN/fa_widgets` → branch + external submodule pin +
/// overlay → open (or reuse) the PR → record the submission in the ledger.
///
/// The service writes ONLY to the connected user's own repositories and
/// their fork; the catalog repo is written exclusively through the PR.
/// All network goes through the injectable [GithubApiClient] factory so
/// tests script the REST flow with `http.testing.MockClient`.
class WidgetPublishService {
  WidgetPublishService({
    required ExecutionEnv env,
    required GithubAccountStore account,
    required WidgetPublicationStore ledger,
    GithubApiClient Function(String token)? clientFactory,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
  }) // ignore: prefer_initializing_formals — private fields, public params
    // ignore: prefer_initializing_formals
    : _env = env,
       // ignore: prefer_initializing_formals
       _account = account,
       // ignore: prefer_initializing_formals
       _ledger = ledger,
       _clientFactory =
           clientFactory ?? ((token) => GithubApiClient(token: token)),
       _clock = clock ?? DateTime.now,
       _sleep = sleep ?? Future<void>.delayed;

  /// Catalog pre-flight limits (edge case E4; the fa_widgets validator
  /// enforces the same numbers).
  static const maxFolderBytes = 5 * 1024 * 1024;
  static const maxFolderFiles = 100;

  static final _idPattern = RegExp(r'^[a-z0-9-]+$');
  static final _semverPattern = RegExp(
    r'^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$',
  );
  static final _repoNameInvalidChars = RegExp(r'[^A-Za-z0-9._-]+');

  final ExecutionEnv _env;
  final GithubAccountStore _account;
  final WidgetPublicationStore _ledger;
  final GithubApiClient Function(String token) _clientFactory;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _sleep;

  // --- pre-flight ----------------------------------------------------------

  /// Static checks only — no engine boot, no network. Every failure is
  /// returned as a [WidgetPreflightIssue] with an actionable message; an
  /// empty list means the widget is publishable.
  Future<List<WidgetPreflightIssue>> preflight(JsAppInfo app) async {
    final issues = <WidgetPreflightIssue>[];

    // Id shape: catalog ids are lowercase slug segments.
    if (!_idPattern.hasMatch(app.id)) {
      issues.add(
        WidgetPreflightIssue(
          'id_invalid',
          'Widget id "${app.id}" must match ^[a-z0-9-]+\$ — rename the '
              'widget folder and the manifest "id" to a lowercase slug '
              '(letters, digits, dashes).',
        ),
      );
    }

    // Version shape.
    if (!_semverPattern.hasMatch(app.version)) {
      issues.add(
        WidgetPreflightIssue(
          'version_invalid',
          'Version "${app.version}" is not valid semver — set "version" in '
              'manifest.json to e.g. "1.0.0".',
        ),
      );
    }

    // Manifest parses and its id matches the folder name.
    final manifestText = (await _env.readTextFile(
      app.manifestPath,
    )).valueOrNull;
    Map<String, Object?>? manifest;
    if (manifestText == null) {
      issues.add(
        WidgetPreflightIssue(
          'manifest_missing',
          'manifest.json is missing at ${app.manifestPath} — the widget '
              'needs a manifest to be published.',
        ),
      );
    } else {
      try {
        final decoded = jsonDecode(manifestText);
        if (decoded is Map) {
          manifest = Map<String, Object?>.from(decoded);
        } else {
          throw const FormatException('manifest root is not an object');
        }
      } on FormatException {
        issues.add(
          WidgetPreflightIssue(
            'manifest_invalid',
            'manifest.json does not parse as a JSON object — fix the syntax '
                'error in ${app.manifestPath}.',
          ),
        );
      }
      final folderName = app.dir.split('/').last;
      final manifestId = manifest?['id']?.toString();
      if (manifest != null && manifestId != folderName) {
        issues.add(
          WidgetPreflightIssue(
            'manifest_id_mismatch',
            'manifest "id" ($manifestId) does not match the folder name '
                '($folderName) — make them identical.',
          ),
        );
      }
    }

    // Entry file: widget.js, or the tile entry when the app has no full
    // widget entry.
    final entryOk =
        await _nonEmptyFile('${app.dir}/widget.js') ||
        (app.tileWidget != null && await _nonEmptyFile(app.tileWidgetPath));
    if (!entryOk) {
      issues.add(
        WidgetPreflightIssue(
          'entry_missing',
          'Neither ${app.dir}/widget.js nor the tile entry exists and is '
              'non-empty — add the widget entry point.',
        ),
      );
    }

    // Icon: an icon.svg file OR a non-empty emoji/string icon field.
    final hasIconFile =
        (await _env.exists('${app.dir}/icon.svg')).valueOrNull == true;
    if (!hasIconFile && app.icon.trim().isEmpty) {
      issues.add(
        WidgetPreflightIssue(
          'icon_missing',
          'No icon: add ${app.dir}/icon.svg or set a non-empty "icon" '
              '(emoji) in manifest.json.',
        ),
      );
    }

    // Folder limits (E4).
    var totalBytes = 0;
    var totalFiles = 0;
    await _walk(app.dir, (path, size) {
      totalFiles++;
      totalBytes += size;
    });
    if (totalBytes > maxFolderBytes) {
      issues.add(
        WidgetPreflightIssue(
          'folder_too_large',
          'Widget folder is $totalBytes bytes — the catalog limit is '
              '$maxFolderBytes (5 MiB). Shrink bundled assets.',
        ),
      );
    }
    if (totalFiles > maxFolderFiles) {
      issues.add(
        WidgetPreflightIssue(
          'too_many_files',
          'Widget folder has $totalFiles files — the catalog limit is '
              '$maxFolderFiles. Remove unneeded files.',
        ),
      );
    }

    return issues;
  }

  Future<bool> _nonEmptyFile(String path) async {
    final info = (await _env.fileInfo(path)).valueOrNull;
    return info != null && info.kind == FileKind.file && info.size > 0;
  }

  Future<void> _walk(
    String dir,
    FutureOr<void> Function(String path, int size) onFile,
  ) async {
    final children = (await _env.listDir(dir)).valueOrNull;
    if (children == null) return;
    for (final child in children) {
      switch (child.kind) {
        case FileKind.directory:
          await _walk(child.path, onFile);
        case FileKind.file:
          await onFile(child.path, child.size);
        case FileKind.symlink:
          // Symlinks are not followed — the sandbox never publishes links.
          break;
      }
    }
  }

  // --- publish -------------------------------------------------------------

  /// Runs the whole publish flow. Throws [GithubNotConnectedException] when
  /// no account is connected, and [StateError] listing the issues when
  /// pre-flight fails.
  Future<WidgetPublishResult> publish({
    required JsAppInfo app,
    String? repoName,
  }) async {
    final token = _account.token;
    if (token == null) throw const GithubNotConnectedException();
    final issues = await preflight(app);
    if (issues.isNotEmpty) {
      throw StateError(
        'Widget "${app.id}" failed pre-flight:\n'
        '${issues.map((i) => ' - [${i.code}] ${i.message}').join('\n')}',
      );
    }
    final client = _clientFactory(token);
    final login = _account.login ?? (await client.getUser()).login;
    final existing = _ledger.byWidgetId(app.id);

    final String owner;
    final String name;
    final String repoCommit;

    if (existing != null && existing.step == WidgetPublication.stepRepoPushed) {
      // E7 kill-resume: sources were already pushed before the app died —
      // reuse the recorded repo + commit and continue at the PR step.
      final parts = existing.repoFullName.split('/');
      owner = parts.first;
      name = parts.last;
      repoCommit = existing.repoCommit;
    } else {
      // Repo step: reuse the ledger-recorded repo when re-publishing.
      if (existing != null) {
        final parts = existing.repoFullName.split('/');
        owner = parts.first;
        name = parts.last;
      } else {
        owner = login;
        name = sanitizeRepoName(repoName ?? 'fa-widget-${app.id}');
      }

      final repo = await client.getRepo(owner, name);
      if (repo == null) {
        await client.createRepo(name: name, description: _repoDescription(app));
      } else if (repo.isPrivate) {
        throw StateError(
          'Repository $owner/$name is private — make it public; the '
          'catalog clones widget repos anonymously.',
        );
      }
      final headSha = await client.getHeadSha(owner, name, 'main');
      if (repo != null) {
        // E3: never push into a foreign repo. Provenance holds when the
        // repo is the ledger-recorded one, carries our description marker,
        // or is still empty.
        final ledgerRecorded =
            existing != null && existing.repoFullName == '$owner/$name';
        final hasMarker =
            repo.description?.contains(_provenanceMarker(app.id)) ?? false;
        if (!ledgerRecorded && !hasMarker && headSha != null) {
          throw StateError(
            'Repository $owner/$name already exists and is not a Fa widget '
            'repo for "${app.id}" — pick a different repo name instead of '
            'pushing into a foreign repository.',
          );
        }
      }

      // Commit the widget sources (flat repo root = widget root).
      final files = await _collectWidgetFiles(app);
      final entries = <GithubTreeEntry>[
        for (final path in (files.keys.toList()..sort()))
          GithubTreeEntry.file(
            path,
            await client.createBlob(owner, name, files[path]!),
          ),
      ];
      // The Trees API accepts a commit sha as base_tree.
      final treeSha = await client.createTree(
        owner,
        name,
        entries,
        baseTreeSha: headSha,
      );
      repoCommit = await client.createCommit(
        owner,
        name,
        treeSha: treeSha,
        message: 'Publish ${app.id} ${app.version}',
        parentSha: headSha,
      );
      await client.updateRef(owner, name, 'main', repoCommit);
      // E7: record the reached step BEFORE the PR work so an app kill
      // resumes here instead of duplicating the push.
      await _ledger.record(
        WidgetPublication(
          widgetId: app.id,
          version: app.version,
          repoFullName: '$owner/$name',
          repoCommit: repoCommit,
          step: WidgetPublication.stepRepoPushed,
          submittedAt: _clock().toUtc(),
          prNumber: existing?.prNumber,
          prHtmlUrl: existing?.prHtmlUrl,
        ),
      );
    }

    // PR step: fork → branch + overlay + gitlink → open/reuse the PR.
    final fork = await client.ensureFork(
      owner: GithubApiClient.catalogOwner,
      repo: GithubApiClient.catalogRepo,
      asUser: login,
      sleep: _sleep,
    );
    const catalogRepo = GithubApiClient.catalogRepo;
    final branch = 'publish/${app.id}-${app.version}';
    final baseSha = await client.getHeadSha(
      login,
      catalogRepo,
      fork.defaultBranch,
    );

    final manifest = await _readManifest(app);
    final hasIconFile =
        (await _env.exists('${app.dir}/icon.svg')).valueOrNull == true;
    final overlay = <String, Object?>{
      'icon': hasIconFile ? 'icon.svg' : app.icon,
      'description': app.description,
      if (manifest?['tags'] != null) 'tags': manifest!['tags'],
      if (manifest?['minRuntime'] != null)
        'minRuntime': manifest!['minRuntime'],
      'author': login,
      'source': {'repo': '$owner/$name', 'commit': repoCommit},
    };

    final overlayBlob = await client.createBlob(
      login,
      catalogRepo,
      const JsonEncoder.withIndent('  ').convert(overlay),
    );
    final gitmodulesBlob = await client.createBlob(
      login,
      catalogRepo,
      _buildGitmodules(widgetId: app.id, repoFullName: '$owner/$name'),
    );
    final prTreeSha = await client.createTree(login, catalogRepo, [
      GithubTreeEntry.file('.gitmodules', gitmodulesBlob),
      GithubTreeEntry.file('widgets/${app.id}/overlay.json', overlayBlob),
      GithubTreeEntry.submodule('vendor/external/${app.id}', repoCommit),
    ], baseTreeSha: baseSha);
    final prCommit = await client.createCommit(
      login,
      catalogRepo,
      treeSha: prTreeSha,
      message: 'Add widget ${app.id} ${app.version}',
      parentSha: baseSha,
    );
    await client.createBranch(login, catalogRepo, branch, prCommit);
    await client.updateRef(login, catalogRepo, branch, prCommit);

    // AC6: re-publishing reuses the open PR instead of duplicating it.
    var reusedPr = false;
    var pull = await client.findOpenPull(
      GithubApiClient.catalogOwner,
      catalogRepo,
      head: '$login:$branch',
    );
    if (pull != null) {
      reusedPr = true;
    } else {
      pull = await client.createPull(
        owner: GithubApiClient.catalogOwner,
        repo: catalogRepo,
        head: '$login:$branch',
        base: 'main',
        title: 'Add widget ${app.id} ${app.version}',
        body: _prBody(app, owner: owner, name: name, commit: repoCommit),
      );
    }

    final publication = await _ledger.record(
      WidgetPublication(
        widgetId: app.id,
        version: app.version,
        repoFullName: '$owner/$name',
        repoCommit: repoCommit,
        step: WidgetPublication.stepPrOpened,
        submittedAt: _clock().toUtc(),
        prNumber: pull.number,
        prHtmlUrl: pull.htmlUrl,
        lastKnownState: WidgetPublication.stateOpen,
      ),
    );
    return WidgetPublishResult(publication: publication, reusedPr: reusedPr);
  }

  /// Polls the catalog PR of [publication], updates the ledger's last-known
  /// state and returns the refreshed UI-facing state. Returns the stored
  /// projection unchanged when the publication has no PR yet or the account
  /// is disconnected (offline degrade, AC8).
  Future<WidgetPublicationState> refreshStatus(
    WidgetPublication publication,
  ) async {
    final prNumber = publication.prNumber;
    final token = _account.token;
    if (prNumber == null || token == null) {
      return widgetPublicationStateOf(publication.lastKnownState);
    }
    final client = _clientFactory(token);
    final pull = await client.getPull(
      GithubApiClient.catalogOwner,
      GithubApiClient.catalogRepo,
      prNumber,
    );
    final state = pull == null
        ? WidgetPublication.stateUnknown
        : pull.state == 'open'
        ? WidgetPublication.stateOpen
        : pull.merged
        ? WidgetPublication.stateMerged
        : WidgetPublication.stateClosed;
    if (state != publication.lastKnownState) {
      await _ledger.record(publication.copyWith(lastKnownState: state));
    }
    return widgetPublicationStateOf(state);
  }

  // --- helpers -------------------------------------------------------------

  /// Sanitizes a user-typed repo name to GitHub's rules
  /// (`[A-Za-z0-9._-]`, ≤100 chars).
  static String sanitizeRepoName(String raw) {
    var name = raw.trim().replaceAll(_repoNameInvalidChars, '-');
    if (name.isEmpty) name = 'fa-widget';
    if (name.length > 100) name = name.substring(0, 100);
    return name;
  }

  static String _provenanceMarker(String widgetId) => 'fa-widget:$widgetId';

  static String _repoDescription(JsAppInfo app) =>
      'Fa widget: ${app.name} — published to the fa_widgets catalog '
      '(${_provenanceMarker(app.id)})';

  static String _prBody(
    JsAppInfo app, {
    required String owner,
    required String name,
    required String commit,
  }) {
    return 'Adds widget `${app.id}` ${app.version} to the catalog.\n'
        '\n'
        '- Description: ${app.description}\n'
        '- Source repo: https://github.com/$owner/$name\n'
        '- Pinned commit: `$commit`\n'
        '\n'
        '- [ ] CI validate passes\n';
  }

  Future<Map<String, Object?>?> _readManifest(JsAppInfo app) async {
    final text = (await _env.readTextFile(app.manifestPath)).valueOrNull;
    if (text == null) return null;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? Map<String, Object?>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  /// Reads every file under `app.dir` as publishable text content,
  /// `storage.json` excluded (it is user data and is never published).
  ///
  /// `FileInfo.path` from `listDir` is the env-ABSOLUTE normalized path;
  /// the repo tree paths are widget-root-relative POSIX-style (the same
  /// convention `JsAppInfo.dir` uses).
  ///
  /// Binary assets: the GitHub blob API takes base64, and the client's
  /// `createBlob` encodes its String content as UTF-8 — so bytes are first
  /// decoded strictly as UTF-8. On a [FormatException] the bytes fall back
  /// to a latin1 decode; NOTE that latin1 is lossy here (bytes ≥ 0x80 are
  /// re-encoded as multi-byte UTF-8), so true binary fidelity would need a
  /// pre-encoded-base64 blob path in `GithubApiClient` (contract-fixed).
  /// Widget assets (svg/json/js) are UTF-8 in practice.
  Future<Map<String, String>> _collectWidgetFiles(JsAppInfo app) async {
    final files = <String, String>{};
    await _walk(app.dir, (path, size) async {
      var relative = path;
      if (relative.startsWith('/')) relative = relative.substring(1);
      if (relative.startsWith('${app.dir}/')) {
        relative = relative.substring(app.dir.length + 1);
      }
      if (relative == 'storage.json') return; // user data, never published
      final bytes = (await _env.readBinaryFile(path)).valueOrNull;
      if (bytes == null) return;
      String content;
      try {
        content = utf8.decode(bytes);
      } on FormatException {
        content = latin1.decode(bytes); // see doc comment above
      }
      files[relative] = content;
    });
    return files;
  }

  /// Reconstructs the fork's `.gitmodules` with the runtime submodule, every
  /// `vendor/external/*` entry the ledger knows about, and this widget.
  ///
  /// LIMITATION: the current `GithubApiClient` has no contents/blob fetch,
  /// so the existing `.gitmodules` cannot be read — entries published from
  /// OTHER devices (not in this ledger) would be dropped from the file
  /// content written here. The gitlinks in the tree base are unaffected;
  /// only the `.gitmodules` blob is rewritten. Acceptable for v1 (single
  /// publishing device per account).
  String _buildGitmodules({
    required String widgetId,
    required String repoFullName,
  }) {
    final external = <String, String>{
      for (final p in _ledger.publications)
        if (p.widgetId != widgetId) p.widgetId: p.repoFullName,
      widgetId: repoFullName,
    };
    final buffer = StringBuffer()
      ..writeln('[submodule "vendor/js_widget_runtime"]')
      ..writeln('\tpath = vendor/js_widget_runtime')
      ..writeln(
        '\turl = https://github.com/IstiN/flutter_js_widget_runtime.git',
      );
    for (final id in external.keys.toList()..sort()) {
      buffer
        ..writeln('[submodule "vendor/external/$id"]')
        ..writeln('\tpath = vendor/external/$id')
        ..writeln('\turl = https://github.com/${external[id]}.git');
    }
    return buffer.toString();
  }
}
