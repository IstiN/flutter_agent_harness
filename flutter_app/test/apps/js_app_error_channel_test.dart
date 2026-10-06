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

  test(
    'publish routes to subscribers; without a listener it is inert (E3)',
    () async {
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
    },
  );

  test('disposeAndReset re-arms the gate', () {
    expect(report(channel, _error())!.deliver, isTrue);
    expect(report(channel, _error())!.deliver, isFalse);
    channel.disposeAndReset();
    expect(report(channel, _error())!.deliver, isTrue);
  });

  group('parseJsAppErrorLogLine (gh-1307: the engine log tap transport)', () {
    // The record the bootstrap emits, verbatim.
    const record =
        '{"kind":"showError","message":"Widget error: Error: load blew up",'
        '"stack":"    at foo (<eval>:3)\\n","fingerprint":"load blew #\\nat foo"}';

    test('a plain structured record parses (the gh-1164 wire shape)', () {
      final event = parseJsAppErrorLogLine('[E] faAppError:$record');
      expect(event, isNotNull);
      expect(event!.kind, JsAppErrorKind.showError);
      expect(event.message, contains('load blew up'));
    });

    test('a record inside the engine log envelope still parses — the iid '
        'tag wraps console lines as {id: "[E] faAppError:{…}"} by the time '
        'they reach Dart (flutter_js jsonDecodes the payload before the '
        'channel callback, so the {id: …} wrap survives dispatch)', () {
      final event = parseJsAppErrorLogLine('{id: [E] faAppError:$record}');
      expect(event, isNotNull, reason: 'the load error must be captured');
      expect(event!.kind, JsAppErrorKind.showError);
      expect(event.message, contains('load blew up'));
      expect(event.fingerprint, contains('load blew #'));
    });

    test('a record with nested braces/escapes inside its strings parses '
        'inside the envelope', () {
      final nested =
          '{"kind":"callback","message":"bad {token} \\"q\\" end",'
          '"stack":"at f ({a:1})\\n","fingerprint":"bad {token}#"}';
      final event = parseJsAppErrorLogLine('{id: [E] faAppError:$nested}');
      expect(event, isNotNull);
      expect(event!.kind, JsAppErrorKind.callback);
      expect(event.message, contains('{token}'));
    });

    test('a marker mention in a plain log line followed by unrelated JSON '
        'is NOT captured — the record `{` must be the first non-whitespace '
        'character after the marker (gh-1307 review)', () {
      final event = parseJsAppErrorLogLine(
        'the host parses faAppError: records like {"message":"hint"}',
      );
      expect(event, isNull, reason: 'a marker mention is not a record');
    });

    test('a truncated (unbalanced) record stays null — never a best-effort '
        'prefix decode (gh-1307 review: pins the scanner\u2019s truncation '
        'exit)', () {
      expect(
        parseJsAppErrorLogLine(
          '[E] faAppError:{"kind":"showError","message":"x"',
        ),
        isNull,
        reason: 'unbalanced record must stay null, not decode a prefix',
      );
    });

    test('non-record lines (plain logs, marker-free, malformed payloads) '
        'return null', () {
      expect(parseJsAppErrorLogLine('hello world'), isNull);
      expect(parseJsAppErrorLogLine('{id: [E] some plain log}'), isNull);
      expect(parseJsAppErrorLogLine('[E] faAppError:not-json'), isNull);
      expect(
        parseJsAppErrorLogLine('{id: [E] faAppError:{"kind":"showError"}}'),
        isNull,
        reason: 'no message → not a captureable record',
      );
    });
  });

  test(
    'capExcerpt bounds gate excerpts with the same cap as the notices '
    '(gh-1164 review: pathological error text can never balloon the '
    'open_app tool result)',
    () {
      final short = JsAppErrorChannel.capExcerpt('ok');
      expect(short, 'ok');
      final huge = JsAppErrorChannel.capExcerpt(
        'x' * (JsAppErrorChannel.maxMessageChars * 20),
      );
      expect(huge, contains('[truncated]'));
      expect(
        huge.length,
        lessThanOrEqualTo(JsAppErrorChannel.maxMessageChars + 16),
      );
    },
  );
}
