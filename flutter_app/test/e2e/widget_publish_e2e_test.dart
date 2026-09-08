// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Issue #35 E2E-1 + AC12 — the REAL-GitHub publish verification.
///
/// Runs the production publish pipeline (WidgetPublishService over the
/// real GithubApiClient) end to end: it creates a scratch widget repo
/// under the token account, forks IstiN/fa_widgets, pins the gitlink and
/// opens (or reuses) the catalog PR. Re-runs are idempotent (the AC6
/// reuse path) — the same PR is found again instead of duplicating.
///
/// Token-scoped like every real E2E: it self-skips unless launched with
///
/// ```sh
/// cd flutter_app && flutter test test/e2e/widget_publish_e2e_test.dart \
///   --dart-define=FA_E2E_GITHUB_TOKEN=<token with public_repo>
/// ```
///
/// The token is read from the dart-define only — it is never written to
/// any file, log, or ledger (the AC9 invariant applies to this test too).
/// The second test verifies AC12 once the catalog PR is merged: the
/// rolling-release `catalog.json` must list the widget and the production
/// CatalogService download path must serve its sources.
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/catalog_service.dart';
import 'package:fa/services/github_account_store.dart';
import 'package:fa/services/github_api_client.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/widget_publication_store.dart';
import 'package:fa/services/widget_publish_service.dart';
import 'package:flutter_agent_harness/io.dart' show LocalExecutionEnv;
import 'package:flutter_test/flutter_test.dart';

const _token = String.fromEnvironment('FA_E2E_GITHUB_TOKEN');

/// The scratch widget this E2E publishes — clearly named so the catalog
/// PR is recognizable as the issue #35 verification PR.
const _widgetId = 'e2e-scratch';
const _widgetVersion = '1.0.0';

Future<(WidgetPublishService, WidgetPublicationStore, Directory)> _setupWorld(
  String login,
) async {
  final tempDir = await Directory.systemTemp.createTemp('fa_e2e_publish_');
  final env = LocalExecutionEnv(cwd: tempDir.path);
  final manifest = jsonEncode({
    'id': _widgetId,
    'name': 'E2E Scratch',
    'description':
        'Issue #35 E2E-1 verification widget — safe to close or '
        'keep; sources live in the publisher repo this PR pins.',
    'version': _widgetVersion,
    'icon': '🧪',
    'tags': ['e2e'],
    'minRuntime': '0.4.79',
  });
  await env
      .writeFile('apps/$_widgetId/manifest.json', manifest)
      .then((r) => r.getOrThrow());
  await env
      .writeFile(
        'apps/$_widgetId/widget.js',
        'export function render(container) {\n'
            '  container.innerHTML = '
            "'<p>E2E scratch widget (issue #35 verification)</p>';\n"
            '}\n',
      )
      .then((r) => r.getOrThrow());
  await env
      .writeFile(
        'apps/$_widgetId/icon.svg',
        '<svg xmlns="http://www.w3.org/'
            '2000/svg" width="16" height="16"><rect width="16" height="16"/></'
            'svg>\n',
      )
      .then((r) => r.getOrThrow());

  final account = GithubAccountStore(keys: SessionKeysStore.inMemory());
  await account.connect(token: _token, login: login);
  final ledger = WidgetPublicationStore.inMemory();
  final service = WidgetPublishService(
    env: env,
    account: account,
    ledger: ledger,
  );
  return (service, ledger, tempDir);
}

void main() {
  test('E2E-1: real publish lands a visible catalog PR', () async {
    if (_token.isEmpty) {
      // ignore: avoid_print
      print('SKIPPED: needs --dart-define=FA_E2E_GITHUB_TOKEN=<token>');
      return;
    }
    final client = GithubApiClient(token: _token);
    final login = (await client.getUser()).login;
    final (service, ledger, tempDir) = await _setupWorld(login);
    addTearDown(() => tempDir.delete(recursive: true));

    final app = JsAppInfo(
      id: _widgetId,
      name: 'E2E Scratch',
      description: 'Issue #35 E2E-1 verification widget.',
      icon: '🧪',
      version: _widgetVersion,
      declaredPermissions: const AppPermissions(),
    );

    // The full pipeline: repo → sources → fork → gitlink+overlay → PR.
    final result = await service.publish(app: app);
    expect(result.prNumber, greaterThan(0));
    expect(result.prUrl, contains('github.com/IstiN/fa_widgets/pull/'));
    expect(result.publication.repoFullName, '$login/fa-widget-$_widgetId');
    expect(result.publication.step, WidgetPublication.stepPrOpened);

    // AC4 evidence: the user repo exists, is public, carries the
    // provenance marker, and its main head IS the commit the ledger
    // recorded (byte-for-byte packaging itself is UT-1's job).
    final client2 = GithubApiClient(token: _token);
    final repo = await client2.getRepo(login, 'fa-widget-$_widgetId');
    expect(repo, isNotNull);
    expect(repo!.isPrivate, isFalse);
    expect(repo.description, contains('fa-widget:$_widgetId'));
    final headSha = await client2.getHeadSha(
      login,
      'fa-widget-$_widgetId',
      'main',
    );
    expect(headSha, result.publication.repoCommit);

    // Live status polling against the real API (AC7 transport path).
    final state = await service.refreshStatus(result.publication);
    // ignore: avoid_print
    print(
      'publish OK: PR #${result.prNumber} state=$state '
      'reused=${result.reusedPr} ${result.prUrl}',
    );

    // AC6 against the real API: re-publishing must reuse the open PR,
    // never open a duplicate.
    final republish = await service.publish(app: app);
    expect(republish.prNumber, result.prNumber);
    expect(republish.reusedPr, isTrue);
    // ignore: avoid_print
    print('re-publish OK: reused PR #${republish.prNumber}');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('AC12: merged widget reaches the rolling-release catalog', () async {
    if (_token.isEmpty) {
      // ignore: avoid_print
      print('SKIPPED: needs --dart-define=FA_E2E_GITHUB_TOKEN=<token>');
      return;
    }
    final client = GithubApiClient(token: _token);
    final login = (await client.getUser()).login;
    final (service, ledger, tempDir) = await _setupWorld(login);
    addTearDown(() => tempDir.delete(recursive: true));

    final publication = ledger.byWidgetId(_widgetId);
    if (publication?.prNumber == null) {
      // Never published on this machine: run the E2E-1 test first (it
      // seeds the ledger) or accept this run as publish-only.
      final result = await service.publish(
        app: JsAppInfo(
          id: _widgetId,
          name: 'E2E Scratch',
          description: 'Issue #35 E2E-1 verification widget.',
          icon: '🧪',
          version: _widgetVersion,
          declaredPermissions: const AppPermissions(),
        ),
      );
      // ignore: avoid_print
      print('seeded publish: PR #${result.prNumber}');
    }
    final record = ledger.byWidgetId(_widgetId)!;
    final state = await service.refreshStatus(record);

    if (state != WidgetPublicationState.published) {
      // ignore: avoid_print
      print(
        'AC12 PENDING: PR #${record.prNumber} is not merged yet '
        '(state=$state). Re-run after the maintainer merges — '
        '${record.prHtmlUrl}',
      );
      return;
    }

    // Merged: the rolling release must carry the widget through the
    // production consumer path (fetch catalog → download sources).
    final boardEnv = LocalExecutionEnv(
      cwd: (await Directory.systemTemp.createTemp('fa_e2e_board_')).path,
    );
    addTearDown(() async => Directory(boardEnv.cwd).delete(recursive: true));
    final catalog = CatalogService(boardEnv);
    final snapshot = await catalog.fetchCatalog(force: true);
    final entry = snapshot.entries
        .where((e) => e.id == _widgetId)
        .toList(growable: false);
    expect(
      entry,
      isNotEmpty,
      reason:
          'merged widget missing from the '
          'rolling-release catalog.json',
    );
    final files = await catalog.downloadWidget(entry.single);
    expect(files.containsKey('manifest.json'), isTrue);
    // ignore: avoid_print
    print(
      'AC12 OK: ${entry.single.id} ${entry.single.version} in the rolling '
      'release; download served ${files.length} files '
      '(board auto-update path verified).',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
