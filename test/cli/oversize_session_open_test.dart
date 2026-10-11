// gh-1555 W1 (lazy/windowed-everywhere reads): the legacy full-open call
// sites — the TUI session picker, the boot-time name-resolution scan, the
// subagent transcript preview, and the headless trajectory resolver — must
// never depend on a full open, because a ledger past the gh-1073 2 GiB
// backstop refuses EVERY full open with SessionErrorCode.tooLarge (the
// 2026-10-11 incident: three production sessions fell off the picker).
//
// The fixture repo below models exactly that incident shape: any
// `open(windowed: false)` refuses like an over-the-backstop ledger, any
// windowed open delegates to the real repo. Every test here fails on the
// old code by construction (the refused full open propagates), and passes
// only when the call site reads windowed.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/trajectory_tui.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The incident-shape repo: FULL opens refuse with the gh-1073 refusal a
/// > 2 GiB ledger produces; windowed opens delegate to the real store.
final class RefusingFullOpenRepo implements SessionRepo {
  RefusingFullOpenRepo(this._delegate);

  final SessionRepo _delegate;

  @override
  Future<Session> open(
    SessionMetadata metadata, {
    bool windowed = false,
    bool wholeFileOnly = false,
  }) {
    if (!windowed) {
      throw SessionException(
        'Refusing to open session ${metadata.path}: 2.60 GiB exceeds the '
        '2.0 GiB full-open bound. Resume it windowed '
        '(`fa --session ${metadata.path.split('/').last}`) or shrink the '
        'ledger with `fa session repair` — the full open would exhaust '
        'the heap (gh-1073).',
        code: SessionErrorCode.tooLarge,
      );
    }
    return _delegate.open(
      metadata,
      windowed: windowed,
      wholeFileOnly: wholeFileOnly,
    );
  }

  @override
  Future<Session> create(JsonlSessionCreateOptions options) =>
      _delegate.create(options);

  @override
  Future<List<SessionMetadata>> list({String? cwd}) =>
      _delegate.list(cwd: cwd);

  @override
  Future<void> delete(SessionMetadata metadata, {String actor = 'unknown'}) =>
      _delegate.delete(metadata, actor: actor);

  @override
  Future<Session> fork(
    SessionMetadata source, {
    required String cwd,
    String? entryId,
    ForkPosition position = ForkPosition.before,
    String? id,
    String? parentSessionPath,
    Map<String, dynamic>? metadata,
  }) => _delegate.fork(
    source,
    cwd: cwd,
    entryId: entryId,
    position: position,
    id: id,
    parentSessionPath: parentSessionPath,
    metadata: metadata,
  );
}

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor(StreamFunction streamFunction) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  RefusingFullOpenRepo incidentRepo() => RefusingFullOpenRepo(
    JsonlSessionRepo(fs: env, sessionsRoot: '/sessions'),
  );

  Future<void> seedNamedSession(String name) async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final session = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await session.appendSessionName(name);
    await session.appendMessage(UserMessage.text('hello from $name'));
  }

  test(
    'picker opens an over-the-backstop session windowed and switches '
    '(gh-1555 AC1/F3)',
    () async {
      await seedNamedSession('marathon');
      final cli = cliFor(FakeStreamFunction([textTurn('ok')]).call);
      cli.repoForTest = incidentRepo();

      await cli.openSessionsPickerForTest();
      await cli.tuiPickSessionForTest('r0');
      expect(
        io.out.toString(),
        contains("switched to session 'marathon'"),
        reason: 'the picker must not ride the refused full open',
      );
      expect(io.out.toString(), isNot(contains('failed to open session')));
    },
  );

  test(
    'a corrupt (not merely large) session still reports inline from the '
    'picker (gh-1555 F3 NEG)',
    () async {
      await seedNamedSession('marathon');
      final delegate = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final corrupt = CorruptWindowedRepo(delegate);
      final cli = cliFor(FakeStreamFunction([textTurn('ok')]).call);
      cli.repoForTest = corrupt;

      await cli.openSessionsPickerForTest();
      await cli.tuiPickSessionForTest('r0');
      expect(
        io.out.toString(),
        contains('failed to open session'),
        reason: 'the error UX is preserved, not swallowed',
      );
    },
  );

  test(
    'boot resume by name resolves the name scan windowed (gh-1555 d4) and '
    'the marathon fallback never full-opens (AC2)',
    () async {
      await seedNamedSession('marathon');
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          sessionName: 'marathon',
          providerKind: 'openai-completions',
        ),
        io: io,
        streamFunction: FakeStreamFunction([textTurn('ok')]).call,
      );
      cli.repoForTest = incidentRepo();

      final run = cli.run();
      await waitForIt(
        () => io.out.toString().contains('restored session'),
        reason: 'the boot resume replays the session',
      );
      expect(io.out.toString(), isNot(contains('failed to open session')));
      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'subagent transcript preview tails an over-the-backstop child session '
    '(gh-1555 AC4/d7)',
    () async {
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final child = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await child.appendMessage(UserMessage.text('child task'));
      final childPath = (await child.getMetadata()).path;

      final cli = cliFor(FakeStreamFunction([textTurn('ok')]).call);
      cli.repoForTest = incidentRepo();

      final lines = await cli.readChildMessagesForTest(childPath, tail: 8);
      expect(
        lines,
        isNotEmpty,
        reason: 'the preview rides the windowed tail, not the refused '
            'full open',
      );
      expect(lines.first, startsWith('user: child task'));
    },
  );

  test(
    'the headless trajectory resolver opens windowed (gh-1555 AC3)',
    () async {
      await seedNamedSession('widgets');
      final repo = incidentRepo();

      final byName = await resolveTrajectorySession(repo, 'widgets');
      expect(
        byName,
        isNotNull,
        reason: 'trajectory resolution must survive the backstop the '
            'incident sessions hit',
      );
      final metadata = await byName!.getMetadata();
      expect(metadata.id, isNotEmpty);

      // The cost/inspect surfaces page the whole ledger in bounded blocks
      // instead of materializing one giant string (gh-1555 W1).
      expect(await byName.ensureWholeLedgerResident(), isTrue);
      final branch = await byName.getBranch();
      expect(branch, isNotEmpty);
      expect(branch.last, isA<MessageRecord>());
    },
  );
}

/// A repo whose WINDOWED opens fail too — the genuinely-corrupt (not
/// merely large) session the picker's inline-error UX must survive.
final class CorruptWindowedRepo extends RefusingFullOpenRepo {
  CorruptWindowedRepo(super._delegate);

  @override
  Future<Session> open(
    SessionMetadata metadata, {
    bool windowed = false,
    bool wholeFileOnly = false,
  }) {
    if (windowed) {
      throw StateError('Unexpected character (at offset 12)');
    }
    return super.open(metadata, windowed: windowed, wholeFileOnly: wholeFileOnly);
  }
}
