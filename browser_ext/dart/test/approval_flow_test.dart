// Pins the pure approval-flow core the SW host delegates to (the host
// itself is web-only): pending prompts + the 120s timeout backstop, the
// panel's decide path (with exfil-gate origin bookkeeping), and the
// mid-run mode-change rescue (flipping to yolo resolves every pending
// prompt as allowed instead of stalling the turn for the full timeout).
//
// Regression context: the extension panel chatted through a surface with
// no approval handler mounted, every gated tool call stalled 120s, was
// denied, and the agent retried the next gated tool — the user saw a
// permanently "busy" badge and no output. Switching the approval mode to
// yolo mid-run was DROPPED by the busy guard, so the rescue never landed.
import 'dart:async';

import 'package:flutter_agent_harness/src/approval/approval.dart'
    show ApprovalMode;
import 'package:test/test.dart';

import '../src/approval_flow.dart';

void main() {
  final events = <Map<String, dynamic>>[];
  late ApprovalFlow flow;

  setUp(() {
    events.clear();
    flow = ApprovalFlow(sink: events.add);
  });

  Map<String, dynamic> event(String type) =>
      events.firstWhere((e) => e['type'] == type);

  test('request sinks approval_request and decide completes it', () async {
    final done = flow.request(
      toolName: 'browser_read_dom',
      arguments: {'selector': 'body'},
      reason: 'read tier asks in always-ask mode',
    );

    final req = event('approval_request');
    expect(req['id'], 'ap-1');
    expect(req['call']['toolName'], 'browser_read_dom');
    expect(req['reason'], 'read tier asks in always-ask mode');
    expect(flow.hasPending, isTrue);

    expect(flow.decide('ap-1', true).found, isTrue);
    await expectLater(done, completion(isTrue));
    expect(flow.hasPending, isFalse);
  });

  test('ids increment; a second request gets its own id', () async {
    final first = flow.request(toolName: 'a', arguments: {}, reason: '');
    final second = flow.request(toolName: 'b', arguments: {}, reason: '');
    expect(event('approval_request')['id'], 'ap-1');
    flow.decide('ap-1', true);
    await first;
    expect(
      events.where((e) => e['type'] == 'approval_request').last['id'],
      'ap-2',
    );
    flow.decide('ap-2', false);
    await expectLater(second, completion(isFalse));
  });

  test('decide on an unknown id is a found=false no-op', () {
    expect(flow.decide('ap-9', true).found, isFalse);
    expect(flow.hasPending, isFalse);
  });

  test('allowed decide exposes the target origin (exfil-gate seeding)', () {
    final done = flow.request(
      toolName: 'tabs_open',
      arguments: {'url': 'https://example.com/a'},
      reason: '',
    );
    final outcome = flow.decide('ap-1', true);
    expect(outcome.found, isTrue);
    expect(outcome.origin, 'https://example.com');
    unawaited(done);
  });

  test('denied decide still reports found but no origin use', () async {
    final done = flow.request(
      toolName: 'tabs_open',
      arguments: {'url': 'https://example.com/a'},
      reason: '',
    );
    final outcome = flow.decide('ap-1', false);
    expect(outcome.found, isTrue);
    expect(outcome.origin, isNull); // host must NOT seed a denied origin
    await expectLater(done, completion(isFalse));
  });

  test('timeout backstop denies with a note', () async {
    final fast = ApprovalFlow(
      sink: events.add,
      timeout: const Duration(milliseconds: 10),
    );
    final done = fast.request(toolName: 'x', arguments: {}, reason: '');
    await expectLater(done, completion(isFalse));
    final resolved = event('approval_resolved');
    expect(resolved['allow'], isFalse);
    expect(resolved['note'], contains('timed out'));
    expect(fast.hasPending, isFalse);
  });

  test('resolveAll (mode → yolo rescue) allows every pending prompt', () async {
    final a = flow.request(toolName: 'a', arguments: {}, reason: '');
    final b = flow.request(toolName: 'b', arguments: {}, reason: '');
    final resolved = flow.resolveAll(
      allow: true,
      note: 'approval mode → yolo: pending prompts allowed',
    );
    expect(resolved, 2);
    await expectLater(a, completion(isTrue));
    await expectLater(b, completion(isTrue));
    expect(flow.hasPending, isFalse);
    final notes = events
        .whereType<Map<String, dynamic>>()
        .where((e) => e['type'] == 'approval_resolved')
        .toList();
    expect(notes, hasLength(2));
    expect(notes.every((e) => e['allow'] == true), isTrue);
  });

  test('resolveAll with nothing pending resolves nothing', () {
    expect(flow.resolveAll(allow: true, note: 'x'), 0);
  });

  test('summary over 300 chars is trimmed with an ellipsis', () {
    final long = 'x' * 400;
    unawaited(
      flow
          .request(toolName: 't', arguments: {'a': long}, reason: '')
          .then((_) {}),
    );
    final summary = event('approval_request')['summary'] as String;
    expect(summary.length, 301);
    expect(summary.endsWith('…'), isTrue);
    flow.decide('ap-1', true);
  });

  test('exfilGateShouldAsk: yolo/unattended silent, ask/write prompt', () {
    expect(exfilGateShouldAsk(ApprovalMode.alwaysAsk), isTrue);
    expect(exfilGateShouldAsk(ApprovalMode.write), isTrue);
    // The user's contract: yolo = NOTHING asks, ever. The extension has
    // no bash, so no critical pattern can justify a prompt there.
    expect(exfilGateShouldAsk(ApprovalMode.yolo), isFalse);
    expect(exfilGateShouldAsk(ApprovalMode.unattended), isFalse);
  });

  test('reconfigureNeedsIdle: approval-mode-only change applies live', () {
    // The busy guard must NOT swallow a yolo flip: the mode is the one
    // field that is safe (and vital) to change mid-run.
    expect(
      reconfigureNeedsIdle(
        mailboxChanged: false,
        providerChanged: false,
        dapChanged: false,
        toolsChanged: false,
      ),
      isFalse,
    );
    expect(
      reconfigureNeedsIdle(
        mailboxChanged: false,
        providerChanged: true,
        dapChanged: false,
        toolsChanged: false,
      ),
      isTrue,
    );
    expect(
      reconfigureNeedsIdle(
        mailboxChanged: true,
        providerChanged: false,
        dapChanged: false,
        toolsChanged: false,
      ),
      isTrue,
    );
    expect(
      reconfigureNeedsIdle(
        mailboxChanged: false,
        providerChanged: false,
        dapChanged: true,
        toolsChanged: false,
      ),
      isTrue,
    );
    expect(
      reconfigureNeedsIdle(
        mailboxChanged: false,
        providerChanged: false,
        dapChanged: false,
        toolsChanged: true,
      ),
      isTrue,
    );
  });
}
