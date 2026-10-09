// gh-1449 AC6 — the HOST side of the one-shot orphan-report latch.
//
// The library-level latch is covered by tool_pairing_test /
// orphan_notice_loop_test; here the wiring runs through the real CLI:
// the resume seed (`_loadSession` → reportedOrphanKeys) and the persist
// path (`_persistToolLivenessRecord` appending the hidden orphan_report
// record), plus the per-session latch boundary (an Agent instance is
// reused across session switches).
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

final _at = DateTime.utc(2026, 1, 1, 12);

void main() {
  late FakeCliIO io;

  setUp(() {
    io = FakeCliIO();
  });
  tearDown(() => io.close());

  Future<MemoryExecutionEnv> freshEnv() async {
    final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    // Suppress session-start memory maintenance (suite convention) so the
    // scripted turns feed only the turn under test.
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    return env;
  }

  /// Seeds [name] with an orphan result whose originating call is gone
  /// (the production resume shape) and returns (metadata, latch key) —
  /// the key computed from the REBUILT context, i.e. exactly what the
  /// resumed loop will see.
  Future<(SessionMetadata, String)> seedOrphanSession(
    MemoryExecutionEnv env,
    String name,
  ) async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final seed = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await seed.appendSessionName(name);
    await seed.appendMessage(
      UserMessage.text('before the cut', timestamp: DateTime.utc(2026)),
    );
    await seed.appendMessage(
      ToolResultMessage(
        toolCallId: 'bash_198',
        toolName: 'bash',
        content: const [TextContent(text: 'ok')],
        timestamp: _at,
        isError: false,
      ),
    );
    final meta = await seed.getMetadata();
    final rebuilt = await (await repo.open(meta)).buildContextMessages();
    final orphan = rebuilt.whereType<ToolResultMessage>().single;
    return (meta, orphanReportKey(orphan));
  }

  AgentCli cliFor(MemoryExecutionEnv env, FakeStreamFunction stream) =>
      AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          skillsAccess: SkillsAccess.granted,
        ),
        io: io,
        streamFunction: stream.call,
      );

  List<String> noteTexts(Context context) => context.messages
      .whereType<UserMessage>()
      .map(messageText)
      .where((t) => t.contains('[context note:'))
      .toList();

  test('persist: a resumed session with a fresh orphan notes it on the '
      'request and appends the orphan_report record', () async {
    final env = await freshEnv();
    final (meta, key) = await seedOrphanSession(env, 'orphan-live');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final stream = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(env, stream);
    final run = cli.run();
    io.sendLine('go');
    await waitForIt(
      () => stream.calls >= 1 && !cli.isBusy,
      reason: 'the resumed session answers one turn',
    );
    io.sendLine('/exit');
    await run;

    // The note reached the request, riding a user message.
    final notes = noteTexts(stream.contexts.first);
    expect(
      notes,
      hasLength(1),
      reason: [
        for (final m in stream.contexts.first.messages)
          '${m.runtimeType}: ${m is UserMessage ? messageText(m) : m is ToolResultMessage ? (m as ToolResultMessage).toolCallId : '…'}',
      ].join(' | '),
    );
    expect(notes.single, contains('bash_198'));
    expect(notes.single, contains('kept in summary'));

    // AC6: the FIRST-TIME batch was persisted as the hidden record.
    final records = await repo.readCustomRecordsOfType(meta, {
      orphanReportRecordType,
    });
    expect(
      orphanReportKeysFromRecords(records),
      {key},
      reason: 'session file: ${(await env.readTextFile(meta.path)).getOrThrow()}',
    );
  });

  test('seed: a resumed session whose orphan_report record holds the key '
      'does not re-note and appends nothing', () async {
    final env = await freshEnv();
    final (meta, key) = await seedOrphanSession(env, 'orphan-recorded');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    // The prior process reported this orphan: the record exists BEFORE
    // the resume.
    final writer = await repo.open(meta);
    await writer.appendCustomEntry(
      customType: orphanReportRecordType,
      data: orphanReportRecordData({key}),
    );
    final recordsBefore = await repo.readCustomRecordsOfType(meta, {
      orphanReportRecordType,
    });

    final stream = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(env, stream);
    final run = cli.run();
    io.sendLine('go');
    await waitForIt(
      () => stream.calls >= 1 && !cli.isBusy,
      reason: 'the resumed session answers one turn',
    );
    io.sendLine('/exit');
    await run;

    // The orphan was still dropped from the payload…
    expect(
      stream.contexts.first.messages.whereType<ToolResultMessage>(),
      isEmpty,
    );
    // …silently: no note anywhere in the request.
    expect(noteTexts(stream.contexts.first), isEmpty);
    // And the re-report wrote nothing.
    final recordsAfter = await repo.readCustomRecordsOfType(meta, {
      orphanReportRecordType,
    });
    expect(recordsAfter, hasLength(recordsBefore.length));
  });

  test('the latch is per-session: session A\'s report never suppresses '
      'session B\'s first report of the same-shaped orphan', () async {
    final env = await freshEnv();
    // SAME orphan shape (tool/id/timestamp ⇒ the same latch key) in both
    // sessions; only A carries the orphan_report record.
    await seedOrphanSession(env, 'orphan-a');
    final (bMeta, _) = await seedOrphanSession(env, 'orphan-b');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    expect(
      await repo.readCustomRecordsOfType(bMeta, {orphanReportRecordType}),
      isEmpty,
    );

    final stream = FakeStreamFunction([textTurn('ok'), textTurn('ok')]);
    final cli = cliFor(env, stream);
    final run = cli.run();
    io.sendLine('go');
    await waitForIt(
      () => stream.calls >= 1 && !cli.isBusy,
      reason: 'session A answers its turn',
    );
    io.sendLine('/session orphan-b');
    await waitForIt(
      () => io.out.toString().contains("switched to session 'orphan-b'"),
      reason: 'the switch loads session B on the SAME Agent',
    );
    io.sendLine('go');
    await waitForIt(
      () => stream.calls >= 2 && !cli.isBusy,
      reason: 'session B answers its turn',
    );
    io.sendLine('/exit');
    await run;

    // Without the per-session clear, A's key lingers in the reused
    // Agent's latch and B's legitimate first report is silently dropped.
    expect(noteTexts(stream.contexts[1]), hasLength(1));
  });
}
