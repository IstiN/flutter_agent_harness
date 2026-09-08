// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/services/github_account_store.dart';
import 'package:fa/services/github_api_client.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/widget_publication_store.dart';
import 'package:fa/ui/widgets/widget_publication_resume_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The scripted catalog PR the fake transport serves; every request is
/// counted so "no network" assertions are byte-level.
class _CountingGithub {
  /// Requests that fetched the PR state — exactly one per refresh cycle
  /// (the comment snapshot rides the same cycle over two endpoints).
  var prFetches = 0;

  http.Client client() => MockClient((request) async {
    final path = request.url.path;
    if (path == '/repos/IstiN/fa_widgets/pulls/12') {
      prFetches++;
      return http.Response(
        jsonEncode({
          'number': 12,
          'state': 'open',
          'title': 'Add widget pomodoro 1.0.0',
          'html_url': 'https://github.com/IstiN/fa_widgets/pull/12',
        }),
        200,
      );
    }
    if (path.endsWith('/comments')) {
      return http.Response('[]', 200);
    }
    return http.Response('{}', 404);
  });
}

WidgetPublication _prPublication() => WidgetPublication(
  widgetId: 'pomodoro',
  version: '1.0.0',
  repoFullName: 'octocat/fa-widget-pomodoro',
  repoCommit: 'a' * 40,
  step: WidgetPublication.stepPrOpened,
  submittedAt: DateTime.utc(2026, 9, 8, 12),
  prNumber: 12,
  prHtmlUrl: 'https://github.com/IstiN/fa_widgets/pull/12',
);

Future<WidgetPublicationStore> _ledgerWithPr() async {
  final ledger = WidgetPublicationStore.inMemory();
  await ledger.record(_prPublication());
  return ledger;
}

Future<GithubAccountStore> _account(
  SessionKeysStore keys, {
  String? token,
}) async {
  final store = GithubAccountStore(keys: keys);
  if (token != null) {
    await store.connect(token: token, login: 'octocat');
  }
  return store;
}

/// Pumps the refresher the way the app mounts it (inside the session-keys
/// scope, wrapping the home) and fires one paused → resumed round trip.
Future<void> _pumpAndResume(
  WidgetTester tester, {
  required GithubAccountStore store,
  required SessionKeysStore keys,
  WidgetPublicationStore? ledger,
  ExecutionEnv? env,
  DateTime Function()? clock,
  _CountingGithub? github,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SessionKeysScope(
        store: keys,
        child: WidgetPublicationResumeRefresher(
          env: env,
          ledger: ledger,
          store: store,
          clock: clock,
          clientFactory: (token) =>
              GithubApiClient(token: token, httpClient: github!.client()),
          child: const SizedBox(),
        ),
      ),
    ),
  );
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  await tester.pump();
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('resume with the sheet closed refreshes PR states', (
    tester,
  ) async {
    final github = _CountingGithub();
    final keys = SessionKeysStore.inMemory();
    final ledger = await _ledgerWithPr();

    await _pumpAndResume(
      tester,
      store: await _account(keys, token: 't'),
      keys: keys,
      ledger: ledger,
      env: MemoryExecutionEnv(),
      github: github,
    );

    // PR state fetch + (empty) comment snapshot — a real cycle ran.
    expect(github.prFetches, 1);
    expect(ledger.byWidgetId('pomodoro')!.lastKnownState, 'open');
  });

  testWidgets('throttled to one cycle per poll interval', (tester) async {
    final github = _CountingGithub();
    final keys = SessionKeysStore.inMemory();
    final ledger = await _ledgerWithPr();
    var now = DateTime.utc(2026, 9, 8, 12);

    Future<void> resumeAt(Duration after) async {
      now = now.add(after);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tester.pumpWidget(
      MaterialApp(
        home: SessionKeysScope(
          store: keys,
          child: WidgetPublicationResumeRefresher(
            env: MemoryExecutionEnv(),
            ledger: ledger,
            store: await _account(keys, token: 't'),
            child: const SizedBox(),
            clock: () => now,
            clientFactory: (token) =>
                GithubApiClient(token: token, httpClient: github.client()),
          ),
        ),
      ),
    );
    await resumeAt(const Duration(minutes: 1));
    expect(github.prFetches, 1);
    // 4 minutes later: still inside the 5-minute window — skipped.
    await resumeAt(const Duration(minutes: 4));
    expect(github.prFetches, 1);
    // Beyond the window: the next cycle runs.
    await resumeAt(const Duration(minutes: 2));
    expect(github.prFetches, 2);
  });

  testWidgets('disconnected account: no network on resume', (tester) async {
    final github = _CountingGithub();
    final keys = SessionKeysStore.inMemory();
    final ledger = await _ledgerWithPr();

    await _pumpAndResume(
      tester,
      store: await _account(keys),
      keys: keys,
      ledger: ledger,
      env: MemoryExecutionEnv(),
      github: github,
    );

    expect(github.prFetches, 0);
  });

  testWidgets('no PR-bearing records: no network on resume', (tester) async {
    final github = _CountingGithub();
    final keys = SessionKeysStore.inMemory();
    final ledger = WidgetPublicationStore.inMemory();
    await ledger.record(
      WidgetPublication(
        widgetId: 'early',
        version: '0.1.0',
        repoFullName: 'octocat/fa-widget-early',
        repoCommit: 'deadbeef',
        step: WidgetPublication.stepRepoPushed,
        submittedAt: DateTime.utc(2026, 9, 8, 12),
      ),
    );

    await _pumpAndResume(
      tester,
      store: await _account(keys, token: 't'),
      keys: keys,
      ledger: ledger,
      env: MemoryExecutionEnv(),
      github: github,
    );

    expect(github.prFetches, 0);
  });

  testWidgets('without an env the observer is not installed', (tester) async {
    final github = _CountingGithub();
    final keys = SessionKeysStore.inMemory();
    final ledger = await _ledgerWithPr();

    await _pumpAndResume(
      tester,
      store: await _account(keys, token: 't'),
      keys: keys,
      ledger: ledger,
      github: github,
    );

    expect(github.prFetches, 0);
  });
}
