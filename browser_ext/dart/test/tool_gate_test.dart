// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/src/agent/agent_tool.dart';
import 'package:flutter_agent_harness/src/cancel_token.dart';
import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/agent/tool_registry.dart';
import 'package:test/test.dart';
import '../src/tool_gate.dart';
import '../src/ui_protocol.dart';

Future<ToolExecutionResult> _executeNoop(
  Map<String, dynamic> args,
  CancelToken? cancelToken,
  void Function(ToolExecutionResult)? onUpdate,
) async => ToolExecutionResult.text('ok');

/// Minimal tool double: only the name matters to the gate.
AgentTool tool(String name) => AgentTool(
      name: name,
      description: 'test double',
      parameters: const <String, dynamic>{},
      execute: _executeNoop,
    );

void main() {
  test('snapshot lists every source with its enabled flag', () {
    final gate = ToolGate({
      'a': tool('a'),
      'b': tool('b'),
    });
    expect(gate.snapshot(), const [
      UiToolState(name: 'a', enabled: true),
      UiToolState(name: 'b', enabled: true),
    ]);
    expect(gate.enabled, {'a', 'b'});
  });

  test('apply toggles known names and reports changes', () {
    final gate = ToolGate({'a': tool('a'), 'b': tool('b')});
    expect(
      gate.apply(const [UiToolState(name: 'b', enabled: false)]),
      isTrue,
    );
    expect(gate.enabled, {'a'});
    // No-op puts report no change (the host skips the re-sync).
    expect(
      gate.apply(const [UiToolState(name: 'b', enabled: false)]),
      isFalse,
    );
    expect(
      gate.apply(const [UiToolState(name: 'b', enabled: true)]),
      isTrue,
    );
    expect(gate.enabled, {'a', 'b'});
  });

  test('apply ignores unknown names (panel may lag the SW)', () {
    final gate = ToolGate({'a': tool('a')});
    expect(
      gate.apply(const [UiToolState(name: 'ghost', enabled: false)]),
      isFalse,
    );
    expect(gate.enabled, {'a'});
  });

  test('sync registers enabled and unregisters disabled tools', () {
    final gate = ToolGate({'a': tool('a'), 'b': tool('b')});
    final registry = ToolRegistry(const []);
    gate.sync(registry);
    expect(registry.names, containsAll(['a', 'b']));
    gate.apply(const [UiToolState(name: 'a', enabled: false)]);
    gate.sync(registry);
    expect(registry.names, ['b']);
    gate.apply(const [UiToolState(name: 'a', enabled: true)]);
    gate.sync(registry);
    expect(registry.names, containsAllInOrder(['b', 'a']));
  });
}
