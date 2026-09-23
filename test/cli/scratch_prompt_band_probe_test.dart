// Scratch probe (review-only, to be deleted): frame row accounting when a
// TUI prompt (ask/approval dialog) is open while the band composer is
// attached — does the frame still fill the physical height?
library;

import 'package:dart_tui/dart_tui.dart';
import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/approval/approval.dart'
    show ApprovalRequest, ApprovalTier;
import 'package:flutter_agent_harness/src/cli/tui_prompt.dart'
    show ApprovalPromptSpec, TuiPromptState;
import 'package:flutter_agent_harness/src/cli/tui_status_line.dart';

import 'package:test/test.dart';

StatusLineSnapshot _snapshot() => const StatusLineSnapshot(
  cwd: '/tmp/work',
  modelName: 'm',
  approvalMode: 'yolo',
  contextTokens: 100,
  contextWindow: 1000,
  idle: true,
);

FaTuiCallbacks _callbacks() => FaTuiCallbacks(
  onSubmit: (_, {images = const []}) async {},
  onModelSelected: (_) async {},
  buildSlashMenu: (_) => const [],
  buildModelMenu: (_, _) => const [],
  statusLine: () => 'legacy footer',
  prompt: '',
  statusSnapshot: _snapshot,
  statusLineEngine: TuiStatusLine(spec: resolveStatusLineSpec(null)),
);

FaTuiModel _model({TuiPromptState? promptState, int height = 24}) {
  var m = FaTuiModel(
    callbacks: _callbacks(),
    isExited: () => false,
    termWidth: 80,
    termHeight: height,
  );
  if (promptState != null) m = m.copyWith(prompt: promptState);
  return m;
}

void main() {
  test('probe: painted rows vs termHeight with prompt open (band attached)', () {
    final state = TuiPromptState(
      ApprovalPromptSpec(
        request: ApprovalRequest(
          toolName: 'bash',
          tier: ApprovalTier.exec,
          arguments: const {'command': 'ls'},
          reason: 'test',
        ),
      ),
    );
    final m = _model(promptState: state);
    final content = m.view().content;
    final rows = content.split('\n').length;
    // ignore: avoid_print
    print('band+prompt painted rows=$rows termHeight=24');
    expect(rows, lessThanOrEqualTo(24));
  });

  test('probe: painted rows vs termHeight no prompt (band frame)', () {
    final m = _model();
    final rows = m.view().content.split('\n').length;
    // ignore: avoid_print
    print('band rows=$rows termHeight=24');
    expect(rows, lessThanOrEqualTo(24));
  });
}
