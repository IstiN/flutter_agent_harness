// gh-1241 CLI wiring tests: a headless run over the fake provider leaves
// the usage ledger behind — the IT-2/IT-3/IT-7 shapes at the CLI level:
// segment marker on boot, usage.json after close, `fa-tokens:` log line
// per segment close, resume semantics (ONE record, resumedCount bump),
// and the `/usage rebuild` command path.

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

Usage reportedUsage({int input = 100, int output = 50}) => Usage(
  input: input,
  output: output,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: input + output,
  cost: const UsageCost(),
);

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor(
    List<List<AssistantMessageEvent>> turns, {
    String? sessionName,
  }) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      homeDir: '/home',
      sessionName: sessionName,
      providerKind: 'openai-completions',
    ),
    io: io,
    streamFunction: FakeStreamFunction(turns).call,
    version: '0.0.0-test',
  );

  Future<UsageLedger?> readLedger(String sessionId) async {
    final read = await env.readTextFile('/sessions/$sessionId/usage.json');
    if (read.isErr) return null;
    return UsageLedger.fromJson(
      jsonDecode(read.valueOrNull!) as Map<String, dynamic>,
    );
  }

  test(
    'the fa-tokens line carries the session model id (gh-1460 AC1/AC4)',
    () async {
      final cli = cliFor([textTurn('ok', usage: reportedUsage())]);
      expect(await cli.runHeadless('say hi'), 0);

      final log = (await env.readTextFile(
        '/home/.fah/logs/fa.log',
      )).valueOrNull!;
      final lines = log
          .split('\n')
          .where((line) => line.contains('fa-tokens: '))
          .toList();
      expect(lines, hasLength(1));
      final payload = 'fa-tokens: ${lines.single.split('fa-tokens: ').last}';
      // The model id is the one the assistant message records — the same
      // string the settings/UI display.
      expect(payload, contains('"model":"test-model"'));
      expect(usageTokensLogPattern.hasMatch(payload), isTrue);
    },
  );

  test(
    'a headless run leaves usage.json and one fa-tokens log line (AC1/AC7)',
    () async {
      final cli = cliFor([textTurn('ok', usage: reportedUsage())]);
      final exit = await cli.runHeadless('say hi');
      expect(exit, 0);

      final sessions = await JsonlSessionRepo(
        fs: env,
        sessionsRoot: '/sessions',
      ).list();
      expect(sessions, hasLength(1));
      final sessionId = sessions.single.id;

      final ledger = await readLedger(sessionId);
      expect(ledger, isNotNull);
      expect(ledger!.resumedCount, 0);
      expect(ledger.segments.length, 1);
      expect(ledger.segments.single.totals.requests, 1);
      expect(ledger.segments.single.totals.input, 100);
      expect(ledger.segments.single.totals.output, 50);
      expect(ledger.segments.single.source, UsageSource.reported);
      expect(ledger.total.totals.input, 100);
      // I4: the artifact is schema-shaped only.
      expect(
        jsonEncode(ledger.toJson()),
        isNot(contains('[REDACTED:Sensitive Value]')),
      );

      final log = (await env.readTextFile(
        '/home/.fah/logs/fa.log',
      )).valueOrNull!;
      final lines = log
          .split('\n')
          .where((line) => line.contains('fa-tokens: '))
          .toList();
      expect(lines, hasLength(1));
      // The reporter's pinned regex parses the line (the log prefixes a
      // timestamp, so re-join prefix + payload for the shape check).
      final payload = 'fa-tokens: ${lines.single.split('fa-tokens: ').last}';
      expect(usageTokensLogPattern.hasMatch(payload), isTrue);
    },
  );

  test('headless run mirrors the fa-tokens line to the run-log channel, '
      'stdout stays prose (gh-1292)', () async {
    // Split-channel headless IO (write = pipeable stdout, writeln =
    // diagnostics → stderr on real hosts): the round-1 stdout mirror
    // reded the headless_cli/markdown_surface/headless_hep exact-stdout
    // suites — the line rides the diagnostics channel ONLY, and the
    // reporter still finds it (it greps the whole GH job log, stderr
    // included).
    final splitIo = SplitChannelCliIO();
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        homeDir: '/home',
        providerKind: 'openai-completions',
      ),
      io: splitIo,
      streamFunction: FakeStreamFunction([
        textTurn('ok', usage: reportedUsage()),
      ]).call,
      version: '0.0.0-test',
    );
    expect(await cli.runHeadless('say hi'), 0);

    // Stdout carries nothing but the assistant prose (issue #774 AC3).
    expect(splitIo.out.toString(), 'ok\n');

    // The diagnostics channel carries exactly one segment-close line,
    // matching the reporter's pinned regex with no timestamp prefix.
    final lines = splitIo.diag
        .toString()
        .split('\n')
        .where((line) => line.contains(usageTokensLogPrefix))
        .toList();
    expect(lines, hasLength(1));
    expect(usageTokensLogPattern.hasMatch(lines.single), isTrue);

    // The diag-file write is unchanged.
    final log = (await env.readTextFile('/home/.fah/logs/fa.log')).valueOrNull!;
    expect(log, contains(usageTokensLogPrefix));
  });

  test('a TUI-attached session keeps stdout clean — the fa-tokens line '
      'stays in the diag log only (gh-1292 guard)', () async {
    final tuiIo = FakeCliIO();
    addTearDown(tuiIo.close);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        homeDir: '/home',
        providerKind: 'openai-completions',
      ),
      io: tuiIo,
      streamFunction: FakeStreamFunction([
        textTurn('ok', usage: reportedUsage()),
      ]).call,
      useTui: true,
      version: '0.0.0-test',
    );
    expect(await cli.runHeadless('say hi'), 0);

    expect(tuiIo.out.toString(), isNot(contains(usageTokensLogPrefix)));
    // The diag-file write stays (the guard only disables the mirror).
    final log = (await env.readTextFile('/home/.fah/logs/fa.log')).valueOrNull!;
    expect(log, contains(usageTokensLogPrefix));
  });

  test('stream-json mode keeps the NDJSON wire free of the fa-tokens line '
      '(gh-1292)', () async {
    // The real host wraps the terminal io in HepEventsIO for
    // structured modes (bin/fah_runapp.dart: prose writes are
    // dropped, frames own stdout) — mirror that wiring here.
    final rawIo = SplitChannelCliIO();
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        homeDir: '/home',
        providerKind: 'openai-completions',
      ),
      io: HepEventsIO(rawIo),
      streamFunction: FakeStreamFunction([
        textTurn('ok', usage: reportedUsage()),
      ]).call,
      version: '0.0.0-test',
    );
    final lines = <String>[];
    final code = await cli.runHeadless(
      'say hi',
      streamJson: StreamJsonWriter(emit: lines.add),
    );
    expect(code, 0);
    expect(lines, isNotEmpty);
    // Structured modes own stdout exclusively — every emitted line
    // must stay machine-parseable NDJSON.
    expect(lines.where((line) => line.contains(usageTokensLogPrefix)), isEmpty);
    // HepEventsIO drops write and forwards writeln: raw stdout stays
    // empty (the frames carry everything), while the mirror line rides
    // the host's diagnostics channel (stderr headless) — the run-log
    // capture still sees it in structured modes.
    expect(rawIo.out.toString(), isEmpty);
    expect(rawIo.diag.toString(), contains(usageTokensLogPrefix));
    // The line still reached the diag log.
    final log = (await env.readTextFile('/home/.fah/logs/fa.log')).valueOrNull!;
    expect(log, contains(usageTokensLogPrefix));
  });

  test('an interactive REPL exit keeps stdout clean — the mirror is for '
      'headless legs only (gh-1292)', () async {
    final cli = cliFor([textTurn('ok', usage: reportedUsage())]);
    final run = cli.run();
    await waitForIt(() => io.out.toString().contains('fa> '));
    io.sendLine('hi');
    await waitForIt(() => io.out.toString().contains('ok'));
    io.sendLine('/exit');
    await run;

    expect(io.out.toString(), isNot(contains(usageTokensLogPrefix)));
    // The diag-file write is unchanged by the gating.
    final log = (await env.readTextFile('/home/.fah/logs/fa.log')).valueOrNull!;
    expect(log, contains(usageTokensLogPrefix));
  });

  test(
    'resuming the session twice folds ONE record with three segments (AC2)',
    () async {
      final first = cliFor([
        textTurn('one', usage: reportedUsage(input: 10, output: 5)),
      ]);
      expect(await first.runHeadless('go'), 0);
      final sessions = await JsonlSessionRepo(
        fs: env,
        sessionsRoot: '/sessions',
      ).list();
      final sessionId = sessions.single.id;

      // --continue once: two segments total.
      final second = cliFor([
        textTurn('two', usage: reportedUsage(input: 20, output: 10)),
      ], sessionName: sessionId);
      expect(await second.runHeadless('again'), 0);
      var ledger = await readLedger(sessionId);
      expect(ledger!.segments.length, 2);
      expect(ledger.resumedCount, 1);
      expect(ledger.total.totals.input, 30);

      // --continue twice: three segments, total == Σ(segments) (I2).
      final third = cliFor([
        textTurn('three', usage: reportedUsage(input: 7, output: 3)),
      ], sessionName: sessionId);
      expect(await third.runHeadless('more'), 0);
      ledger = await readLedger(sessionId);
      expect(ledger!.segments.length, 3);
      expect(ledger.resumedCount, 2);
      final sum = ledger.segments
          .map((segment) => segment.totals.input)
          .reduce((a, b) => a + b);
      expect(ledger.total.totals.input, sum);
      expect(ledger.total.totals.input, 37);
    },
  );

  test(
    'a fake provider that omits usage marks the segment estimated (AC4)',
    () async {
      final cli = cliFor([textTurn('ok')]); // textTurn default: Usage.zero
      expect(await cli.runHeadless('say hi'), 0);
      final sessions = await JsonlSessionRepo(
        fs: env,
        sessionsRoot: '/sessions',
      ).list();
      final ledger = await readLedger(sessions.single.id);
      expect(ledger!.segments.single.source, UsageSource.estimated);
      expect(ledger.total.source, UsageSource.estimated);
    },
  );

  test(
    'a stale writer never clobbers a concurrent writer\'s newer fold (E2)',
    () async {
      final first = cliFor([
        textTurn('one', usage: reportedUsage(input: 10, output: 5)),
      ]);
      expect(await first.runHeadless('go'), 0);
      final sessions = await JsonlSessionRepo(
        fs: env,
        sessionsRoot: '/sessions',
      ).list();
      final sessionId = sessions.single.id;

      // Simulate a concurrent writer that already folded a LONGER chain
      // (a later resume got further along): the artifact's fingerprint
      // no longer matches any short-chain fold, and its record count
      // claims a fold over more records than the stale process saw.
      final onDisk = (await readLedger(sessionId))!;
      final concurrent = UsageLedger(
        sessionId: onDisk.sessionId,
        segments: onDisk.segments,
        total: onDisk.total,
        chainRecords: onDisk.chainRecords + 10,
        chainHash: 'sha256:concurrent-writer',
      );
      await env.writeFile(
        '/sessions/$sessionId/usage.json',
        '${jsonEncode(concurrent.toJson())}\n',
      );

      // The stale process resumes and flushes its fold over the shorter
      // chain it saw: it must SKIP the write, not clobber the newer
      // artifact (last writer wins, never slowest writer wins).
      final second = cliFor([
        textTurn('two', usage: reportedUsage(input: 20, output: 10)),
      ], sessionName: sessionId);
      expect(await second.runHeadless('again'), 0);

      final after = await readLedger(sessionId);
      expect(after, isNotNull);
      expect(after!.chainRecords, concurrent.chainRecords);
      expect(after.chainHash, 'sha256:concurrent-writer');
    },
  );

  test(
    '/usage rebuild re-folds the chain onto disk (rebuild command path)',
    () async {
      final cli = cliFor([textTurn('ok', usage: reportedUsage())]);
      expect(await cli.runHeadless('say hi'), 0);
      final sessions = await JsonlSessionRepo(
        fs: env,
        sessionsRoot: '/sessions',
      ).list();
      final sessionId = sessions.single.id;

      // Wreck the artifact (E3: hand-edited garbage).
      await env.writeFile(
        '/sessions/$sessionId/usage.json',
        '{"garbage":true}',
      );

      final io2 = FakeCliIO();
      addTearDown(io2.close);
      final cli2 = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          homeDir: '/home',
          sessionName: sessionId,
          providerKind: 'openai-completions',
        ),
        io: io2,
        streamFunction: FakeStreamFunction(const []).call,
        version: '0.0.0-test',
      );
      final run = cli2.run();
      await waitForIt(() => !cli2.isBusy);
      io2.sendLine('/usage rebuild');
      await waitForIt(() => io2.out.toString().contains('usage: rebuilt'));
      io2.sendLine('/exit');
      await run;

      final ledger = await readLedger(sessionId);
      expect(ledger, isNotNull);
      expect(ledger!.total.totals.requests, 1);
    },
  );

  test('/usage rebuild with an empty chain path says so instead of failing '
      'the read (flush-path guard parity)', () async {
    // A session whose metadata carries no chain path is unreachable
    // through the real repo — the test seam swaps one in after boot
    // (the `fa> ` prompt means boot finished and _session is stable).
    final cli = cliFor(const []);
    final run = cli.run();
    await waitForIt(() => io.out.toString().contains('fa> '));
    cli.sessionForTest = Session(_EmptyChainPathStorage());
    io.sendLine('/usage rebuild');
    await waitForIt(
      () => io.out.toString().contains('usage: no session chain'),
    );
    io.sendLine('/exit');
    await run;
    expect(io.out.toString(), contains('usage: no session chain'));
  });
}

/// A storage whose metadata has no chain path: the shape the usage-ledger
/// guards defend against (unreachable through JsonlSessionRepo).
final class _EmptyChainPathStorage implements SessionStorage {
  @override
  Future<SessionMetadata> getMetadata() async => SessionMetadata(
    id: '',
    createdAt: DateTime.utc(2024),
    cwd: '/work',
    path: '',
  );

  @override
  Future<String?> getLeafId() async => null;

  @override
  Future<void> setLeafId(String? leafId) async {}

  @override
  Future<String> createEntryId() async => 'fake-id';

  @override
  Future<void> appendEntry(SessionRecord record) async {}

  @override
  Future<SessionRecord?> getEntry(String id) async => null;

  @override
  Future<List<SessionRecord>> findEntries(String type) async => const [];

  @override
  Future<String?> getLabel(String id) async => null;

  @override
  Future<List<SessionRecord>> getPathToRoot(String? leafId) async => const [];

  @override
  Future<List<SessionRecord>> getEntries() async => const [];
}
