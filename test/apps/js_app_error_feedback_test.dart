/// gh-1164 Part B: the anti-spam gate between JS app runtime errors and the
/// authoring agent's session — one report per (app, error fingerprint) until
/// the app source revision changes, a per-app circuit breaker after N
/// unacted identical reports, bounded payloads (E2).
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/apps/js_app_errors.dart';
import 'package:test/test.dart';

JsAppErrorReport? _observe(
  JsAppErrorFeedback gate, {
  String appId = 'calc',
  String surface = 'app',
  String kind = 'callback',
  required String message,
  String stack = '',
  required String revision,
  DateTime? now,
}) {
  return gate.observe(
    appId: appId,
    surface: surface,
    kind: kind,
    message: message,
    stack: stack,
    sourceRevision: revision,
    now: now ?? DateTime.fromMillisecondsSinceEpoch(1700000000000),
  );
}

void main() {
  group('parseJsAppErrorLogLine', () {
    test('parses the [E]-prefixed marker line the bootstrap emits', () {
      final payload = jsonEncode({
        'kind': 'callback',
        'message': 'boom: x is not defined',
        'stack': 'at handler (widget.js:12)',
      });
      final event = parseJsAppErrorLogLine('[E] faAppError:$payload');
      expect(event, isNotNull);
      expect(event!.kind, 'callback');
      expect(event.message, 'boom: x is not defined');
      expect(event.stack, contains('widget.js:12'));
    });

    test('plain log lines and malformed payloads return null', () {
      expect(parseJsAppErrorLogLine('[E] regular console error'), isNull);
      expect(parseJsAppErrorLogLine('loading…'), isNull);
      expect(parseJsAppErrorLogLine('[E] faAppError:not-json{'), isNull);
      expect(parseJsAppErrorLogLine(''), isNull);
      // A JSON payload without the expected shape is not an error record.
      expect(parseJsAppErrorLogLine('[E] faAppError:"just a string"'), isNull);
    });
  });

  group('JsAppErrorFeedback dedup (AC4)', () {
    test('100 identical per-frame errors collapse to exactly ONE report', () {
      final gate = JsAppErrorFeedback();
      final reports = <JsAppErrorReport>[];
      for (var i = 0; i < 100; i++) {
        final report = _observe(
          gate,
          kind: 'callback',
          message: 'Cannot read property "x" of undefined',
          stack: 'at frame (widget.js:42)',
          revision: 'rev-1',
        );
        if (report != null) reports.add(report);
      }
      expect(
        reports,
        hasLength(1),
        reason:
            'the first occurrence reports; '
            'the other 99 frames are the same (app, error) until an edit',
      );
    });

    test('a source revision change reports the same error again', () {
      final gate = JsAppErrorFeedback();
      expect(_observe(gate, message: 'boom', revision: 'rev-1'), isNotNull);
      expect(_observe(gate, message: 'boom', revision: 'rev-1'), isNull);
      final afterEdit = _observe(gate, message: 'boom', revision: 'rev-2');
      expect(
        afterEdit,
        isNotNull,
        reason:
            'the edit did not fix it — the '
            'agent must see the error persists in the NEW revision',
      );
      expect(afterEdit!.sourceRevision, 'rev-2');
    });

    test('a different error in the same revision still reports', () {
      final gate = JsAppErrorFeedback();
      expect(_observe(gate, message: 'boom', revision: 'rev-1'), isNotNull);
      expect(
        _observe(gate, message: 'different failure', revision: 'rev-1'),
        isNotNull,
      );
    });

    test('two live surfaces of one app dedup through a shared gate', () {
      // The launcher tile and the fullscreen view run separate engines;
      // both forward into the service-level gate.
      final gate = JsAppErrorFeedback();
      final tile = _observe(
        gate,
        surface: 'tile',
        message: 'boom',
        revision: 'r1',
      );
      final view = _observe(
        gate,
        surface: 'app',
        message: 'boom',
        revision: 'r1',
      );
      expect(tile, isNotNull);
      expect(view, isNull, reason: 'same app + fingerprint + revision');
    });

    test('the same error text from a DIFFERENT app reports independently', () {
      final gate = JsAppErrorFeedback();
      expect(
        _observe(gate, appId: 'calc', message: 'boom', revision: 'r1'),
        isNotNull,
      );
      expect(
        _observe(gate, appId: 'notes', message: 'boom', revision: 'r1'),
        isNotNull,
      );
    });
  });

  group('JsAppErrorFeedback circuit breaker', () {
    test('stops after N unacted identical reports across revisions', () {
      final gate = JsAppErrorFeedback();
      final reports = <JsAppErrorReport?>[];
      for (var revision = 1; revision <= 6; revision++) {
        reports.add(
          _observe(gate, message: 'same bug', revision: 'rev-$revision'),
        );
      }
      // maxUnactedRevisions = 3: the first three edits report, then the
      // loop stops — the agent saw "the same bug persists" three times.
      expect(reports[0], isNotNull);
      expect(reports[1], isNotNull);
      expect(reports[2], isNotNull);
      expect(reports[3], isNull, reason: 'breaker tripped');
      expect(reports[4], isNull);
      expect(reports[5], isNull);
    });

    test('progress on a DIFFERENT error re-arms the breaker', () {
      final gate = JsAppErrorFeedback();
      for (var revision = 1; revision <= 4; revision++) {
        _observe(gate, message: 'same bug', revision: 'rev-$revision');
      }
      // The agent's edit changed something else — a different error fires.
      expect(
        _observe(gate, message: 'a new different bug', revision: 'rev-5'),
        isNotNull,
      );
      // The breaker re-armed: the original bug reports on the next
      // revision again.
      expect(_observe(gate, message: 'same bug', revision: 'rev-6'), isNotNull);
    });
  });

  group('bounded payloads (E2)', () {
    test('huge stacks keep the head frames and mark the truncation', () {
      final gate = JsAppErrorFeedback(maxStackFrames: 4);
      final hugeStack = List.generate(
        200,
        (i) => 'at f$i (widget.js:$i)',
      ).join('\n');
      final report = _observe(
        gate,
        message: 'boom',
        stack: hugeStack,
        revision: 'r1',
      )!;
      expect(report.stackHead, hasLength(4));
      expect(report.stackHead.first, 'at f0 (widget.js:0)');
      expect(report.stackTruncated, isTrue);
    });

    test('a short stack is carried whole, never marked truncated', () {
      final gate = JsAppErrorFeedback();
      final report = _observe(
        gate,
        message: 'boom',
        stack: 'at only (widget.js:1)',
        revision: 'r1',
      )!;
      expect(report.stackHead, hasLength(1));
      expect(report.stackTruncated, isFalse);
    });

    test('oversized messages are capped with a truncation marker', () {
      final gate = JsAppErrorFeedback(maxMessageChars: 64);
      final report = _observe(gate, message: 'x' * 10000, revision: 'r1')!;
      expect(report.message.length, lessThanOrEqualTo(64 + 20));
      expect(report.message, endsWith('…'));
    });
  });

  group('report shape', () {
    test('carries the identity fields the session record needs', () {
      final localGate = JsAppErrorFeedback();
      final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final report = _observe(
        localGate,
        appId: 'weather',
        surface: 'tile',
        kind: 'bootstrap',
        message: 'SyntaxError: unexpected token',
        stack: 'at global (widget_tile.js:1)',
        revision: 'rev-9',
        now: now,
      )!;
      expect(report.appId, 'weather');
      expect(report.surface, 'tile');
      expect(report.kind, 'bootstrap');
      expect(report.message, 'SyntaxError: unexpected token');
      expect(report.sourceRevision, 'rev-9');
      expect(report.timestamp, now);
      expect(report.fingerprint, isNotEmpty);
    });

    test('json round-trips through the session-record shape', () {
      final gate = JsAppErrorFeedback();
      final report = _observe(
        gate,
        kind: 'render',
        message: 'render host exception',
        stack: 'at build (js_app_view.dart:1)',
        revision: 'r1',
      )!;
      final restored = JsAppErrorReport.fromJson(
        jsonDecode(jsonEncode(report.toJson())) as Map<String, dynamic>,
      );
      expect(restored.appId, report.appId);
      expect(restored.surface, report.surface);
      expect(restored.kind, report.kind);
      expect(restored.message, report.message);
      expect(restored.stackHead, report.stackHead);
      expect(restored.stackTruncated, report.stackTruncated);
      expect(restored.sourceRevision, report.sourceRevision);
      expect(restored.timestamp, report.timestamp);
      expect(restored.fingerprint, report.fingerprint);
    });

    test('fingerprints ignore whitespace noise but keep distinct errors', () {
      final gate = JsAppErrorFeedback();
      final first = _observe(
        gate,
        message: 'Cannot read property\n  "x" of   undefined',
        revision: 'r1',
      )!;
      // Same error with different formatting collapses (already reported).
      expect(
        _observe(
          gate,
          message: 'Cannot read property "x" of undefined',
          revision: 'r1',
        ),
        isNull,
      );
      expect(
        first.fingerprint,
        _observe(
          gate,
          message: 'Cannot read property "x" of undefined',
          revision: 'r2',
        )!.fingerprint,
      );
      expect(
        first.fingerprint,
        isNot(
          _observe(
            gate,
            message: 'totally different',
            revision: 'r1',
          )!.fingerprint,
        ),
      );
    });
  });
}
