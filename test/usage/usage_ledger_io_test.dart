// gh-1241 usage.json persistence: atomic tmp+rename via ExecutionEnv,
// the E3 stale/corrupt detection, and the I4 byte-scan gate on writes.

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'usage_chain_fixtures.dart';

UsageLedger buildLedger(List<String> chain, {String sessionId = 'sess-1'}) =>
    const UsageChainFolder().foldChain(sessionId: sessionId, lines: chain);

List<String> simpleChain() => [
  sessionHeaderLine('sess-1'),
  segmentMarkerLine(1),
  requestSummaryLine(2),
  assistantLine(3, usage: reportedUsage(input: 100, output: 50)),
];

void main() {
  group('UsageLedgerWriter', () {
    test('writes usage.json atomically (no tmp left behind)', () async {
      final env = MemoryExecutionEnv();
      final ledger = buildLedger(simpleChain());
      await UsageLedgerWriter(env).write('/sessions/sess-1', ledger);
      final read = await env.readTextFile('/sessions/sess-1/usage.json');
      expect(read.isOk, isTrue);
      expect(
        jsonDecode(read.valueOrNull!) as Map<String, dynamic>,
        ledger.toJson(),
      );
      // The tmp name is gone after the rename.
      final tmp = await env.fileInfo('/sessions/sess-1/.usage.json.tmp');
      expect(tmp.isErr || tmp.valueOrNull?.kind != FileKind.file, isTrue);
    });

    test('concurrent writers use unique tmp names (E2) and the last rename wins', () async {
      final env = MemoryExecutionEnv();
      final ledger = buildLedger(simpleChain());
      await Future.wait([
        UsageLedgerWriter(env).write('/sessions/sess-1', ledger, tmpSuffix: 'p1'),
        UsageLedgerWriter(env).write('/sessions/sess-1', ledger, tmpSuffix: 'p2'),
      ]);
      final read = await env.readTextFile('/sessions/sess-1/usage.json');
      expect(read.isOk, isTrue);
      expect(
        UsageLedger.fromJson(
          jsonDecode(read.valueOrNull!) as Map<String, dynamic>,
        ).chainHash,
        ledger.chainHash,
      );
    });

    test('write is byte-deterministic for the same chain (I6)', () async {
      final env = MemoryExecutionEnv();
      final a = buildLedger(simpleChain());
      final b = buildLedger(simpleChain());
      await UsageLedgerWriter(env).write('/s1', a);
      await UsageLedgerWriter(env).write('/s2', b);
      final ra = await env.readTextFile('/s1/usage.json');
      final rb = await env.readTextFile('/s2/usage.json');
      expect(ra.valueOrNull, rb.valueOrNull);
    });

    test('a secret in the artifact fails the write and touches nothing (I4/UT-6)', () async {
      final env = MemoryExecutionEnv();
      final ledger = buildLedger(simpleChain());
      expect(
        () => UsageLedgerWriter(env).write(
          '/sessions/sess-1',
          ledger,
          forbiddenSecrets: const ['sess-1'],
        ),
        throwsA(isA<UsageHygieneException>()),
      );
      final leaked = await env.readTextFile('/sessions/sess-1/usage.json');
      expect(leaked.isErr, isTrue);
    });

    test('readIfValid returns the ledger only when the chain fingerprint matches (E3)', () async {
      final env = MemoryExecutionEnv();
      final ledger = buildLedger(simpleChain());
      final dir = '/sessions/sess-1';
      final writer = UsageLedgerWriter(env);
      await writer.write(dir, ledger);

      final valid = await writer.readIfValid(
        dir,
        expectedRecords: ledger.chainRecords,
        expectedHash: ledger.chainHash,
      );
      expect(valid?.chainHash, ledger.chainHash);

      // Chain grew (resume appended a segment): the artifact is stale.
      final stale = await writer.readIfValid(
        dir,
        expectedRecords: ledger.chainRecords + 1,
        expectedHash: ledger.chainHash,
      );
      expect(stale, isNull);

      // Hand-edited artifact (hash mismatch): never merged into garbage.
      final tampered = await writer.readIfValid(
        dir,
        expectedRecords: ledger.chainRecords,
        expectedHash: 'sha256:forged',
      );
      expect(tampered, isNull);
    });

    test('readIfValid returns null for a missing or corrupt file', () async {
      final env = MemoryExecutionEnv();
      expect(
        await UsageLedgerWriter(env).readIfValid(
          '/nope',
          expectedRecords: 0,
          expectedHash: '',
        ),
        isNull,
      );
      await env.createDir('/sessions/sess-1', recursive: true);
      await env.writeFile('/sessions/sess-1/usage.json', '{not json');
      expect(
        await UsageLedgerWriter(env).readIfValid(
          '/sessions/sess-1',
          expectedRecords: 0,
          expectedHash: '',
        ),
        isNull,
      );
    });
  });

  group('usageDirFor', () {
    test('resolves the documented per-session surface', () {
      expect(
        UsageLedgerWriter.usageDirFor(
          sessionsRoot: '/home/u/.fah/sessions',
          sessionId: 'abc-123',
        ),
        '/home/u/.fah/sessions/abc-123',
      );
    });
  });
}
