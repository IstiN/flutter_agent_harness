@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// gh-1412 review (rounds 1+2): the hidden `task_ledger` record is an
/// audit surface three times over — session JSONL, `task_ledger` wire
/// frame, bench trial sync (`agent-logs/fah-sessions`) — and its
/// free-text fields (`requirement`/`command`/`expected`/`actual`) quote
/// agent-authored verification commands and observed output. The
/// FinalizeGate contract + the unattended `credentialHuntNudge` actively
/// steer the agent toward credential material (`~/.aws/`, `~/.ssh/`,
/// env), so the record must pass through the host's redaction pipeline
/// before `appendCustomEntry` — the same convention the sibling
/// liveness/stuck records already follow (gh-1054 review).
void main() {
  const secret = 'sk-live-topsecret-credential-42';

  const ledgerAnswer = '''
Task complete.
```task-ledger
- requirement: key material \$key is gone
  command: echo "\$key"
  expected: empty output
  actual: sk-live-topsecret-credential-42
  status: pass
```
''';

  Future<List<CustomRecord>> runAndRecords({
    RedactionPipeline? pipeline,
  }) async {
    final env = MemoryExecutionEnv(cwd: '/work');
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    final io = FakeCliIO();
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        approvalMode: ApprovalMode.unattended,
        redactionPipeline: pipeline,
      ),
      io: io,
      streamFunction: FakeStreamFunction([textTurn(ledgerAnswer)]).call,
    );
    final exitCode = await cli.runHeadless('rotate the key');
    expect(exitCode, 0);
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final sessions = await repo.list(cwd: '/work');
    final session = await repo.open(sessions.first);
    final records = await session.getEntries();
    return [
      for (final record in records)
        if (record is CustomRecord && record.customType == 'task_ledger')
          record,
    ];
  }

  test('ledger free-text is redacted through the host pipeline', () async {
    final ledgers = await runAndRecords(
      pipeline: RedactionPipeline(registeredSecrets: [secret]),
    );
    expect(ledgers, hasLength(1), reason: 'the run persisted its ledger');
    final raw = ledgers.map((r) => r.data.toString()).join('\n');
    expect(raw, isNot(contains(secret)), reason: 'no raw secret in the record');
    expect(raw, contains('[REDACTED:'), reason: 'masked, not dropped');
  });

  test('structured fields survive the redaction pass intact', () async {
    final ledgers = await runAndRecords(
      pipeline: RedactionPipeline(registeredSecrets: [secret]),
    );
    final data = ledgers.single.data;
    expect(data, isA<Map>());
    final items = (data as Map)['items'] as List;
    expect(items, hasLength(1));
    final item = items.first as Map;
    expect(item['status'], 'pass');
    expect(item['requirement'], contains('[REDACTED:'));
    expect(item['actual'], contains('[REDACTED:'));
  });

  test('no pipeline: the record persists verbatim (byte-identical legacy)',
      () async {
    final ledgers = await runAndRecords();
    expect(ledgers, hasLength(1));
    final raw = ledgers.single.data.toString();
    expect(raw, contains(secret));
  });
}
