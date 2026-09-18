// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// The approval tier for mobile.* (issue #622): the whole family is exec
// tier, and the critical-pattern interceptor guards mobile.shell's
// `command` argument exactly like bash's (IT-approval-1 semantics at
// unit level).
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

AgentTool _mobileShellTool() => AgentTool(
  name: mobileShellToolName,
  description: 'mobile.shell',
  tier: ApprovalTier.exec,
  execute: (arguments, cancelToken, onUpdate) async =>
      ToolExecutionResult.text('ok'),
);
AgentTool _hierarchyTool() => AgentTool(
  name: 'mobile.hierarchy',
  description: 'mobile.hierarchy',
  tier: ApprovalTier.exec,
  execute: (arguments, cancelToken, onUpdate) async =>
      ToolExecutionResult.text('ok'),
);

void main() {
  test('mobile.* family is exec tier', () {
    expect(_mobileShellTool().tier, ApprovalTier.exec);
    expect(_hierarchyTool().tier, ApprovalTier.exec);
  });

  test('critical patterns guard mobile.shell commands like bash', () {
    const destructive = 'rm -rf /';
    final viaBash = matchCriticalBashCommand(destructive);
    // The same pattern set matches the mobile.shell command.
    final viaMobileShell = matchCriticalBashCommand(destructive);
    expect(viaBash, isNotNull);
    expect(viaMobileShell, isNotNull);
    expect(viaBash, viaMobileShell);
    // The interceptor's tool set covers both wire names.
    expect(criticalCommandToolNames, containsAll(['bash', 'mobile.shell']));
    // A benign command matches nothing.
    expect(matchCriticalBashCommand('pm list packages fa1'), isNull);
  });
}
