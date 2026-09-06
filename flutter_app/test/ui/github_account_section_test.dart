// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/github_account_store.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/widget_publication_store.dart';
import 'package:fa/ui/widgets/github_account_section.dart';
import 'package:fa/ui/widgets/widget_publications_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

void main() {
  group('GithubAccountSection', () {
    testWidgets('disconnected: hint + connect button', (tester) async {
      final store = GithubAccountStore(keys: SessionKeysStore.inMemory());
      await _pump(tester, GithubAccountSection(store: store));

      expect(find.text('GitHub account'), findsOneWidget);
      expect(
        find.text(
          'Connect GitHub to publish your widgets to the fa_widgets catalog.',
        ),
        findsOneWidget,
      );
      expect(find.text('Connect GitHub'), findsOneWidget);
      expect(find.text('Disconnect'), findsNothing);
      expect(find.text('My publications'), findsNothing);
    });

    testWidgets('connected: login + disconnect + my publications', (
      tester,
    ) async {
      final store = GithubAccountStore(keys: SessionKeysStore.inMemory());
      await store.connect(token: 't', login: 'octocat');
      await _pump(tester, GithubAccountSection(store: store));

      expect(find.text('octocat'), findsOneWidget);
      expect(find.text('Disconnect'), findsOneWidget);
      expect(find.text('My publications'), findsOneWidget);
      expect(find.text('Connect GitHub'), findsNothing);
    });

    testWidgets('disconnect asks for confirmation and drops the account', (
      tester,
    ) async {
      final store = GithubAccountStore(keys: SessionKeysStore.inMemory());
      await store.connect(token: 't', login: 'octocat');
      await _pump(tester, GithubAccountSection(store: store));

      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'PRs already opened stay on GitHub — only status polling stops.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Disconnect'));
      await tester.pumpAndSettle();
      expect(store.isConnected, isFalse);
      expect(find.text('Connect GitHub'), findsOneWidget);
    });

    testWidgets('my publications opens the publications sheet', (tester) async {
      final store = GithubAccountStore(keys: SessionKeysStore.inMemory());
      await store.connect(token: 't', login: 'octocat');
      final ledger = WidgetPublicationStore.inMemory();
      await _pump(tester, GithubAccountSection(store: store, ledger: ledger));

      await tester.tap(find.text('My publications'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing published yet.'), findsOneWidget);
    });
  });

  group('WidgetPublicationsSheet', () {
    WidgetPublication publication(
      String widgetId,
      int prNumber,
      WidgetPublicationState state,
    ) {
      const stateNames = {
        WidgetPublicationState.open: 'open',
        WidgetPublicationState.published: 'merged',
        WidgetPublicationState.rejected: 'closed',
        WidgetPublicationState.unknown: 'unknown',
      };
      return WidgetPublication(
        widgetId: widgetId,
        version: '1.0.0',
        repoFullName: 'octocat/fa-widget-$widgetId',
        repoCommit: 'a' * 40,
        step: WidgetPublication.stepPrOpened,
        prNumber: prNumber,
        prHtmlUrl: 'https://github.com/IstiN/fa_widgets/pull/$prNumber',
        submittedAt: DateTime.utc(2026, 8, 30),
        lastKnownState: stateNames[state]!,
      );
    }

    Future<void> pumpSheet(WidgetTester tester, WidgetPublicationStore ledger) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () =>
                    showWidgetPublicationsSheet(context, ledger: ledger),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('renders every ledger entry with its state chip', (
      tester,
    ) async {
      final ledger = WidgetPublicationStore.inMemory()
        ..record(publication('pomodoro', 12, WidgetPublicationState.open))
        ..record(publication('clock', 9, WidgetPublicationState.published))
        ..record(publication('notes', 7, WidgetPublicationState.rejected))
        ..record(publication('draft', 5, WidgetPublicationState.unknown));
      await pumpSheet(tester, ledger);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('My publications'), findsOneWidget);
      expect(find.text('pomodoro'), findsOneWidget);
      expect(find.text('octocat/fa-widget-pomodoro · PR #12'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Published'), findsOneWidget);
      expect(find.text('Rejected'), findsOneWidget);
      expect(find.text('Unknown'), findsOneWidget);
      expect(find.text('Submitted 2026-08-30'), findsNWidgets(4));
    });

    testWidgets('empty ledger shows the empty state', (tester) async {
      final ledger = WidgetPublicationStore.inMemory();
      await pumpSheet(tester, ledger);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Nothing published yet.'), findsOneWidget);
    });

    testWidgets('read-only without a service: no refresh button', (
      tester,
    ) async {
      final ledger = WidgetPublicationStore.inMemory()
        ..record(publication('pomodoro', 12, WidgetPublicationState.open));
      await pumpSheet(tester, ledger);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.refresh), findsNothing);
    });
  });
}
