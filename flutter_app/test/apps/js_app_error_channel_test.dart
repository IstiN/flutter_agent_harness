// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1164 Part B + AC4: the error channel's dedup gate — one report per
/// (app, error fingerprint) until the source revision changes; a per-app
/// circuit breaker silences unacted repeats; bounded payloads (E2).
library;

import 'package:fa/apps/js_app_error_channel.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

JsAppErrorEvent _error({String message = 'boom', String fingerprint = ''}) =>
    JsAppErrorEvent(
      kind: JsAppErrorKind.callback,
      message: message,
      stack: 'at widget.js:7:3',
      fingerprint: fingerprint,
    );

void main() {
  late JsAppErrorChannel channel;

  setUp(() => channel = JsAppErrorChannel.test());

  JsAppErrorFeedback? report(
    JsAppErrorChannel target,
    JsAppErrorEvent event, {
    String revision = 'r1',
  }) => target.reportAppError(
    event,
    appId: 'calc',
    surface: 'app',
    sourceRevision: revision,
  );

  test('first occurrence delivers; identical repeats dedup (AC4)', () {
    final first = report(channel, _error());
    expect(first, isNotNull);
    expect(first!.deliver, isTrue);
    expect(first.notice, contains('calc'));
    expect(first.notice, contains('boom'));
    for (var i = 0; i < 3; i++) {
      final again = report(channel, _error());
      expect(again, isNotNull);
      expect(again!.deliver, isFalse, reason: 'repeat ${i + 2} must dedup');
    }
  });

  test('a different fingerprint is a new report; an edit (new revision) '
      're-arms everything (AC4)', () {
    expect(report(channel, _error())!.deliver, isTrue);
    expect(report(channel, _error(message: 'other'))!.deliver, isTrue);
    // Same errors, new source revision → re-armed.
    expect(report(channel, _error(), revision: 'r2')!.deliver, isTrue);
    expect(report(channel, _error(), revision: 'r2')!.deliver, isFalse);
  });

  test('per-frame bursts collapse: 100 identical errors → exactly ONE '
      'deliverable report, then the circuit breaker silences the key', () {
    JsAppErrorFeedback? last;
    for (var i = 0; i < 100; i++) {
      last = report(channel, _error());
    }
    expect(last, isNull, reason: 'breaker must silence after threshold');
    // A DIFFERENT error on the same app still reports (breaker is per key).
    expect(report(channel, _error(message: 'other'))!.deliver, isTrue);
  });

  test('payloads are bounded and truncation is marked (E2)', () {
    final huge = JsAppErrorEvent(
      kind: JsAppErrorKind.onerror,
      message: 'x' * 5000,
      stack: List.generate(40, (i) => 'at frame$i:1:1').join('\n'),
    );
    final feedback = report(channel, huge);
    expect(feedback!.deliver, isTrue);
    expect(feedback.notice.length, lessThan(2000));
    expect(feedback.notice, contains('[truncated]'));
    expect(
      feedback.notice.split('\n').where((l) => l.startsWith('at ')).length,
      lessThanOrEqualTo(5),
    );
  });

  test('publish routes to subscribers; without a listener it is inert (E3)', () async {
    final notice = JsAppErrorNotice(
      event: _error(),
      appId: 'calc',
      surface: 'app',
      sourceRevision: 'r1',
      notice: 'n',
    );
    expect(channel.publish(notice), isFalse);
    final received = <JsAppErrorNotice>[];
    final sub = channel.onDeliver.listen(received.add);
    expect(channel.publish(notice), isTrue);
    await pumpEventQueue();
    expect(received, hasLength(1));
    await sub.cancel();
  });

  test('disposeAndReset re-arms the gate', () {
    expect(report(channel, _error())!.deliver, isTrue);
    expect(report(channel, _error())!.deliver, isFalse);
    channel.disposeAndReset();
    expect(report(channel, _error())!.deliver, isTrue);
  });
}
