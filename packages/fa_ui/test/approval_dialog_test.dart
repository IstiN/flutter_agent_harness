// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// A listenable [FaApprovalModeController] around a real [ApprovalManager]:
/// mirrors what [FaChatService] carries so the yolo checkbox and the mode
/// selector run against the production manager state.
final class _ModeController extends ChangeNotifier
    implements FaApprovalModeController {
  _ModeController(ApprovalMode initial) {
    manager.mode = initial;
  }

  final manager = ApprovalManager();

  @override
  ApprovalManager get approval => manager;

  @override
  void setApprovalMode(ApprovalMode mode) {
    manager.mode = mode;
    notifyListeners();
  }
}

/// The prompt under test: a shell tool call in always-ask mode.
const _request = ApprovalRequest(
  toolName: 'bash',
  tier: ApprovalTier.exec,
  arguments: {'command': 'ls -la'},
  reason: 'always-ask mode prompts for every call',
);

void main() {
  /// Pumps a one-button host page whose tap opens the dialog and records
  /// the resolved [ApprovalDecision].
  Future<void> pumpPrompt(
    WidgetTester tester, {
    ApprovalRequest request = _request,
    FaApprovalModeController? modeController,
    required ValueChanged<ApprovalDecision> onDecision,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () async => onDecision(
                  await showApprovalPrompt(
                    context,
                    request,
                    modeController: modeController,
                  ),
                ),
                child: const Text('ask'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Opens the dialog via the host button.
  Future<void> openDialog(WidgetTester tester) async {
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();
  }

  testWidgets('the three buttons pop their decisions', (tester) async {
    final decisions = <ApprovalDecision>[];
    for (final (label, expected) in const [
      ('Deny', ApprovalDecision.deny),
      ('Allow once', ApprovalDecision.approveOnce),
      ('Always allow', ApprovalDecision.approveAlways),
    ]) {
      await pumpPrompt(tester, onDecision: decisions.add);
      await openDialog(tester);
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(decisions, [expected], reason: label);
      expect(find.byType(ApprovalDialog), findsNothing, reason: label);
      decisions.clear();
    }
  });

  testWidgets('dismissing the dialog (barrier tap) maps to deny — an '
      'unanswered prompt must never allow a call', (tester) async {
    ApprovalDecision? decision;
    await pumpPrompt(tester, onDecision: (d) => decision = d);
    await openDialog(tester);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(decision, ApprovalDecision.deny);
  });

  testWidgets('the request surfaces the tool name, tier, reason and '
      'arguments', (tester) async {
    await pumpPrompt(tester, onDecision: (_) {});
    await openDialog(tester);
    expect(find.text('Allow bash?'), findsOneWidget);
    expect(find.text('always-ask mode prompts for every call'), findsOneWidget);
    expect(find.text('Tier: exec'), findsOneWidget);
    expect(find.textContaining('ls -la'), findsOneWidget);
  });

  testWidgets('oversized arguments truncate at the 800-char cap', (
    tester,
  ) async {
    final big = ApprovalRequest(
      toolName: 'write',
      tier: ApprovalTier.write,
      arguments: {'content': 'x' * 2000},
      reason: 'write tier',
    );
    await pumpPrompt(tester, request: big, onDecision: (_) {});
    await openDialog(tester);
    final cell = tester.widget<Text>(find.textContaining('"content"').first);
    final rendered = cell.data!;
    expect(rendered.length, 801, reason: '800 chars + the ellipsis');
    expect(rendered.endsWith('…'), isTrue);
  });

  testWidgets('non-JSON-encodable arguments fall back to toString', (
    tester,
  ) async {
    final weird = ApprovalRequest(
      toolName: 'bash',
      tier: ApprovalTier.exec,
      // DateTime has no JSON encoding — the JsonEncoder throws.
      arguments: {'when': DateTime(2026, 10, 25)},
      reason: 'always-ask',
    );
    await pumpPrompt(tester, request: weird, onDecision: (_) {});
    await openDialog(tester);
    expect(find.textContaining('2026-10-25'), findsOneWidget);
  });

  testWidgets('no mode controller hides the yolo checkbox', (tester) async {
    await pumpPrompt(tester, onDecision: (_) {});
    await openDialog(tester);
    expect(find.byType(CheckboxListTile), findsNothing);
  });

  testWidgets('the yolo checkbox switches the session to yolo and back to '
      'the mode the dialog opened with', (tester) async {
    final controller = _ModeController(ApprovalMode.write);
    await pumpPrompt(tester, modeController: controller, onDecision: (_) {});
    await openDialog(tester);

    final checkbox = find.byType(CheckboxListTile);
    expect(controller.manager.mode, ApprovalMode.write);
    expect(
      tester.widget<CheckboxListTile>(checkbox).value,
      isFalse,
      reason: 'write mode is not yolo',
    );

    await tester.tap(find.text('YOLO mode — allow everything'));
    await tester.pumpAndSettle();
    expect(controller.manager.mode, ApprovalMode.yolo);
    expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);

    await tester.tap(find.text('YOLO mode — allow everything'));
    await tester.pumpAndSettle();
    expect(controller.manager.mode, ApprovalMode.write);
    expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
  });

  testWidgets('a dialog opened in yolo starts with the checkbox checked', (
    tester,
  ) async {
    final controller = _ModeController(ApprovalMode.yolo);
    await pumpPrompt(tester, modeController: controller, onDecision: (_) {});
    await openDialog(tester);
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isTrue,
    );
  });

  testWidgets('the mode selector renders the four segments and their '
      'hints live', (tester) async {
    final controller = _ModeController(ApprovalMode.alwaysAsk);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ApprovalModeSelector(service: controller)),
      ),
    );
    await tester.pumpAndSettle();

    final segments = tester.widget<SegmentedButton<ApprovalMode>>(
      find.byType(SegmentedButton<ApprovalMode>),
    );
    expect(segments.selected, {ApprovalMode.alwaysAsk});
    expect(find.text('Every tool call asks for approval.'), findsOneWidget);

    // alwaysAsk → yolo: the manager updates and the hint follows.
    await tester.tap(find.text('YOLO'));
    await tester.pumpAndSettle();
    expect(controller.manager.mode, ApprovalMode.yolo);
    expect(
      tester
          .widget<SegmentedButton<ApprovalMode>>(
            find.byType(SegmentedButton<ApprovalMode>),
          )
          .selected,
      {ApprovalMode.yolo},
    );
  });

  for (final (mode, hint) in const [
    (ApprovalMode.alwaysAsk, 'Every tool call asks for approval.'),
    (
      ApprovalMode.write,
      'File reads run freely; writes, edits and shell commands ask for approval.',
    ),
    (
      ApprovalMode.yolo,
      'All tools run without asking (destructive shell commands still ask).',
    ),
    // Unattended shares the yolo hint — there is nobody to ask either way.
    (
      ApprovalMode.unattended,
      'All tools run without asking (destructive shell commands still ask).',
    ),
  ]) {
    testWidgets('the selector hint arm for ${mode.name}', (tester) async {
      final controller = _ModeController(mode);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ApprovalModeSelector(service: controller)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SegmentedButton<ApprovalMode>>(
              find.byType(SegmentedButton<ApprovalMode>),
            )
            .selected,
        {mode},
      );
      expect(find.text(hint), findsOneWidget);
    });
  }
}
