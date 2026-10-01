// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;

import 'package:fa/apps/apps_store.dart';
import 'package:fa/services/github_account_store.dart';
import 'package:fa/services/github_api_client.dart';
import 'package:fa/services/widget_publication_store.dart';
// The public barrel (fa_widgets_tool.dart) also exports the zip packager,
// which does not compile against the app's archive 4 (it declares ^3.6.1).
// The client validates ONLY, so it imports the validator subtree directly —
// one ruleset either way (issue #1045 I1).
// ignore: implementation_imports
import 'package:fa_widgets_tool/src/issues.dart';
// ignore: implementation_imports
import 'package:fa_widgets_tool/src/manifest.dart';
// ignore: implementation_imports
import 'package:fa_widgets_tool/src/validator.dart';
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

/// A publish attempt kicked off by [WidgetPublishService.startPublish]:
/// [publication] is the optimistic `publishing` ledger record (the UI
/// shows «publishing…» from it), [flow] completes with the PR result or
/// throws after the failure has been recorded in the ledger (I4).
final class PendingPublish {
  const PendingPublish({required this.publication, required this.flow});

  final WidgetPublication publication;
  final Future<WidgetPublishResult> flow;
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
/// #35; #232 pin-only PRs): pre-flight validation → user repo
/// create-or-update → commit widget sources → fork `IstiN/fa_widgets` →
/// branch + `widgets/<id>/overlay.json` carrying the `source: {repo,
/// commit}` pin → open (or reuse) the PR → record the submission in the
/// ledger. The PR touches exactly ONE file — the overlay — so parallel
/// publishes from any number of devices never conflict (#232).
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

  /// Widgets with a live publish flow (issue #1045 review): fire-and-forget
  /// removed the sheet-level serialization, so one widget has at most one
  /// in-flight flow — a second [startPublish] for the same id fails fast
  /// instead of double-writing the ledger. Process-wide ON PURPOSE: every
  /// publish entry point (launcher menu, account section, apps panel)
  /// constructs its own [WidgetPublishService], so an instance field would
  /// never see the second flow.
  static final Set<String> _activePublishes = <String>{};

  /// Catalog pre-flight limits (edge case E4; the fa_widgets validator
  /// enforces the same numbers).
  static const maxFolderBytes = 5 * 1024 * 1024;
  static const maxFolderFiles = 100;

  /// The catalog's canonical minimum `js_widget_runtime` (issue #1045
  /// AC2): stamped into the overlay when the widget's manifest never
  /// declares one, so a publish-bound manifest is never empty of
  /// `minRuntime` — the exact failure that sank fa_widgets PR #8.
  ///
  /// CROSS-REPO POINTER: the rule's authority is the catalog validator in
  /// github.com/IstiN/fa_widgets (its CI rejects manifests under its
  /// floor). When the catalog raises the floor, bump THIS constant in the
  /// same change — the fa_widgets_tool package it could be imported from
  /// exports no floor value yet (r2 review).
  static const catalogFloorRuntime = '0.4.79';

  /// Newest reviewer comments kept per publication in the ledger.
  static const _maxStoredComments = 50;

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

    // The catalog's own rule engine (issue #1045 AC1): every manifest rule
    // the CI validator enforces — required strings, strict semver,
    // minRuntime — checked on-device with the engine's VERBATIM error
    // strings, so what the user sees here is byte-identical to what the
    // run would have said. Advisory only (I2): CI stays the authority.
    if (manifest != null) {
      issues.addAll(await _catalogValidatorIssues(app, manifest));
    }

    return issues;
  }

  /// [manifest] with `minRuntime` stamped (issue #1045 AC2): a present,
  /// non-empty value wins (the version the widget was authored against);
  /// missing or empty falls to [catalogFloorRuntime] — never empty.
  static Map<String, Object?> stampedManifest(Map<String, Object?> manifest) {
    final existing = manifest['minRuntime'];
    final minRuntime = existing is String && existing.trim().isNotEmpty
        ? existing.trim()
        : catalogFloorRuntime;
    return {...manifest, 'minRuntime': minRuntime};
  }

  /// Runs the imported fa_widgets rule engine over the widget with the
  /// stamped manifest. On VM platforms the engine sees a real directory
  /// (a temp copy carrying the stamped manifest + entry + icon), so every
  /// error — including the strict-semver strings — comes from the SAME
  /// code the catalog CI runs. Where `dart:io` cannot serve a directory
  /// (web), the manifest-level rules still run through the engine's own
  /// [WidgetManifest] parser (verbatim `'x' must be a non-empty string`
  /// errors); directory-only checks stay advisory to CI (I2).
  Future<List<WidgetPreflightIssue>> _catalogValidatorIssues(
    JsAppInfo app,
    Map<String, Object?> manifest,
  ) async {
    final stamped = stampedManifest(manifest);
    // Env reads complete on microtasks (in-memory envs resolve inline), so
    // they stay async; only the real-file materialization below is sync.
    final entry = await _readEnvFile('${app.dir}/widget.js');
    final icon = await _readEnvFile('${app.dir}/icon.svg');
    try {
      return _runCatalogEngine(app, stamped, entry, icon);
    } on UnsupportedError {
      // No usable dart:io directory (web sandbox — Directory/file APIs
      // throw UnsupportedError there; checked on both dart2js and
      // dart2wasm builds of the publish sheet); parse through the engine's
      // manifest layer instead. Genuine engine bugs on the VM still
      // propagate.
      return _manifestLevelValidatorIssues(stamped);
    }
  }

  /// The engine pass over a materialized widget directory. The dart:io
  /// calls are deliberately SYNCHRONOUS: widget tests run in a fakeAsync
  /// zone where real async file I/O never completes — a sync materialize
  /// keeps preflight resolvable everywhere (issue #1045 golden suites).
  List<WidgetPreflightIssue> _runCatalogEngine(
    JsAppInfo app,
    Map<String, Object?> stamped,
    String? entry,
    String? icon,
  ) {
    final temp = Directory.systemTemp.createTempSync('fa-validate-');
    try {
      final widgetDir = Directory('${temp.path}/${app.id.split('/').last}')
        ..createSync(recursive: true);
      // The materialized manifest is the OVERLAY-MERGED one (what CI
      // actually validates): the publish overlay rewrites `icon` to the
      // packaged icon.svg when one ships, so the engine must see the
      // same merged shape — validate the manifest you publish, not the
      // one on disk.
      File('${widgetDir.path}/manifest.json').writeAsStringSync(
        jsonEncode({...stamped, if (icon != null) 'icon': 'icon.svg'}),
      );
      if (entry != null) {
        File('${widgetDir.path}/widget.js').writeAsStringSync(entry);
      }
      if (icon != null) {
        File('${widgetDir.path}/icon.svg').writeAsStringSync(icon);
      }
      final result = validateWidgetDirectory(widgetDir);
      return [
        // VERBATIM: the engine's own message, unmodified (issue #1045).
        for (final error in result.errors)
          WidgetPreflightIssue('validator', error.message),
      ];
    } finally {
      temp.deleteSync(recursive: true);
    }
  }

  /// Manifest-rule-only pass (web fallback): the engine's parser throws
  /// [ManifestException] with the same strings the CI surfaces.
  static List<WidgetPreflightIssue> _manifestLevelValidatorIssues(
    Map<String, Object?> stamped,
  ) {
    try {
      WidgetManifest.fromJson(stamped);
      return const [];
    } on ManifestException catch (error) {
      return [
        for (final message in error.errors)
          WidgetPreflightIssue('validator', message),
      ];
    }
  }

  Future<String?> _readEnvFile(String path) async =>
      (await _env.readTextFile(path)).valueOrNull;

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

  /// Fire-and-forget publish entry (issue #1045 AC6): validates, records
  /// the optimistic `publishing` state into the ledger, and RETURNS — the
  /// PR creation and CI run continue in [PendingPublish.flow] while the UI
  /// shows «publishing…» and the detail sheet resolves the outcome later.
  /// Throws [GithubNotConnectedException] when no account is connected,
  /// and [StateError] listing the issues when pre-flight fails (AC1: a
  /// rule-incomplete manifest never reaches the network).
  Future<PendingPublish> startPublish({
    required JsAppInfo app,
    String? repoName,
  }) async {
    // One flow per widget (issue #1045 review): fire-and-forget removed the
    // UI-level serialization, so the service owns the invariant. The check
    // + add run before the first await — no interleaving window.
    if (_activePublishes.contains(app.id)) {
      throw StateError(
        'publish_in_progress: widget "${app.id}" is already publishing',
      );
    }
    _activePublishes.add(app.id);
    final token = _account.token;
    if (token == null) {
      _activePublishes.remove(app.id);
      throw const GithubNotConnectedException();
    }
    final issues = await preflight(app);
    if (issues.isNotEmpty) {
      _activePublishes.remove(app.id);
      throw StateError(
        'Widget "${app.id}" failed pre-flight:\n'
        '${issues.map((i) => ' - [${i.code}] ${i.message}').join('\n')}',
      );
    }
    final previous = _ledger.byWidgetId(app.id);
    final publication = await _ledger.record(
      WidgetPublication(
        widgetId: app.id,
        version: app.version,
        repoFullName: previous?.repoFullName ?? '',
        repoCommit: previous?.repoCommit ?? '',
        step: WidgetPublication.stepPublishing,
        submittedAt: _clock().toUtc(),
        prNumber: previous?.prNumber,
        prHtmlUrl: previous?.prHtmlUrl,
        lastKnownState: WidgetPublication.statePublishing,
      ),
    );
    return PendingPublish(
      publication: publication,
      // The in-flight guard releases when the background flow settles —
      // success, recorded failure, or anything thrown by _recordFailure.
      flow: _recordFailure(
        app: app,
        previous: previous,
        flow: _executePublish(
          app: app,
          repoName: repoName,
          // The ledger already carries the optimistic `publishing` record
          // by the time the flow runs — the pre-publish snapshot decides
          // repo reuse / kill-resume (E7), not the optimistic entry.
          existing: previous,
        ),
      ).whenComplete(() => _activePublishes.remove(app.id)),
    );
  }

  /// Classic awaiting contract over [startPublish]: resolves with the PR
  /// result (or throws after recording the failure in the ledger — I4).
  Future<WidgetPublishResult> publish({
    required JsAppInfo app,
    String? repoName,
  }) async {
    final pending = await startPublish(app: app, repoName: repoName);
    return pending.flow;
  }

  /// Keeps a background publish failure visible (issue #1045 I4): the
  /// failed attempt lands in the ledger — `failed` + the verbatim error —
  /// while preserving any earlier PR pointer so the detail sheet still
  /// links the widget's open PR. Then rethrows for the live UI.
  Future<WidgetPublishResult> _recordFailure({
    required JsAppInfo app,
    required WidgetPublication? previous,
    required Future<WidgetPublishResult> flow,
  }) async {
    try {
      return await flow;
    } on Object catch (error) {
      await _ledger.record(
        (previous ??
                _ledger.byWidgetId(app.id) ??
                WidgetPublication(
                  widgetId: app.id,
                  version: app.version,
                  repoFullName: '',
                  repoCommit: '',
                  step: WidgetPublication.stepPublishing,
                  submittedAt: _clock().toUtc(),
                ))
            .copyWith(
              lastKnownState: WidgetPublication.stateFailed,
              lastError: error.toString(),
              validatorErrors: const [],
            ),
      );
      rethrow;
    }
  }

  Future<WidgetPublishResult> _executePublish({
    required JsAppInfo app,
    String? repoName,
    WidgetPublication? existing,
  }) async {
    final token = _account.token!;
    final client = _clientFactory(token);
    final login = _account.login ?? (await client.getUser()).login;

    final String owner;
    final String name;
    final String repoCommit;

    if (existing != null &&
        existing.step == WidgetPublication.stepRepoPushed &&
        existing.repoFullName.contains('/')) {
      // E7 kill-resume: sources were already pushed before the app died —
      // reuse the recorded repo + commit and continue at the PR step.
      final parts = existing.repoFullName.split('/');
      owner = parts.first;
      name = parts.last;
      repoCommit = existing.repoCommit;
    } else {
      // Repo step: reuse the ledger-recorded repo when re-publishing. An
      // optimistic record with an EMPTY repoFullName (a failed first
      // attempt that never reached the repo step) is not a recorded repo —
      // recompute, so a retry after a failure is never `GET /repos//`.
      if (existing != null && existing.repoFullName.contains('/')) {
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

      // The git data API (blobs/trees/commits) answers 409 "Git
      // Repository is empty." on a repo with zero commits — bootstrap it
      // with a Contents-API commit first (the only write endpoint that
      // works there); it also creates refs/heads/main for the follow-up
      // updateRef.
      var parentSha = headSha;
      parentSha ??= await client.putFile(
        owner,
        name,
        'README.md',
        message: 'Initialize Fa widget repo',
        content: _repoReadme(app),
      );

      // Commit the widget sources (flat repo root = widget root). The
      // tree is a FULL SNAPSHOT (no base_tree): the repo root must be
      // exactly the widget sources + README — carrying a base over would
      // keep any earlier garbage alive forever.
      final files = await _collectWidgetFiles(app);
      final readmeBlob = await client.createBlob(owner, name, _repoReadme(app));
      final entries = <GithubTreeEntry>[
        GithubTreeEntry.file('README.md', readmeBlob),
        for (final path in (files.keys.toList()..sort()))
          GithubTreeEntry.file(
            path,
            await client.createBlob(owner, name, files[path]!),
          ),
      ];
      final treeSha = await client.createTree(owner, name, entries);
      repoCommit = await client.createCommit(
        owner,
        name,
        treeSha: treeSha,
        message: 'Publish ${app.id} ${app.version}',
        parentSha: parentSha,
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

    // PR step: fork → branch + overlay (source pin only) → open/reuse the PR.
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
    // minRuntime is ALWAYS written (issue #1045 AC2 — the PR #8 failure
    // was an empty minRuntime): stamped from the manifest when declared,
    // from the catalog floor otherwise. The catalog validator merges the
    // overlay onto the pinned sources' manifest, so the merged manifest
    // the CI validates can never miss the field.
    final overlay = <String, Object?>{
      'icon': hasIconFile ? 'icon.svg' : app.icon,
      'description': app.description,
      if (manifest?['tags'] != null) 'tags': manifest!['tags'],
      'minRuntime': stampedManifest(manifest ?? const {})['minRuntime'],
      'author': login,
      'source': {'repo': '$owner/$name', 'commit': repoCommit},
    };

    final overlayBlob = await client.createBlob(
      login,
      catalogRepo,
      const JsonEncoder.withIndent('  ').convert(overlay),
    );
    final prTreeSha = await client.createTree(login, catalogRepo, [
      GithubTreeEntry.file('widgets/${app.id}/overlay.json', overlayBlob),
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
  ///
  /// Issue #1045: an open PR is further resolved through the CI check runs
  /// on its head sha — pending → `validating`, any failure → `invalid`
  /// with the validator's error lines stored VERBATIM plus the run link,
  /// all green → plain `open`.
  Future<WidgetPublicationState> refreshStatus(
    WidgetPublication publication,
  ) async {
    // Rebase onto the ledger's newest record: a stale snapshot (two
    // refreshes in flight, or a caller holding a pre-refresh copy) would
    // make the change-detector below compare against the wrong baseline
    // and skip persisting a real state transition.
    publication = _ledger.byWidgetId(publication.widgetId) ?? publication;
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

    // CI verdict on the PR head (issue #1045 AC3). A failed check read
    // (offline / rate limit) keeps the plain open state — never invent a
    // verdict the API did not confirm.
    var effective = state;
    var validatorErrors = publication.validatorErrors;
    var runUrl = publication.runHtmlUrl;
    if (state == WidgetPublication.stateOpen && pull?.headSha != null) {
      try {
        final checks = await client.listCheckRuns(
          GithubApiClient.catalogOwner,
          GithubApiClient.catalogRepo,
          pull!.headSha!,
        );
        final failing = checks.where((check) => check.isFailed).toList();
        if (checks.isEmpty || checks.any((check) => !check.isCompleted)) {
          effective = WidgetPublication.stateValidating;
          validatorErrors = const [];
          runUrl = null;
        } else if (failing.isNotEmpty) {
          effective = WidgetPublication.stateInvalid;
          validatorErrors = await _verbatimValidatorErrors(client, failing);
          runUrl = failing.first.htmlUrl;
        } else {
          effective = WidgetPublication.stateOpen;
          validatorErrors = const [];
          runUrl = null;
        }
      } on Object {
        // Offline / rate limit: keep the plain open state — never invent a
        // verdict the API did not confirm.
      }
    }

    // Reviewer feedback snapshot (AC7): the latest comments ride the same
    // refresh as the state so the publications view needs one action per
    // update. Capped at the newest [_maxStoredComments] to bound the
    // ledger file; bodies stay plain text (display-only data).
    var comments = publication.comments;
    if (pull != null) {
      try {
        final fetched = await client.listPullComments(
          GithubApiClient.catalogOwner,
          GithubApiClient.catalogRepo,
          prNumber,
        );
        comments = [
          for (final c
              in fetched.length > _maxStoredComments
                  ? fetched.sublist(fetched.length - _maxStoredComments)
                  : fetched)
            WidgetPublicationComment(
              author: c.author,
              body: c.body,
              createdAt: c.createdAt,
              isReview: c.isReview,
            ),
        ];
      } on Object {
        // State still refreshes when comments are unreachable (a partial
        // degrade beats a failed refresh).
      }
    }

    // Persist only on a real change: the effective state (PR state merged
    // with the CI verdict — `open` under the hood must NOT re-record every
    // tick while the stored verdict is `validating`), the verbatim error
    // lines, the run link, or the comment snapshot differs. The poller
    // runs on a timer — re-recording an unchanged publication would
    // rewrite the ledger file and notify listeners every tick for nothing.
    final changed =
        effective != publication.lastKnownState ||
        !listEquals(validatorErrors, publication.validatorErrors) ||
        runUrl != publication.runHtmlUrl ||
        (pull != null && !listEquals(comments, publication.comments));
    if (changed) {
      await _ledger.record(
        publication.copyWith(
          lastKnownState: effective,
          comments: comments,
          validatorErrors: validatorErrors,
          runHtmlUrl: runUrl,
        ),
      );
    }
    return widgetPublicationStateOf(effective);
  }

  /// The failing checks' error lines, VERBATIM (issue #1045 — "no
  /// swallowing, no aggregate-only failure"): the check-run output when
  /// the workflow writes one, else the `ERROR` lines of the Actions job
  /// log (GitHub's per-line log timestamp is presentation framing and is
  /// stripped; the error text itself is byte-for-byte).
  // ponytail: 20-line/2000-char cap is a ledger-size bound, not filtering —
  // the run link always carries the full log.
  static const _maxValidatorErrors = 20;
  static const _maxValidatorErrorLength = 2000;

  Future<List<String>> _verbatimValidatorErrors(
    GithubApiClient client,
    List<GithubCheckRun> failing,
  ) async {
    final lines = <String>[];
    for (final check in failing) {
      final fromOutput =
          check.outputText ?? check.outputSummary ?? check.outputTitle ?? '';
      if (fromOutput.isNotEmpty) {
        lines.addAll(
          fromOutput.split('\n').where((line) => line.trim().isNotEmpty),
        );
        continue;
      }
      final jobId = GithubApiClient.jobIdFromUrl(check.htmlUrl);
      if (jobId == null) continue;
      final log = await client.jobLog(
        GithubApiClient.catalogOwner,
        GithubApiClient.catalogRepo,
        jobId,
      );
      if (log == null) continue;
      final logLines = log.split('\n').map(_stripLogPrefix).toList();
      final errorLines = logLines
          .where((line) => line.toLowerCase().contains('error'))
          .toList();
      if (errorLines.isNotEmpty) {
        lines.addAll(errorLines);
        continue;
      }
      // A failure with no `error`-shaped line at all (OOM kill, silent
      // crash): keep the tail of the log verbatim — still CI's own words,
      // never a rewording (issue #1045 "no digging into CI").
      final tail = logLines.where((line) => line.trim().isNotEmpty).toList();
      lines.addAll(tail.length > 5 ? tail.sublist(tail.length - 5) : tail);
    }
    return List<String>.unmodifiable([
      for (final line in lines.take(_maxValidatorErrors))
        line.length > _maxValidatorErrorLength
            ? line.substring(0, _maxValidatorErrorLength)
            : line,
    ]);
  }

  /// Drops GitHub's leading log timestamp (`2026-09-28T07:00:00.000Z `),
  /// keeping the validator's own line verbatim.
  static String _stripLogPrefix(String line) =>
      line.replaceFirst(RegExp(r'^\d{4}-\d{2}-\d{2}T[\d:.]+Z\s+'), '');

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

  /// Maps a walked file path onto its widget-root-relative publish path,
  /// or null when the path is outside the widget folder. The env walk may
  /// report host-absolute paths (`/Users/<name>/…/apps/<id>/…`) while
  /// [JsAppInfo.dir] is the sandbox-relative `apps/<id>` — so the cut
  /// anchors on the app folder NAME, never on the app.dir prefix (a
  /// missed prefix once published a Users/… mirror of the home directory
  /// into the widget repo). The FIRST `/<id>/` occurrence wins, so a
  /// same-named directory nested inside the widget stays nested.
  static String? widgetRelativePath(JsAppInfo app, String path) {
    final marker = '/${app.id}/';
    final cut = path.indexOf(marker);
    if (cut < 0) return null;
    return path.substring(cut + marker.length);
  }

  static String _repoDescription(JsAppInfo app) =>
      'Fa widget: ${app.name} — published to the fa_widgets catalog '
      '(${_provenanceMarker(app.id)})';

  /// The bootstrap README of a freshly created widget repo (the first
  /// commit, before the widget sources land).
  static String _repoReadme(JsAppInfo app) =>
      '# Fa Widget: ${app.name}\n'
      '\n'
      'Published from the [Fa app](https://fa1.dev) to the '
      '[IstiN/fa_widgets](https://github.com/IstiN/fa_widgets) catalog.\n'
      '\n'
      'Widget id: `${app.id}`\n';

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
      final relative = widgetRelativePath(app, path);
      if (relative == null || relative.isEmpty) return;
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
}
