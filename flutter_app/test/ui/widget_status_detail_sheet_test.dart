// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/widget_publication_store.dart';
import 'package:fa/ui/widgets/widget_status_detail_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: child, bottomSheet: null));

void main() {
  // Issue #1045 AC3: the detail sheet surfaces the per-widget publish
  // status with the validator's VERBATIM error lines and the CI run link.
  testWidgets(
    'invalid publication shows verbatim validator errors + run link',
    (tester) async {
      final env = MemoryExecutionEnv();
      await initSharedWidgetPublicationStore(env);
      await sharedWidgetPublicationStore().record(
        WidgetPublication(
          widgetId: 'pomodoro',
          version: '1.2.0',
          repoFullName: 'octocat/fa-widget-pomodoro',
          repoCommit: 'abc1234',
          step: WidgetPublication.stepPrOpened,
          submittedAt: DateTime.utc(2026, 2, 1),
          prNumber: 8,
          prHtmlUrl: 'https://github.com/IstiN/fa_widgets/pull/8',
          lastKnownState: WidgetPublication.stateInvalid,
          validatorErrors: const [
            "external manifest: 'minRuntime' must be a non-empty string.",
          ],
          lastError:
              "ERROR 2048: external manifest: 'minRuntime' must be a "
              "non-empty string.",
          runHtmlUrl: 'https://github.com/IstiN/fa_widgets/actions/runs/99',
        ),
      );

      await tester.pumpWidget(
        _wrap(
          WidgetStatusDetailSheet(
            widgetId: 'pomodoro',
            title: 'Pomodoro',
            version: '1.2.0',
            description: 'Focus timer',
            env: env,
            pollInterval: const Duration(hours: 1), // no timer churn in test
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // Verbatim validator line on screen (SelectableText body).
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is SelectableText &&
              (w.data ?? '').contains(
                "external manifest: 'minRuntime' must be a non-empty string.",
              ),
        ),
        findsOneWidget,
      );
      expect(find.text('Validator errors:'), findsOneWidget);
      // The CI run link renders (URL opens externally).
      expect(find.text('Open CI run'), findsOneWidget);
    },
  );

  testWidgets('not-published widget shows a missing status chip, no errors', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    await tester.pumpWidget(
      _wrap(
        WidgetStatusDetailSheet(
          widgetId: 'fresh',
          title: 'Fresh Widget',
          env: env,
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('minRuntime'), findsNothing);
    // Widget info still rendered.
    expect(find.text('Fresh Widget'), findsOneWidget);
  });
}
