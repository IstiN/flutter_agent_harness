// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/services/github_account_store.dart';
import 'package:fa/services/github_api_client.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/widget_publication_store.dart';
import 'package:fa/services/widget_publish_service.dart';
import 'package:fa/ui/widgets/widget_publish_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scripts the sheet's service touchpoints: preflight blockers, the
/// publish outcome, and counts the publish calls.
class _FakePublishService implements WidgetPublishService {
  _FakePublishService({this.issues = const []});

  /// Preflight blockers returned by [preflight].
  final List<WidgetPreflightIssue> issues;

  /// Publish behavior: a result to complete with, or an object to throw.
  Object? outcome;

  var publishCalls = 0;

  @override
  Future<List<WidgetPreflightIssue>> preflight(JsAppInfo app) async => issues;

  @override
  Future<WidgetPublishResult> publish({
    required JsAppInfo app,
    String? repoName,
  }) async {
    publishCalls++;
    final outcome = this.outcome;
    if (outcome != null) throw outcome;
    return WidgetPublishResult(publication: _publication(), reusedPr: false);
  }

  @override
  Future<WidgetPublicationState> refreshStatus(
    WidgetPublication publication,
  ) async => WidgetPublicationState.open;
}

WidgetPublication _publication() => WidgetPublication(
  widgetId: 'demo',
  version: '1.0.0',
  repoFullName: 'octocat/fa-widget-demo',
  repoCommit: 'a1b2c3d4',
  step: WidgetPublication.stepPrOpened,
  submittedAt: DateTime.utc(2026, 2, 1, 12),
  prNumber: 12,
  prHtmlUrl: 'https://github.com/octocat/fa_widgets/pull/12',
);

JsAppInfo _app() => JsAppInfo.fromManifest(
  const {
    'id': 'demo',
    'name': 'Demo',
    'description': 'd',
    'version': '1.0.0',
  },
  bundled: false,
  fallbackId: 'demo',
);

Future<void> _pump(
  WidgetTester tester,
  WidgetPublishSheet sheet,
) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: sheet)));
  // The preflight hop completes on real async.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  late GithubAccountStore account;
  late WidgetPublicationStore ledger;

  setUp(() async {
    account = GithubAccountStore(keys: SessionKeysStore.inMemory());
    ledger = WidgetPublicationStore.inMemory();
  });

  testWidgets('a disconnected account offers Connect, not publish', (
    tester,
  ) async {
    await _pump(
      tester,
      WidgetPublishSheet(
        app: _app(),
        account: account,
        service: _FakePublishService(),
        ledger: ledger,
      ),
    );

    expect(find.text('Connect GitHub'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('preflight blockers keep the publish button disabled', (
    tester,
  ) async {
    await account.connect(token: 'gho_t', login: 'octocat');
    await _pump(
      tester,
      WidgetPublishSheet(
        app: _app(),
        account: account,
        service: _FakePublishService(
          issues: const [WidgetPreflightIssue('empty', 'no source')],
        ),
        ledger: ledger,
      ),
    );

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Publish'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('an empty repo name keeps the publish button disabled', (
    tester,
  ) async {
    await account.connect(token: 'gho_t', login: 'octocat');
    await _pump(
      tester,
      WidgetPublishSheet(
        app: _app(),
        account: account,
        service: _FakePublishService(),
        ledger: ledger,
      ),
    );

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Publish'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('a clean preflight publishes and shows the PR link', (
    tester,
  ) async {
    await account.connect(token: 'gho_t', login: 'octocat');
    final service = _FakePublishService();
    await _pump(
      tester,
      WidgetPublishSheet(
        app: _app(),
        account: account,
        service: service,
        ledger: ledger,
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Publish'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(service.publishCalls, 1);
    expect(find.text('Publishing…'), findsNothing);
    expect(find.text('https://github.com/octocat/fa_widgets/pull/12'),
        findsOneWidget);
  });

  testWidgets('a GitHub API failure lands back on the form with the message', (
    tester,
  ) async {
    await account.connect(token: 'gho_t', login: 'octocat');
    final service = _FakePublishService()
      ..outcome = const GithubApiException(422, 'name already exists');
    await _pump(
      tester,
      WidgetPublishSheet(
        app: _app(),
        account: account,
        service: service,
        ledger: ledger,
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Publish'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('name already exists'), findsOneWidget);
    // The form is usable again: publish re-arms.
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Publish'),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('an unexpected failure surfaces its string form', (
    tester,
  ) async {
    await account.connect(token: 'gho_t', login: 'octocat');
    final service = _FakePublishService()
      ..outcome = StateError('offline');
    await _pump(
      tester,
      WidgetPublishSheet(
        app: _app(),
        account: account,
        service: service,
        ledger: ledger,
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Publish'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('Bad state: offline'), findsOneWidget);
  });

  testWidgets('the publish button shows progress and locks while in flight', (
    tester,
  ) async {
    await account.connect(token: 'gho_t', login: 'octocat');
    final service = _FakePublishService();
    final completer = Completer<WidgetPublishResult>();
    service.outcome = null;
    // Hang the publish until the test releases it.
    final hung = _HungService(service, completer);
    await _pump(
      tester,
      WidgetPublishSheet(
        app: _app(),
        account: account,
        service: hung,
        ledger: ledger,
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Publish'));
    await tester.pump();

    expect(find.text('Publishing…'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Publishing…'))
          .onPressed,
      isNull,
    );

    completer.complete(
      WidgetPublishResult(publication: _publication(), reusedPr: false),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.text('https://github.com/octocat/fa_widgets/pull/12'),
      findsOneWidget,
    );
  });
}

class _HungService extends _FakePublishService {
  _HungService(this.delegate, this.completer);

  final _FakePublishService delegate;
  final Completer<WidgetPublishResult> completer;

  @override
  Future<List<WidgetPreflightIssue>> preflight(JsAppInfo app) =>
      delegate.preflight(app);

  @override
  Future<WidgetPublishResult> publish({
    required JsAppInfo app,
    String? repoName,
  }) => completer.future;
}
