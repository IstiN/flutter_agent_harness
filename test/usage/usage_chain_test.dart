// gh-1241 chain-fold tests: AC1 (sums over model_request_summary), AC2
// (double-resume → one record, resumedCount 2, three segments), AC3
// (kill-mid-segment + rebuild reproduces exactly, I6 idempotency), AC4
// (fake provider omitting usage → estimated/mixed markers), AC5 (mid-run
// model switch → byModel split), E1 (partial usage → mixed), E3 (corrupt
// artifact detected), blob skip, torn-line tolerance.

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'usage_chain_fixtures.dart';

UsageLedger foldChain(List<String> lines, {String sessionId = 'sess-1'}) =>
    const UsageChainFolder().foldChain(sessionId: sessionId, lines: lines);

void main() {
  group('AC1: fresh session fold', () {
    test(
      'segments[0] equals the sums over the model_request_summary records',
      () {
        final ledger = foldChain([
          sessionHeaderLine('sess-1'),
          segmentMarkerLine(1),
          requestSummaryLine(2),
          assistantLine(3, usage: reportedUsage(input: 100, output: 50)),
          requestSummaryLine(4),
          assistantLine(
            5,
            usage: reportedUsage(input: 300, output: 150, cacheRead: 200),
          ),
          userLine(6), // ignored
        ]);
        expect(ledger.resumedCount, 0);
        expect(ledger.segments.length, 1);
        final segment = ledger.segments.single;
        expect(segment.totals.requests, 2);
        expect(segment.totals.input, 400);
        expect(segment.totals.output, 200);
        expect(segment.totals.cacheRead, 200);
        expect(segment.source, UsageSource.reported);
        expect(ledger.total.totals.input, 400);
        expect(ledger.total.totals.requests, 2);
        // I2: total == Σ(segments) at every write.
        expect(ledger.total.totals.requests, segment.totals.requests);
      },
    );

    test(
      'estimates input from the paired summary chars when usage is omitted (AC4)',
      () {
        final ledger = foldChain([
          sessionHeaderLine('sess-1'),
          segmentMarkerLine(1),
          // 400 + 100 = 500 chars outbound → ceil(500/4) = 125 estimated
          // input; output estimated from the assistant payload
          // ('hello world' = 11 chars → ceil(11/4) = 3).
          requestSummaryLine(2, messageChars: const [400, 100]),
          assistantLine(3, usage: omittedUsage),
        ]);
        final segment = ledger.segments.single;
        expect(segment.totals.requests, 1);
        expect(segment.source, UsageSource.estimated);
        expect(segment.totals.input, 125);
        expect(segment.totals.output, 3);
        expect(ledger.total.source, UsageSource.estimated);
      },
    );

    test(
      'partial provider usage inside one segment → per-segment mixed (E1)',
      () {
        final ledger = foldChain([
          sessionHeaderLine('sess-1'),
          segmentMarkerLine(1),
          requestSummaryLine(2),
          assistantLine(3, usage: reportedUsage(input: 100, output: 50)),
          requestSummaryLine(4),
          assistantLine(5, usage: omittedUsage),
        ]);
        final segment = ledger.segments.single;
        expect(segment.source, UsageSource.mixed);
        // Reported counts are kept, estimated ones added — never zero-filled
        // silently.
        expect(segment.totals.input, greaterThanOrEqualTo(100));
        expect(segment.totals.requests, 2);
        expect(ledger.total.source, UsageSource.mixed);
      },
    );
  });

  group('AC2: resume semantics (I1)', () {
    test(
      '--continue twice → ONE record, resumedCount 2, three segments, total == Σ(segments)',
      () {
        // Boot 1: segment 0 with one request.
        // Boot 2 (--continue): marker, segment 1 with two requests.
        // Boot 3 (--continue): marker, segment 2 with one request.
        final ledger = foldChain([
          sessionHeaderLine('sess-1'),
          segmentMarkerLine(1),
          requestSummaryLine(2),
          assistantLine(3, usage: reportedUsage(input: 100, output: 50)),
          segmentMarkerLine(4),
          requestSummaryLine(5),
          assistantLine(6, usage: reportedUsage(input: 200, output: 100)),
          requestSummaryLine(7),
          assistantLine(8, usage: reportedUsage(input: 10, output: 5)),
          segmentMarkerLine(9),
          requestSummaryLine(10),
          assistantLine(11, usage: reportedUsage(input: 7, output: 3)),
        ]);
        expect(ledger.segments.length, 3);
        expect(ledger.resumedCount, 2);
        expect(ledger.segments[0].totals.requests, 1);
        expect(ledger.segments[1].totals.requests, 2);
        expect(ledger.segments[2].totals.requests, 1);
        expect(ledger.total.totals.requests, 4);
        expect(ledger.total.totals.input, 317);
        expect(ledger.total.totals.input, 100 + 210 + 7);
        // Segments are keyed by chain sequence: segment indexes follow the
        // marker order, and the resume markers stamp each segment's open.
        expect(ledger.segments[1].openedAt, DateTime.utc(2024, 1, 1, 0, 4));
      },
    );
  });

  group('AC3/I6: kill mid-segment + rebuild', () {
    test(
      'SIGKILL loses nothing: the open segment is reproduced from the surviving chain',
      () {
        // The ledger AS WRITTEN before the kill held only the closed
        // segment. Re-running the fold over the chain (which still carries
        // the open segment's records) must reproduce the FULL usage.
        final preKillChain = [
          sessionHeaderLine('sess-1'),
          segmentMarkerLine(1),
          requestSummaryLine(2),
          assistantLine(3, usage: reportedUsage(input: 100, output: 50)),
        ];
        final closedLedger = foldChain(preKillChain);
        expect(closedLedger.segments.single.totals.requests, 1);

        // The process is killed mid-segment-2; the chain on disk carries
        // everything the fold needs (records flush per request).
        final survivingChain = [
          ...preKillChain,
          segmentMarkerLine(4),
          requestSummaryLine(5),
          assistantLine(6, usage: reportedUsage(input: 42, output: 9)),
        ];
        final rebuilt = foldChain(survivingChain);
        expect(rebuilt.segments.length, 2);
        expect(rebuilt.segments[0].totals.input, 100);
        // The open segment's usage is exact, not lost.
        expect(rebuilt.segments[1].totals.input, 42);
        expect(rebuilt.segments[1].totals.requests, 1);
        expect(rebuilt.total.totals.input, 142);
      },
    );

    test(
      'running the fold twice over the same chain is byte-identical (I6)',
      () {
        final chain = [
          sessionHeaderLine('sess-1'),
          segmentMarkerLine(1),
          requestSummaryLine(2),
          assistantLine(3, usage: reportedUsage(input: 100, output: 50)),
          segmentMarkerLine(4),
          wireDumpLine(5), // giant blob: hashed, never decoded
          requestSummaryLine(6),
          assistantLine(7, usage: omittedUsage),
        ];
        final first = jsonEncode(foldChain(chain).toJson());
        final second = jsonEncode(foldChain(chain).toJson());
        expect(second, first);
      },
    );
  });

  group('AC5: mid-segment model switch (I5)', () {
    test(
      'role-fallback take-over splits usage per model, grand total unchanged',
      () {
        final ledger = foldChain([
          sessionHeaderLine('sess-1'),
          segmentMarkerLine(1),
          requestSummaryLine(2),
          assistantLine(
            3,
            model: 'model-main',
            usage: reportedUsage(input: 100, output: 50),
          ),
          // Mid-turn fallback: the provider flips to the smol model.
          requestSummaryLine(4),
          assistantLine(
            5,
            model: 'model-smol',
            usage: reportedUsage(input: 20, output: 10),
          ),
        ]);
        final segment = ledger.segments.single;
        expect(segment.totals.input, 120);
        expect(segment.totals.output, 60);
        expect(segment.byModel['model-main']!.input, 100);
        expect(segment.byModel['model-smol']!.output, 10);
        expect(segment.byModel.length, 2);
        expect(ledger.total.byModel.length, 2);
      },
    );
  });

  group('gh-1460: segment-close model capture', () {
    test(
      'last-seen model wins: the segment model is the LAST request\'s model',
      () {
        final ledger = foldChain([
          sessionHeaderLine('sess-1'),
          segmentMarkerLine(1),
          requestSummaryLine(2),
          assistantLine(
            3,
            model: 'model-main',
            usage: reportedUsage(input: 100, output: 50),
          ),
          requestSummaryLine(4),
          assistantLine(
            5,
            model: 'model-smol',
            usage: reportedUsage(input: 20, output: 10),
          ),
        ]);
        expect(ledger.segments.single.model, 'model-smol');
      },
    );

    test('each resume segment carries its OWN last model', () {
      final ledger = foldChain([
        sessionHeaderLine('sess-1'),
        segmentMarkerLine(1),
        requestSummaryLine(2),
        assistantLine(
          3,
          model: 'model-old',
          usage: reportedUsage(input: 100, output: 50),
        ),
        segmentMarkerLine(4),
        requestSummaryLine(5),
        assistantLine(
          6,
          model: 'model-new',
          usage: reportedUsage(input: 42, output: 9),
        ),
      ]);
      expect(ledger.segments.length, 2);
      expect(ledger.segments[0].model, 'model-old');
      expect(ledger.segments[1].model, 'model-new');
    });

    test('a dangling summary fallback never clobbers the last known model', () {
      final ledger = foldChain([
        sessionHeaderLine('sess-1'),
        segmentMarkerLine(1),
        requestSummaryLine(2),
        assistantLine(
          3,
          model: 'model-a',
          usage: reportedUsage(input: 10, output: 5),
        ),
        requestSummaryLine(4), // never produced an assistant message
      ]);
      expect(ledger.segments.single.model, 'model-a');
    });

    test('a fallback-only segment (all requests died mid-flight) has no '
        'model — the line degrades to the legacy shape', () {
      final ledger = foldChain([
        sessionHeaderLine('sess-1'),
        segmentMarkerLine(1),
        requestSummaryLine(2), // never produced an assistant message
      ]);
      expect(ledger.segments.single.model, isNull);
    });

    test('a blank model id on a record is no observation at all', () {
      final ledger = foldChain([
        sessionHeaderLine('sess-1'),
        segmentMarkerLine(1),
        requestSummaryLine(2),
        assistantLine(3, model: '', usage: reportedUsage(input: 10, output: 5)),
      ]);
      expect(ledger.segments.single.model, isNull);
    });

    test('the model rides the fold, not the usage.json schema (I6)', () {
      final ledger = foldChain([
        sessionHeaderLine('sess-1'),
        segmentMarkerLine(1),
        requestSummaryLine(2),
        assistantLine(3, model: 'model-a', usage: reportedUsage()),
      ]);
      expect(ledger.segments.single.model, 'model-a');
      expect(jsonEncode(ledger.toJson()), isNot(contains('"model":')));
      // Rebuildable: a second fold over the same chain reproduces it.
      expect(
        foldChain([
          sessionHeaderLine('sess-1'),
          segmentMarkerLine(1),
          requestSummaryLine(2),
          assistantLine(3, model: 'model-a', usage: reportedUsage()),
        ]).segments.single.model,
        'model-a',
      );
    });
  });

  group('gh-1643: killed-mid-stream usage (usage_incomplete)', () {
    test('a chain killed before the first assistant message folds the known '
        'request-side input (the evidence-trial shape)', () {
      // Session + segment marker + the first model_request_summary, then
      // the external kill — no assistant message ever finalized. The
      // known request-side volume (systemPromptChars + Σ message chars,
      // persisted BEFORE the request) must fold as estimated input —
      // never a silent zero.
      final ledger = foldChain([
        sessionHeaderLine('sess-1'),
        segmentMarkerLine(1),
        requestSummaryLine(2, messageChars: const [400, 100]),
      ]);
      final segment = ledger.segments.single;
      expect(segment.totals.requests, 1);
      // ceil((10 system + 500 messages) / 4) = 128.
      expect(segment.totals.input, 128);
      expect(segment.totals.output, 0);
      expect(segment.source, UsageSource.estimated);
      expect(ledger.usageIncomplete, isTrue);
      expect(jsonEncode(ledger.toJson()), contains('"usageIncomplete":true'));
    });

    test('two dangling summaries BOTH count (multi-request kill)', () {
      final ledger = foldChain([
        sessionHeaderLine('sess-1'),
        segmentMarkerLine(1),
        requestSummaryLine(2, messageChars: const [400]),
        requestSummaryLine(3, messageChars: const [200, 100]),
      ]);
      final segment = ledger.segments.single;
      expect(segment.totals.requests, 2);
      // ceil((10+400)/4) = 103, ceil((10+300)/4) = 78.
      expect(segment.totals.input, 103 + 78);
      expect(ledger.usageIncomplete, isTrue);
    });

    test('a stripped record folds droppedMessages chars into the estimate '
        '(issue #1882 AC1)', () {
      // The #1882 strip keeps only the newest stubs and folds the older
      // messages into {count, chars} — that aggregate is part of the
      // KNOWN request-side volume, exactly like per-message chars.
      final ledger = foldChain([
        sessionHeaderLine('sess-1'),
        segmentMarkerLine(1),
        requestSummaryLine(
          2,
          messageChars: const [400, 100],
          droppedMessages: (count: 730, chars: 365000),
        ),
      ]);
      final segment = ledger.segments.single;
      // ceil((10 + 500 + 365000) / 4) = 91378.
      expect(segment.totals.input, 91378);
      expect(segment.totals.requests, 1);
      expect(segment.source, UsageSource.estimated);
      expect(ledger.usageIncomplete, isTrue);
    });

    test('a summary superseded by a later summary is flushed, not dropped', () {
      // Request 1 was killed mid-stream; request 2 started before the kill.
      // Both are real spend — dropping the first is the silent-loss shape.
      final scan = const UsageChainScanner().scan([
        sessionHeaderLine('sess-1'),
        segmentMarkerLine(1),
        requestSummaryLine(2, messageChars: const [400]),
        requestSummaryLine(3, messageChars: const [200]),
      ]);
      final requests = [
        for (final segment in scan.segments) ...segment.requests,
      ];
      expect(requests, hasLength(2));
      expect(scan.usageIncomplete, isTrue);
    });

    test(
      'a segment marker flushes the previous segment\'s dangling request',
      () {
        final ledger = foldChain([
          sessionHeaderLine('sess-1'),
          segmentMarkerLine(1),
          requestSummaryLine(2, messageChars: const [400]),
          segmentMarkerLine(3), // resume: request 1 never finalized
          requestSummaryLine(4),
          assistantLine(5, usage: reportedUsage(input: 50, output: 25)),
        ]);
        expect(ledger.segments.length, 2);
        expect(ledger.segments[0].totals.input, 103); // ceil(410/4)
        expect(ledger.segments[1].totals.input, 50);
        expect(ledger.usageIncomplete, isTrue);
      },
    );

    test(
      'completed chains stay byte-identical: no usageIncomplete key, flag false',
      () {
        final ledger = foldChain([
          sessionHeaderLine('sess-1'),
          segmentMarkerLine(1),
          requestSummaryLine(2),
          assistantLine(3, usage: reportedUsage(input: 100, output: 50)),
        ]);
        expect(ledger.usageIncomplete, isFalse);
        expect(jsonEncode(ledger.toJson()), isNot(contains('usageIncomplete')));
      },
    );

    test('usageIncomplete survives the artifact roundtrip', () {
      final ledger = foldChain([
        sessionHeaderLine('sess-1'),
        segmentMarkerLine(1),
        requestSummaryLine(2), // dangling
      ]);
      final decoded = UsageLedger.fromJson(
        (jsonDecode(jsonEncode(ledger.toJson())) as Map)
            .cast<String, dynamic>(),
      );
      expect(decoded.usageIncomplete, isTrue);
    });

    test('a dangling request with NO known chars still marks incomplete — '
        'the marker fires even when the estimate is zero', () {
      final chain = [
        sessionHeaderLine('sess-1'),
        segmentMarkerLine(1),
        // Stub/capped summary shape: no messages array at all.
        '{"type":"custom","id":"r2","timestamp":"2024-01-01T00:02:00.000Z",'
            '"customType":"model_request_summary","data":{"messageCount":3}}',
      ];
      final ledger = foldChain(chain);
      expect(ledger.total.totals.input, 0);
      expect(ledger.total.totals.requests, 1);
      expect(ledger.usageIncomplete, isTrue);
      expect(jsonEncode(ledger.toJson()), contains('"usageIncomplete":true'));
    });
  });

  group('robustness', () {
    test('chains without markers or summaries still fold (old sessions)', () {
      final ledger = foldChain([
        sessionHeaderLine('old-session'),
        userLine(1),
        assistantLine(2, usage: reportedUsage(input: 64, output: 32)),
        assistantLine(3, usage: reportedUsage(input: 36, output: 16)),
      ]);
      expect(ledger.segments.length, 1);
      expect(ledger.segments.single.totals.requests, 2);
      expect(ledger.segments.single.totals.input, 100);
    });

    test('a marker closing a contentful segment with nothing after it is '
        'not materialized (no zero-count trailing segment)', () {
      // Resume drive errors out before any request record lands: the
      // marker closed segment 0 and opened an empty segment 1. The
      // empty trailing segment must be trimmed — otherwise resumedCount
      // inflates (I1 noise) and the flush emits a zero-count fa-tokens
      // line labeled "reported".
      final ledger = foldChain([
        sessionHeaderLine('sess-1'),
        segmentMarkerLine(1),
        requestSummaryLine(2),
        assistantLine(3, usage: reportedUsage(input: 10, output: 5)),
        segmentMarkerLine(4), // closes segment 0; no records follow
      ]);
      expect(ledger.segments.length, 1);
      expect(ledger.resumedCount, 0);
      expect(ledger.total.totals.requests, 1);
      expect(ledger.total.totals.input, 10);
    });

    test('a header-only chain still yields ONE (empty) segment', () {
      final scan = const UsageChainScanner().scan([
        sessionHeaderLine('sess-1'),
      ]);
      expect(scan.segments.length, 1);
      expect(scan.segments.single.requests, isEmpty);
      final ledger = foldChain([sessionHeaderLine('sess-1')]);
      expect(ledger.segments.length, 1);
      expect(ledger.resumedCount, 0);
    });

    test('a non-message record (checkpoint/label/...) still stamps the '
        'segment closedAt', () {
      // The scan refactor dispatches per record type; a record that is
      // neither a marker, a summary, nor an assistant message must not
      // be dropped from the segment's timestamp window.
      final scan = const UsageChainScanner().scan([
        sessionHeaderLine('sess-1'),
        segmentMarkerLine(1),
        requestSummaryLine(2),
        assistantLine(3, usage: reportedUsage(input: 10, output: 5)),
        otherRecordLine(9),
      ]);
      expect(scan.segments.single.requests, hasLength(1));
      expect(scan.segments.single.closedAt, DateTime.utc(2024, 1, 1, 0, 9));
    });

    test(
      'a dangling summary (request died mid-flight) still counts, marked estimated',
      () {
        final ledger = foldChain([
          sessionHeaderLine('sess-1'),
          segmentMarkerLine(1),
          requestSummaryLine(2),
          assistantLine(3, usage: reportedUsage(input: 10, output: 5)),
          requestSummaryLine(4), // never produced an assistant message
        ]);
        final segment = ledger.segments.single;
        expect(segment.totals.requests, 2);
        expect(segment.source, UsageSource.mixed);
        expect(segment.byModel[unknownUsageModel], isNotNull);
      },
    );

    test('torn lines are skipped without breaking the fold', () {
      final ledger = foldChain([
        sessionHeaderLine('sess-1'),
        segmentMarkerLine(1),
        '{"type":"message","id":"broken"',
        requestSummaryLine(2),
        assistantLine(3, usage: reportedUsage(input: 10, output: 5)),
      ]);
      expect(ledger.segments.single.totals.requests, 1);
    });

    test(
      'blob records are skipped without decoding but still fingerprint the chain',
      () {
        final chain = [
          sessionHeaderLine('sess-1'),
          segmentMarkerLine(1),
          requestSummaryLine(2),
          wireDumpLine(3, payloadKb: 128),
          assistantLine(4, usage: reportedUsage(input: 10, output: 5)),
        ];
        final scan = const UsageChainScanner().scan(chain);
        expect(scan.recordCount, 4); // marker + summary + blob + assistant
        expect(scan.chainHash, startsWith('sha256:'));
        // The blob's payload contributes to the fingerprint: a different
        // blob invalidates the artifact (E3).
        final other = const UsageChainScanner().scan([
          ...chain.take(3),
          wireDumpLine(3, payloadKb: 129),
          chain.last,
        ]);
        expect(other.chainHash, isNot(scan.chainHash));
      },
    );
  });
}
