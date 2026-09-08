// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/apps_store.dart';
import 'package:fa/services/widget_publication_store.dart';
import 'package:fa/services/widget_publish_service.dart';
import 'package:fa/ui/widgets/widget_publications_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Counts refreshStatus calls and scripts their outcome — the sheet's only
/// service touchpoint.
class _FakePublishService implements WidgetPublishService {
  _FakePublishService({this.fail = false});

  bool fail;
  var calls = 0;

  @override
  Future<WidgetPublicationState> refreshStatus(
    WidgetPublication publication,
  ) async {
    calls++;
    if (fail) throw StateError('offline');
    return WidgetPublicationState.open;
  }

  @override
  Future<List<WidgetPreflightIssue>> preflight(JsAppInfo app) async => const [];

  @override
  Future<WidgetPublishResult> publish({
    required JsAppInfo app,
    String? repoName,
  }) => throw UnimplementedError();
}

Future<void> _pump(WidgetTester tester, WidgetPublicationsSheet sheet) => tester
    .pumpWidget(MaterialApp(home: Scaffold(body: sheet, bottomSheet: null)));

WidgetPublication _publication() => WidgetPublication(
  widgetId: 'pomodoro',
  version: '1.0.0',
  repoFullName: 'octocat/fa-widget-pomodoro',
  repoCommit: 'a1b2c3d4',
  step: WidgetPublication.stepPrOpened,
  submittedAt: DateTime.utc(2026, 2, 1, 12),
  prNumber: 12,
  prHtmlUrl: 'https://github.com/IstiN/fa_widgets/pull/12',
);

void main() {
  testWidgets('polls on the injected interval while the sheet is open', (
    tester,
  ) async {
    final service = _FakePublishService();
    final ledger = WidgetPublicationStore.inMemory();
    await ledger.record(_publication());
    await _pump(
      tester,
      WidgetPublicationsSheet(
        ledger: ledger,
        service: service,
        pollInterval: const Duration(minutes: 5),
      ),
    );
    expect(service.calls, 0);

    await tester.pump(const Duration(minutes: 5));
    await tester.pump(const Duration(milliseconds: 100));
    expect(service.calls, 1);

    await tester.pump(const Duration(minutes: 5));
    await tester.pump(const Duration(milliseconds: 100));
    expect(service.calls, 2);
  });

  testWidgets('refreshes when the app resumes to the foreground', (
    tester,
  ) async {
    final service = _FakePublishService();
    final ledger = WidgetPublicationStore.inMemory();
    await ledger.record(_publication());
    await _pump(
      tester,
      WidgetPublicationsSheet(
        ledger: ledger,
        service: service,
        pollInterval: const Duration(hours: 1),
      ),
    );
    expect(service.calls, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 100));
    expect(service.calls, 1);
  });

  testWidgets('no polling without a service (read-only projection)', (
    tester,
  ) async {
    final ledger = WidgetPublicationStore.inMemory();
    await ledger.record(_publication());
    await _pump(tester, WidgetPublicationsSheet(ledger: ledger));
    await tester.pump(const Duration(hours: 1));
    // Reaching here without a pending-timer failure proves the timer only
    // exists with a service.
    expect(find.byIcon(Icons.refresh), findsNothing);
  });

  testWidgets('offline hint appears when every refresh fails, clears on '
      'success', (tester) async {
    final ledger = WidgetPublicationStore.inMemory();
    await ledger.record(_publication());
    // One mutable fake: the SAME sheet instance runs failing -> reaching
    // cycles, so the hint's true -> false transition is the real one.
    final service = _FakePublishService(fail: true);
    await _pump(
      tester,
      WidgetPublicationsSheet(ledger: ledger, service: service),
    );

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.wifi_off), findsOneWidget);
    expect(find.text('Offline — showing last known states.'), findsOneWidget);

    service.fail = false;
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.wifi_off), findsNothing);
  });

  testWidgets('PR-less records are skipped: never reached, never failed', (
    tester,
  ) async {
    final ledger = WidgetPublicationStore.inMemory();
    // stepRepoPushed record without a PR: nothing to poll yet.
    await ledger.record(
      WidgetPublication(
        widgetId: 'early',
        version: '0.1.0',
        repoFullName: 'octocat/fa-widget-early',
        repoCommit: 'deadbeef',
        step: WidgetPublication.stepRepoPushed,
        submittedAt: DateTime.utc(2026, 2, 1, 12),
      ),
    );
    final failing = _FakePublishService(fail: true);
    await _pump(
      tester,
      WidgetPublicationsSheet(ledger: ledger, service: failing),
    );

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump(const Duration(milliseconds: 100));
    expect(failing.calls, 0);
    expect(find.byIcon(Icons.wifi_off), findsNothing);
  });

  testWidgets('pull-to-refresh refreshes every submission', (tester) async {
    final service = _FakePublishService();
    final ledger = WidgetPublicationStore.inMemory();
    await ledger.record(_publication());
    await _pump(
      tester,
      WidgetPublicationsSheet(
        ledger: ledger,
        service: service,
        pollInterval: const Duration(hours: 1),
      ),
    );
    expect(service.calls, 0);

    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(service.calls, 1);
  });
}
