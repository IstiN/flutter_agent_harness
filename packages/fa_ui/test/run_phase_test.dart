// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// AC5 (issue #865): the status row's logic is a pure function of the chat
/// event sequence — no screen-level state machine. The transcript shapes
/// below mirror what AgentService appends per agent event (user rows, lazy
/// assistant/thinking rows, the `[name] args` system row on a tool start,
/// tool-result rows).
void main() {
  FaChatMessage row(String role, String content, {String? toolName}) =>
      FaChatMessage(role: role, content: content, toolName: toolName);

  FaRunPhase derive(List<FaChatMessage> messages, {bool streaming = true}) =>
      faRunPhase(streaming: streaming, messages: messages);

  test('idle run is hidden even mid-tool tail', () {
    final messages = [
      row('user', 'hi'),
      row('system', '[bash] {"command": "ls"}'),
    ];
    expect(derive(messages, streaming: false), const FaRunPhase.hidden());
  });

  test('request just sent — empty transcript is the provider wait', () {
    expect(derive(const []), const FaRunPhase(FaRunPhaseKind.thinking));
  });

  test('user tail is the provider wait (AC1 data)', () {
    expect(
      derive([row('user', 'fix the tests')]),
      const FaRunPhase(FaRunPhaseKind.thinking),
    );
  });

  test('assistant tail is writing', () {
    expect(
      derive([
        row('user', 'hi'),
        row('thinking', 'hmm'),
        row('assistant', 'partial ans'),
      ]),
      const FaRunPhase(FaRunPhaseKind.writing),
    );
  });

  test('thinking-only tail stays thinking', () {
    expect(
      derive([row('user', 'hi'), row('thinking', 'let me see...')]),
      const FaRunPhase(FaRunPhaseKind.thinking),
    );
  });

  test('finished tool tail (request back out) is thinking', () {
    expect(
      derive([
        row('user', 'hi'),
        row('system', '[true] {}'),
        row('tool', '', toolName: 'true'),
      ]),
      const FaRunPhase(FaRunPhaseKind.thinking),
    );
  });

  test('in-flight tool names itself (AC2)', () {
    expect(
      derive([
        row('user', 'hi'),
        row('system', '[wasm_shell] {"argv": ["rg", "TODO"]}'),
      ]),
      const FaRunPhase.tool(first: 'wasm_shell', count: 1),
    );
  });

  test('sequential tool marathon switches names per tool', () {
    final messages = [
      row('user', 'tidy the repo'),
      row('system', '[true] {}'),
      row('tool', '', toolName: 'true'),
    ];
    // Second step in flight: the new start row names the phase.
    messages
      ..add(row('system', '[wc] {"stdin": "x"}'))
      ..add(row('tool', '3', toolName: 'wc'));
    expect(
      derive([...messages, row('system', '[rg] {"args": ["TODO"]}')]),
      const FaRunPhase.tool(first: 'rg', count: 1),
    );
    // Between steps — result in, request out: provider wait again.
    expect(derive(messages), const FaRunPhase(FaRunPhaseKind.thinking));
  });

  test('parallel calls: count + first name (E1)', () {
    expect(
      derive([
        row('user', 'refactor'),
        row('system', '[read] {"path": "a.dart"}'),
        row('system', '[grep] {"pattern": "Foo"}'),
      ]),
      const FaRunPhase.tool(first: 'read', count: 2),
    );
  });

  test('parallel calls: completion narrows the count, first name stable', () {
    expect(
      derive([
        row('user', 'refactor'),
        row('system', '[read] {"path": "a.dart"}'),
        row('system', '[grep] {"pattern": "Foo"}'),
        row('tool', 'ok', toolName: 'grep'),
      ]),
      const FaRunPhase.tool(first: 'read', count: 1),
    );
  });

  test('prose system rows are not tool starts', () {
    expect(
      derive([
        row('user', 'hi'),
        row('system', 'CodeMie session expired — sign in again.'),
      ]),
      const FaRunPhase(FaRunPhaseKind.thinking),
    );
  });

  test('steering mid-run keeps the row up (E2)', () {
    final midTool = [
      row('user', 'go'),
      row('system', '[bash] {"command": "ls"}'),
      row('user', 'also check the logs'),
      row('system', '[rg] {"args": ["err"]}')
    ];
    expect(
      derive(midTool),
      const FaRunPhase.tool(first: 'rg', count: 1),
    );
    // Steer absorbed between steps: still visible, provider wait.
    expect(
      derive([
        row('user', 'go'),
        row('tool', 'ok', toolName: 'bash'),
        row('user', 'also check the logs'),
      ]),
      const FaRunPhase(FaRunPhaseKind.thinking),
    );
  });

  test('dynamic-message markers end the phase like any boundary', () {
    // Realistic order: the marker lands right after the tool result row.
    expect(
      derive([
        row('user', 'go'),
        row('system', '[bash] {"command": "make"}'),
        row('tool', 'done', toolName: 'bash'),
        row('widget', 'Build started'),
      ]),
      const FaRunPhase(FaRunPhaseKind.thinking),
    );
  });

  test('phase equality distinguishes kind, tool, and count', () {
    expect(
      const FaRunPhase.tool(first: 'a', count: 1),
      const FaRunPhase.tool(first: 'a', count: 1),
    );
    expect(
      const FaRunPhase.tool(first: 'a', count: 1),
      isNot(const FaRunPhase.tool(first: 'a', count: 2)),
    );
    expect(
      const FaRunPhase.tool(first: 'a', count: 1),
      isNot(const FaRunPhase.tool(first: 'b', count: 1)),
    );
  });
}
