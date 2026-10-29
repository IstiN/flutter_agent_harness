@TestOn('vm')
/// gh-1956 — reply auto-spill: an oversized child reply spills to an
/// artifact automatically (default path), the parent receives a bounded
/// excerpt + `agent://` pointer + completeness marker with byte counts,
/// the excerpt ends at a natural boundary when possible, manual chunking
/// degrades to fallback behind the `subagents.replyAutoSpill` kill
/// switch, and a spilled artifact survives parent resume (durable
/// `deliverable_artifact` records).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

final class _Rig {
  _Rig(this.manager, this.store, this.capture);

  final SubagentManager manager;
  final AgentOutputStore store;
  final DeliverableCapture capture;
}

_Rig _rig({
  int cap = 200,
  String Function(String text)? redact,
  String childId = 'kid',
  bool Function()? autoSpill,
  Future<void> Function(Map<String, dynamic> artifact)? persistArtifact,
  Future<List<Map<String, dynamic>>> Function()? restoreArtifacts,
}) {
  final manager = SubagentManager(parentSessionId: 'p', maxReplyChars: cap);
  manager.register(id: childId, name: childId, agentType: 'task', task: 't');
  final store = AgentOutputStore();
  final capture = DeliverableCapture(
    store: store,
    manager: manager,
    redact: redact,
    autoSpill: autoSpill,
    persistArtifact: persistArtifact,
    restoreArtifacts: restoreArtifacts,
  );
  return _Rig(manager, store, capture);
}

String _text(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join('\n');

/// Minimal in-memory fabric so `agent_message` can reach `main`.
final class _FakeFabric implements MessagingRepository {
  final _inboxes = <String, List<AgentMessage>>{};

  List<AgentMessage> inbox(String mailbox) =>
      List.unmodifiable(_inboxes[mailbox] ?? const []);

  @override
  Future<void> send(AgentMessage message) async =>
      _inboxes.putIfAbsent(message.toId, () => []).add(message);

  @override
  Future<List<AgentMessage>> peek(String agentId) async => inbox(agentId);

  @override
  Future<List<AgentMessage>> drain(String agentId) async =>
      List.unmodifiable(_inboxes.remove(agentId) ?? const []);

  @override
  Future<void> register(
    String agentId, {
    String? sessionName,
    List<AgentCapability> capabilities = const [],
  }) async {}

  @override
  Future<void> touch(String agentId, {bool busy = false}) async {}

  @override
  Future<List<MailboxEntry>> directory() async => const [];
}

({
  SubagentManager manager,
  AgentOutputStore store,
  Map<String, AgentTool> tools,
})
_toolsRig({
  int cap = 200,
  bool Function()? autoSpill,
  DeliverableCapture? capture,
  _FakeFabric? fabric,
}) {
  final manager = SubagentManager(
    parentSessionId: 'p',
    maxReplyChars: cap,
    messaging: fabric,
  );
  manager.register(id: 'kid', name: 'kid', agentType: 'task', task: 't');
  final store = AgentOutputStore();
  final effective =
      capture ??
      DeliverableCapture(store: store, manager: manager, autoSpill: autoSpill);
  final tools = {
    for (final t in subagentMonitoringTools(
      manager: manager,
      currentSubagentId: () => 'kid',
      capture: () => capture ?? effective,
    ))
      t.name: t,
  };
  return (manager: manager, store: store, tools: tools);
}

void main() {
  group('kill switch — auto-spill is the default, chunking the fallback', () {
    test('spill is enabled by default', () {
      final rig = _rig();
      expect(rig.capture.spillEnabled, isTrue);
    });

    test('a disabled switch stops the reply spill entirely', () {
      final rig = _rig(cap: 100, autoSpill: () => false);
      final record = rig.capture.deliverReply('kid', 'x' * 500);
      expect(record, isNull);
      expect(rig.store.availableIds, isEmpty);
      expect(
        rig.manager['kid']!.deliverables.where((r) => r.pointer != null),
        isEmpty,
      );
    });

    test('a disabled switch stops the agent_message spill too', () {
      final rig = _rig(cap: 100, autoSpill: () => false);
      final record = rig.capture.deliverAgentMessage(
        childId: 'kid',
        target: 'main',
        body: 'y' * 500,
      );
      expect(record, isNull);
      expect(rig.store.availableIds, isEmpty);
    });

    test('the chunk protocol keeps working under the kill switch', () {
      final rig = _rig(cap: 100, autoSpill: () => false);
      rig.capture.deliverAgentMessage(
        childId: 'kid',
        target: 'main',
        body: 'part',
        reportId: 'r1',
        partIndex: 0,
      );
      rig.capture.deliverReply('kid', 'm', reportId: 'r1', reportParts: 1);
      final kinds = rig.manager['kid']!.deliverables.map((r) => r.kind);
      expect(kinds, contains(DeliverableRecordKind.chunk));
      expect(kinds, contains(DeliverableRecordKind.manifest));
      expect(rig.manager['kid']!.deliverables.last.manifestComplete, isTrue);
    });

    test('the spill-reach gate answers under its public name (gh-1956 '
        'review: barrel-exported API, no post-release rename)', () {
      final rig = _rig();
      // Same-session handle: an agent:// pointer can reach it.
      expect(rig.capture.spillAppliesTo('kid'), isTrue);
      // The parent inbox: reachable too.
      expect(rig.capture.spillAppliesTo('main'), isTrue);
      // A2A and cross-instance addresses: never spill targets (E11).
      expect(rig.capture.spillAppliesTo('bot@remote'), isFalse);
      expect(rig.capture.spillAppliesTo('other/main'), isFalse);
    });
  });

  group('reply tool — graceful chunk fallback without artifact storage', () {
    test(
      'over-cap reply with the kill switch delivers truncated + notice',
      () async {
        final rig = _toolsRig(cap: 100, autoSpill: () => false);
        final result = await rig.tools['reply']!.execute(
          {'message': 'z' * 500},
          null,
          null,
        );
        final ack = _text(result);
        // Truthful: names the truncation, never claims artifact delivery.
        expect(ack, contains('truncated'));
        expect(ack, contains('100'));
        expect(ack, isNot(contains('agent://')));
        expect(ack, contains('agent_message'));
        // Legacy bare cap applies to the recorded reply (pure-chunk restore).
        expect(rig.manager['kid']!.lastReply, startsWith('z' * 100));
        expect(rig.manager['kid']!.lastReply, contains('…[truncated]'));
        expect(rig.store.availableIds, isEmpty);
      },
    );

    test(
      'over-cap reply without a capture degrades to the same notice',
      () async {
        final bare = SubagentManager(parentSessionId: 'p', maxReplyChars: 100);
        bare.register(id: 'kid', name: 'kid', agentType: 'task', task: 't');
        // Host without artifact storage: no capture provider wired at all.
        final tools = {
          for (final t in subagentMonitoringTools(
            manager: bare,
            currentSubagentId: () => 'kid',
          ))
            t.name: t,
        };
        final result = await tools['reply']!.execute(
          {'message': 'z' * 500},
          null,
          null,
        );
        final ack = _text(result);
        expect(ack, contains('truncated'));
        expect(ack, contains('agent_message'));
        expect(ack, isNot(contains('agent://')));
      },
    );

    test('in-budget reply stays verbatim under the kill switch', () async {
      final rig = _toolsRig(cap: 100, autoSpill: () => false);
      final result = await rig.tools['reply']!.execute(
        {'message': 'short answer'},
        null,
        null,
      );
      expect(_text(result), 'reply delivered to the parent');
      expect(rig.manager['kid']!.lastReply, 'short answer');
    });

    test('over-cap same-session agent_message gets the chunk notice', () async {
      final fabric = _FakeFabric();
      final rig = _toolsRig(cap: 100, autoSpill: () => false, fabric: fabric);
      final result = await rig.tools['agent_message']!.execute(
        {'to': 'main', 'message': 'b' * 500},
        null,
        null,
      );
      final ack = _text(result);
      expect(ack, contains('message queued for "main"'));
      expect(ack, contains('exceeds the 100-char budget'));
      expect(ack, contains('part_index'));
    });
  });

  group('natural excerpt boundary (edge case)', () {
    test('the excerpt ends at a paragraph boundary when one is in window', () {
      final rig = _rig(cap: 200);
      final body = '${'a' * 105}\n\n${'q' * 300}';
      final record = rig.capture.deliverReply('kid', body)!;
      final envelope = rig.capture.envelopeText(record);
      expect(envelope.length, lessThanOrEqualTo(200));
      // The cut lands at the blank-line paragraph break: the first
      // section in full, never a partial next-paragraph fragment.
      expect(envelope, startsWith('${'a' * 105}\n'));
      expect(envelope, isNot(contains('qq')));
    });

    test('the excerpt ends at a line boundary as the fallback', () {
      final rig = _rig(cap: 200);
      final body = '${'a' * 130}\n${'z' * 300}';
      final record = rig.capture.deliverReply('kid', body)!;
      final envelope = rig.capture.envelopeText(record);
      expect(envelope, startsWith('a' * 100));
      expect(envelope, contains('${'a' * 130}…'));
      expect(envelope, isNot(contains('zz')));
    });

    test('no boundary in window keeps the bounded raw cut', () {
      final rig = _rig(cap: 200);
      final body = '${'a' * 10}\n${'b' * 400}';
      final record = rig.capture.deliverReply('kid', body)!;
      final envelope = rig.capture.envelopeText(record);
      expect(envelope.length, lessThanOrEqualTo(200));
      expect(envelope, contains('bbb'));
      expect(envelope, contains('…'));
    });
  });

  group('byte counts (AC1/AC4)', () {
    test('the stored artifact is byte-identical to the reply body', () {
      final rig = _rig(cap: 100);
      final body = 'plain ascii body ' * 40;
      final record = rig.capture.deliverReply('kid', body)!;
      expect(utf8.encode(rig.store.get(record.outputId!)!), utf8.encode(body));
    });

    test('multi-byte content counts UTF-8 bytes, never splits a rune', () {
      final rig = _rig(cap: 120);
      final body = '漢字テスト' * 60; // 3 bytes per rune, far over the cap.
      final record = rig.capture.deliverReply('kid', body)!;
      final stored = rig.store.get(record.outputId!)!;
      expect(record.bytes, utf8.encode(stored).length);
      expect(record.chars, stored.length);
      expect(record.bytes, greaterThan(record.chars));
      // The excerpt stays rune-clean.
      final envelope = rig.capture.envelopeText(record);
      for (var i = 0; i < envelope.length; i++) {
        final unit = envelope.codeUnitAt(i);
        final isLoneLow = unit >= 0xDC00 && unit <= 0xDFFF;
        final prevHigh =
            i > 0 &&
            envelope.codeUnitAt(i - 1) >= 0xD800 &&
            envelope.codeUnitAt(i - 1) <= 0xDBFF;
        expect(isLoneLow && !prevHigh, isFalse);
      }
    });

    test('the child ack names the ref with the byte count', () async {
      final rig = _toolsRig(cap: 100);
      final result = await rig.tools['reply']!.execute(
        {'message': 'body ' * 100},
        null,
        null,
      );
      final record = rig.manager['kid']!.deliverables.single;
      expect(_text(result), contains('agent://${record.outputId}'));
      expect(_text(result), contains('${record.bytes} bytes'));
    });

    test('the envelope status line and render carry the byte count', () {
      final rig = _rig(cap: 200);
      final record = rig.capture.deliverReply('kid', 'x' * 250)!;
      final envelope = rig.capture.envelopeText(record);
      expect(envelope, contains('${record.bytes} bytes'));
      expect(
        record.render(),
        'deliverable complete: agent://${record.outputId} '
        '(250 chars, ${record.bytes} bytes)',
      );
    });

    test('a legacy external constructor without bytes still compiles and '
        'renders chars-only (gh-1956 review: barrel-exported type, the '
        'package is published)', () {
      // Out-of-repo callers built DeliverableRecord.artifact(...) before
      // gh-1956; the new field must not break their compile.
      final record = DeliverableRecord.artifact(
        childId: 'kid',
        outputId: 'kid-report',
        status: AgentArtifactStatus.complete,
        chars: 120,
      );
      expect(record.bytes, isNull);
      expect(
        record.render(),
        'deliverable complete: agent://kid-report (120 chars)',
      );
      // The harness-owned spill path still carries the byte count.
      final rig = _rig(cap: 200);
      final spilled = rig.capture.deliverReply('kid', 'x' * 250)!;
      expect(spilled.bytes, isNotNull);
      expect(
        spilled.render(),
        contains('(${spilled.chars} chars, ${spilled.bytes} bytes)'),
      );
    });
  });

  group('boundary at the spill threshold (AC4)', () {
    for (final (label, len, spills) in [
      ('threshold-1 stays verbatim', 99, false),
      ('threshold stays verbatim', 100, false),
      ('threshold+1 spills', 101, true),
    ]) {
      test(label, () {
        final rig = _rig(cap: 100);
        final record = rig.capture.deliverReply('kid', 'a' * len);
        if (spills) {
          expect(record, isNotNull);
          expect(
            utf8.encode(rig.store.get(record!.outputId!)!),
            utf8.encode('a' * len),
          );
        } else {
          expect(record, isNull);
          expect(rig.store.availableIds, isEmpty);
        }
      });
    }
  });

  group('durable artifacts — spilled report survives parent resume (AC6)', () {
    test(
      'a spill persists a restorable artifact row through the sink',
      () async {
        final rows = <Map<String, dynamic>>[];
        final rig = _rig(
          cap: 100,
          persistArtifact: (row) async => rows.add(row),
        );
        final record = rig.capture.deliverReply('kid', 'r' * 500)!;
        await Future<void>.delayed(Duration.zero);
        expect(rows, hasLength(1));
        expect(rows.single['id'], record.outputId);
        expect(rows.single['content'], 'r' * 500);
        expect(rows.single['status'], 'complete');
        expect(rows.single['childId'], 'kid');
        expect(rows.single['chars'], 500);
      },
    );

    test('the pointer resolves from a fresh store after restore', () async {
      final record = _rig(cap: 100).capture.deliverReply('kid', 'r' * 500)!;
      // Simulated restart: a fresh store + capture fed by the persisted
      // rows — the parent-side read path resolves the full text.
      final restoredRows = <Map<String, dynamic>>[
        {
          'id': record.outputId,
          'content': 'r' * 500,
          'status': 'complete',
          'childId': 'kid',
          'chars': 500,
        },
      ];
      final rig = _rig(cap: 100, restoreArtifacts: () async => restoredRows);
      await rig.capture.ensureRestored();
      final resolution = resolveAgentUrl(
        'agent://${record.outputId}',
        rig.store,
      );
      expect(resolution.content, 'r' * 500);
      expect(resolution.notes.single, contains('deliverable: complete'));
    });

    test(
      'a restored id stays reserved — a new reply gets a new artifact',
      () async {
        final old = _rig(cap: 100).capture.deliverReply('kid', 'old' * 200)!;
        final rig = _rig(
          cap: 100,
          restoreArtifacts: () async => [
            {
              'id': old.outputId,
              'content': 'old' * 200,
              'status': 'complete',
              'childId': 'kid',
              'chars': 600,
            },
          ],
        );
        await rig.capture.ensureRestored();
        final fresh = rig.capture.deliverReply('kid', 'new' * 200)!;
        // Distinct artifact, no interleaving with the immutable old one.
        expect(fresh.outputId, isNot(old.outputId));
        expect(rig.store.get(old.outputId!), 'old' * 200);
        expect(rig.store.get(fresh.outputId!), 'new' * 200);
      },
    );

    test(
      'a live artifact wins over a stale restore row with the same id',
      () async {
        final rig = _rig(
          cap: 100,
          restoreArtifacts: () async => [
            {
              'id': 'kid-report',
              'content': 'stale',
              'status': 'complete',
              'childId': 'kid',
              'chars': 5,
            },
          ],
        );
        // Live spill FIRST: allocate + put under the plain id.
        final live = rig.capture.deliverReply('kid', 'live' * 100)!;
        await rig.capture.ensureRestored();
        expect(live.outputId, 'kid-report');
        expect(rig.store.get('kid-report'), 'live' * 100);
      },
    );

    test('a failed restore degrades without breaking the capture', () async {
      final rig = _rig(
        cap: 100,
        restoreArtifacts: () async => throw StateError('disk gone'),
      );
      await rig.capture.ensureRestored();
      final record = rig.capture.deliverReply('kid', 'x' * 500);
      expect(record, isNotNull);
      expect(rig.store.get(record!.outputId!), 'x' * 500);
    });

    test(
      'the salvage hook restores durable rows before allocating an id',
      () async {
        // The post-resume race (review, gh-1956): the boot kick's restore
        // is still in flight when the first deliverable-path event is an
        // OUTPUT-TRUNCATED call — flow B's salvage persist allocates an
        // id, and an un-restored allocator hands out the restored row's
        // id, shadowing the durable content (first-write-wins then drops
        // the restored artifact; the pointer flips across restarts).
        final durable = {
          'id': 'kid-report',
          'content': 'durable text',
          'status': 'complete',
          'childId': 'kid',
          'chars': 'durable text'.length,
        };
        var release = Completer<void>();
        final rig = _rig(
          cap: 100,
          restoreArtifacts: () => release.future.then((_) => [durable]),
        );
        final salvage = rig.capture.captureSalvaged(
          'kid',
          ToolCall(
            id: 'c1',
            name: 'reply',
            arguments: {'message': 'salvaged ' * 30},
          ),
        );
        // The salvage must not allocate until the restore lands.
        expect(rig.store.availableIds, isEmpty);
        release.complete();
        await salvage;
        // The durable row kept its id and its content — the salvaged
        // partial artifact got a DISTINCT id.
        expect(rig.store.get('kid-report'), 'durable text');
        final record = rig.manager['kid']!.deliverables.single;
        expect(record.status, AgentArtifactStatus.partial);
        expect(record.outputId, isNot('kid-report'));
        expect(rig.store.get(record.outputId!), contains('salvaged'));
      },
    );

    test(
      'a failed persist emits a durability diagnostic through the host sink',
      () async {
        final lines = <String>[];
        final previous = deliverableDurabilityLog;
        deliverableDurabilityLog = lines.add;
        try {
          final rig = _rig(
            cap: 100,
            persistArtifact: (row) async => throw StateError('disk full'),
          );
          final record = rig.capture.deliverReply('kid', 'x' * 500)!;
          await Future<void>.delayed(Duration.zero);
          // AC3 stands (in-session delivery is uncorrupted), but the loss
          // is no longer silent: one diagnosable line names the failure.
          expect(rig.store.get(record.outputId!), 'x' * 500);
          expect(lines, hasLength(1));
          expect(lines.single, contains('[deliverables]'));
          expect(lines.single, contains('artifact persist failed'));
          expect(lines.single, contains('disk full'));
        } finally {
          deliverableDurabilityLog = previous;
        }
      },
    );

    test('a failed persist stays silent when no host sink is wired', () async {
      final previous = deliverableDurabilityLog;
      deliverableDurabilityLog = null;
      try {
        final rig = _rig(
          cap: 100,
          persistArtifact: (row) async => throw StateError('disk full'),
        );
        final record = rig.capture.deliverReply('kid', 'x' * 500)!;
        await Future<void>.delayed(Duration.zero);
        expect(rig.store.get(record.outputId!), 'x' * 500);
      } finally {
        deliverableDurabilityLog = previous;
      }
    });

    test('a failed artifact persist does not corrupt the delivery', () async {
      final rig = _rig(
        cap: 100,
        persistArtifact: (row) async => throw StateError('disk full'),
      );
      final record = rig.capture.deliverReply('kid', 'x' * 500)!;
      // In-session delivery still works; only durability was lost.
      expect(rig.store.get(record.outputId!), 'x' * 500);
    });

    test('concurrent replies from two children spill distinct artifacts', () {
      final first = _rig(cap: 100, childId: 'kid1');
      final second = _rig(cap: 100, childId: 'kid2');
      final a = first.capture.deliverReply('kid1', 'a' * 500)!;
      final b = second.capture.deliverReply('kid2', 'b' * 500)!;
      expect(a.outputId, isNot(b.outputId));
      expect(first.store.get(a.outputId!), 'a' * 500);
      expect(second.store.get(b.outputId!), 'b' * 500);
      // No interleaving: each store holds exactly its own artifact.
      expect(first.store.availableIds, [a.outputId]);
      expect(second.store.availableIds, [b.outputId]);
    });
  });

  group('child contract prompt — auto-spill default, chunking fallback', () {
    test('the spill-on contract advertises automatic spill', () {
      final text = deliverableChunkContract(8000);
      expect(text, contains('8000'));
      expect(text, contains('spill'));
      expect(text, contains('agent://'));
      expect(text.toLowerCase(), contains('fallback'));
      expect(text, contains('report_id'));
    });

    test('the pure-chunk contract (kill switch) mandates manual chunking', () {
      final text = deliverableChunkContract(8000, autoSpill: false);
      expect(text, contains('8000'));
      expect(text, contains('Split a long report'));
      expect(text, isNot(contains('spill')));
      expect(text, contains('report_id'));
    });
  });
}
