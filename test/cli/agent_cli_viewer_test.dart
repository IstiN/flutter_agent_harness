import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Session ownership from the CLI's side (#428): a live `_owner.json`
/// lease turns a second `fa` into a VIEWER (exact banner, composer →
/// owner's mailbox, zero session-file writes); graceful exit releases;
/// a dead owner's stale lease is re-acquired fresh with a warning;
/// headless runs refuse over a live lease.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;
  late JsonlSessionRepo repo;
  late FileSessionLeaseStore store;
  late FileMessagingRepository fabric;
  late FileSessionPresenceStore presence;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
    repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    store = FileSessionLeaseStore(env: env);
    fabric = FileMessagingRepository(
      env: env,
      root: '/sessions/--work--/messages',
    );
    presence = FileSessionPresenceStore(env: env, root: '/sessions');
  });
  tearDown(() => io.close());

  Future<SessionMetadata> namedSession(String name) async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendSessionName(name);
    return session.getMetadata();
  }

  Future<void> seedLiveLease(
    String sessionPath, {
    int pid = 999,
    String bootId = 'owner-boot',
    DateTime? acquiredAt,
  }) async {
    final when = (acquiredAt ?? _fixedWhen).toUtc();
    await env.writeFile(
      store.sidecarPath(sessionPath),
      const JsonEncoder.withIndent('  ').convert({
        'host': 'cli',
        'sessionId': 'whatever',
        'pid': pid,
        'bootId': bootId,
        'heartbeatAt': when.toIso8601String(),
        'acquiredAt': when.toIso8601String(),
      }),
    );
  }

  AgentCli cliFor(StreamFunction streamFunction, {String? sessionName}) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        sessionName: sessionName,
        leaseStore: store,
        processId: 4242,
        presenceStore: presence,
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  String out() => io.out.toString();

  test(
    'AC3: a live lease makes the second CLI a viewer — exact banner, '
    'mail to the owner, zero session writes, no presence, no takeover',
    () async {
      final meta = await namedSession('proj');
      await seedLiveLease(meta.path);
      // A real transcript row so the viewer's pre-open backlog is
      // non-empty and its dimmed render is deterministic.
      final owned = await repo.open(meta);
      await owned.appendMessage(UserMessage.text('earlier note'));
      final bytesBefore = (await env.readTextFile(meta.path)).valueOrNull;

      final cli = cliFor(FakeStreamFunction([]).call, sessionName: 'proj');
      final run = cli.run();
      await waitForIt(
        () => out().contains(
          'Driven by fa CLI (pid 999) since 14:32 — you are viewing. '
          'Your messages are delivered to the live agent.',
        ),
        reason: 'the exact viewer banner',
      );
      await waitForIt(
        () => out().contains('user: earlier note'),
        reason: 'the dimmed backlog row renders on watch',
      );
      // A viewer registers no presence: the app must not think THIS
      // process drives the session.
      expect(await presence.list(), isEmpty);

      // Composer line → the owner's mailbox with CLI attribution, and
      // the session file stays byte-identical.
      io.sendLine('hello from the viewer');
      await waitForIt(
        () => out().contains('hello from the viewer'),
        reason: 'the viewer echo',
      );
      final mail = await fabric.peek('${meta.id}/main');
      expect(mail, hasLength(1));
      expect(mail.single.kind, AgentMessageKind.user);
      expect(mail.single.fromId, 'fa CLI user');
      expect(mail.single.text, 'hello from the viewer');
      expect(
        (await env.readTextFile(meta.path)).valueOrNull,
        bytesBefore,
        reason: 'a viewer never writes session bytes',
      );
      expect(
        (await store.inspect(meta.path)).lease!.bootId,
        'owner-boot',
        reason: 'the viewer never touches the owner’s lease',
      );

      io.sendLine('/exit');
      await run;
      // Even the exit must not release someone else's lease.
      expect((await store.inspect(meta.path)).state, LeaseState.live);
    },
  );

  test('AC4/AC8: a free session is acquired on first drive-open (lazy '
      'sidecar), released on /exit, and adds no idle session bytes', () async {
    final meta = await namedSession('handover');
    final bytesBefore = (await env.readTextFile(meta.path)).valueOrNull;

    final cli = cliFor(FakeStreamFunction([]).call, sessionName: 'handover');
    final run = cli.run();
    await waitForIt(
      () => out().isNotEmpty,
      reason: 'boot banner (claim already settled before it)',
    );
    expect((await store.inspect(meta.path)).state, LeaseState.live);
    expect((await store.inspect(meta.path)).lease!.pid, 4242);
    // Idle boot: the lease sidecar is the ONLY new file — the session
    // JSONL is byte-identical to the no-lease behavior.
    expect((await env.readTextFile(meta.path)).valueOrNull, bytesBefore);

    io.sendLine('/exit');
    await run;
    expect(
      (await store.inspect(meta.path)).state,
      LeaseState.free,
      reason: 'graceful exit releases the lease immediately',
    );

    // The next opener drives: fresh acquire with THIS boot's identity.
    final io2 = FakeCliIO();
    addTearDown(io2.close);
    final cli2 = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        sessionName: 'handover',
        leaseStore: store,
        processId: 7777,
      ),
      io: io2,
      streamFunction: FakeStreamFunction([]).call,
    );
    final run2 = cli2.run();
    await waitForIt(() => io2.out.isNotEmpty, reason: 'second boot banner');
    // The first process deleted the name-only session on exit (empty
    // by design), so run #2 created its own 'handover' — find the one
    // live sidecar and confirm it names the second pid.
    var sidecars = <FileInfo>[];
    for (var i = 0; i < 5000 && sidecars.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final listing = await env.listDir('/sessions/--work--');
      sidecars = listing.valueOrNull!
          .where((f) => f.name.endsWith('.owner.json'))
          .toList();
    }
    expect(sidecars, hasLength(1));
    final raw = await env.readTextFile(sidecars.single.path);
    final live = jsonDecode(raw.valueOrNull!) as Map<String, dynamic>;
    expect(live['pid'], 7777);
    expect(live['bootId'], isNot('owner-boot'));
    io2.sendLine('/exit');
    await run2;
  });

  test('AC7: an expired lease is re-acquired fresh with the dead-owner '
      'warning naming host and pid', () async {
    final meta = await namedSession('deadowner');
    await seedLiveLease(meta.path);
    // Kill the owner: freeze the sidecar 20s in the past (> 15s window).
    env.setMtime(
      store.sidecarPath(meta.path),
      DateTime.now().millisecondsSinceEpoch -
          const Duration(seconds: 20).inMilliseconds,
    );

    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call, sessionName: 'deadowner');
    final run = cli.run();
    await waitForIt(
      () => out().contains('previous owner fa CLI (pid 999)'),
      reason: 'boot claims the stale lease with the warning',
    );
    io.sendLine('drive on');
    await waitForIt(
      () => fake.calls == 1 && !cli.isBusy,
      reason: 'the new owner runs a normal turn',
    );
    expect(
      out().contains('previous owner fa CLI (pid 999) looks dead (stale)'),
      isTrue,
      reason: 'the dead-owner warning names host + pid',
    );
    // Still driving: the fresh lease is ours (a new bootId replaced
    // the dead owner's) — asserted before /exit releases it.
    final fresh = await env.readTextFile(store.sidecarPath(meta.path));
    final live = jsonDecode(fresh.valueOrNull!) as Map<String, dynamic>;
    expect(live['bootId'], isNot('owner-boot'));
    expect(live['pid'], 4242);
    io.sendLine('/exit');
    await run;
    expect((await store.inspect(meta.path)).state, LeaseState.free);
  });

  test('E7: a headless run over a live-leased session refuses with the '
      'banner, exit 3, and no provider call', () async {
    final meta = await namedSession('headless');
    await seedLiveLease(meta.path);
    final bytesBefore = (await env.readTextFile(meta.path)).valueOrNull;
    final fake = FakeStreamFunction([textTurn('never')]);
    final cli = cliFor(fake.call, sessionName: 'headless');

    final exit = await cli.runHeadless('do the thing');
    expect(exit, 3);
    expect(
      out().contains('Driven by fa CLI (pid 999)'),
      isTrue,
      reason: 'the refusal carries the banner',
    );
    expect(fake.calls, 0, reason: 'no second writer ever runs');
    expect((await env.readTextFile(meta.path)).valueOrNull, bytesBefore);
    expect((await store.inspect(meta.path)).state, LeaseState.live);
  });

  test('AC2: viewer composer lands in the LIVE owner transcript with '
      'attribution (two real CLIs, one writer)', () async {
    await namedSession('shared');
    final ownerFake = FakeStreamFunction([]);
    final ownerIo = FakeCliIO();
    addTearDown(ownerIo.close);
    final owner = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        sessionName: 'shared',
        leaseStore: store,
        processId: 4242,
      ),
      io: ownerIo,
      streamFunction: ownerFake.call,
    );
    final ownerRun = owner.run();
    await waitForIt(() => ownerIo.out.isNotEmpty, reason: 'owner boot');

    // A second CLI opens the same session: the live lease makes it a
    // viewer; its composer hands the words to the owner's agent.
    final viewer = cliFor(FakeStreamFunction([]).call, sessionName: 'shared');
    final viewerRun = viewer.run();
    await waitForIt(
      () => out().contains('you are viewing'),
      reason: 'viewer boot',
    );
    io.sendLine('hello from the viewer');
    await waitForIt(
      () => ownerFake.calls == 1 && !owner.isBusy,
      reason: 'the owner runs the handed-over turn',
    );
    // The owner's written turn streams back to the viewer's watch: a
    // rendered, attributed transcript row (deterministic row coverage).
    await waitForIt(
      () => out().contains('[from fa CLI user] hello from the viewer'),
      reason: 'the viewer renders the owner-run turn row',
    );
    expect(
      ownerFake.contexts.single.messages.whereType<UserMessage>().map(
        (m) => m.content is String ? m.content as String : '',
      ),
      contains(contains('[from fa CLI user] hello from the viewer')),
    );

    io.sendLine('/exit');
    await viewerRun;
    ownerIo.sendLine('/exit');
    await ownerRun;
  });

  test('AC4: a viewer switching to a free session exits viewer mode and '
      'drives it', () async {
    final leased = await namedSession('leased');
    final free = await namedSession('free');
    await seedLiveLease(leased.path);

    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call, sessionName: 'leased');
    final run = cli.run();
    await waitForIt(
      () => out().contains('you are viewing'),
      reason: 'viewer boot',
    );

    io.sendLine('/session free');
    await waitForIt(
      () => out().contains("switched to session 'free'"),
      reason: 'the switch',
    );
    // Now a driver: the turn runs through the model, presence registers.
    io.sendLine('run for me');
    await waitForIt(
      () => fake.calls == 1 && !cli.isBusy,
      reason: 'the switched-to session drives a turn',
    );
    // Presence follows the driving session on the next tick (≈2s).
    var rows = <String, SessionPresence>{};
    for (var i = 0; i < 5000 && rows.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      rows = await presence.list();
    }
    expect(rows, hasLength(1));
    expect((await store.inspect(free.path)).state, LeaseState.live);
    // The leased session's owner lease was never touched.
    expect((await store.inspect(leased.path)).lease!.bootId, 'owner-boot');

    io.sendLine('/exit');
    await run;
  });
  test('AC9: viewer row rendering, backlog cap, and stale notice text', () {
    expect(
      viewerRowText(
        const AttachedMessage(role: AttachedMessageRole.user, text: 'hi'),
      ),
      'user: hi',
    );
    expect(
      viewerRowText(
        const AttachedMessage(role: AttachedMessageRole.assistant, text: 'hey'),
      ),
      'hey',
    );
    expect(
      viewerRowText(
        const AttachedMessage(
          role: AttachedMessageRole.tool,
          toolName: 'read',
          text: '',
        ),
      ),
      '[tool] read',
    );
    expect(
      viewerRowText(
        const AttachedMessage(role: AttachedMessageRole.system, text: 'note'),
      ),
      'note',
    );

    final rows = List.generate(
      7,
      (i) => AttachedMessage(role: AttachedMessageRole.assistant, text: 'r$i'),
    );
    final (kept, caption) = viewerBacklogSlice(rows, false);
    expect(kept.map((m) => m.text), ['r2', 'r3', 'r4', 'r5', 'r6']);
    expect(caption, contains('2 earlier rows not shown'));
    expect(viewerBacklogSlice(rows, true), (rows, null));
    expect(viewerBacklogSlice(rows.take(2).toList(), false).$2, isNull);

    expect(
      viewerStaleNotice(
        SessionLease(
          host: 'cli',
          sessionId: 's',
          pid: 999,
          bootId: 'b',
          heartbeatAt: '',
          acquiredAt: '',
        ),
      ),
      contains('the driving fa CLI (pid 999) looks dead'),
    );
  });

  test('AC9: the viewer tick prints the stale notice exactly once when '
      'the owner dies mid-view', () async {
    final meta = await namedSession('tickflip');
    await seedLiveLease(meta.path);
    final cli = cliFor(FakeStreamFunction([]).call, sessionName: 'tickflip');
    final run = cli.run();
    await waitForIt(
      () => out().contains('you are viewing'),
      reason: 'viewer boot',
    );

    // The owner dies: freeze the sidecar beyond the 15s window.
    env.setMtime(
      store.sidecarPath(meta.path),
      DateTime.now().millisecondsSinceEpoch -
          const Duration(seconds: 20).inMilliseconds,
    );
    await waitForIt(
      () => out().contains('looks dead — reopen this session to drive it'),
      reason: 'the live→stale flip notice',
    );
    await Future<void>.delayed(const Duration(seconds: 5));
    expect(
      'looks dead — reopen'.allMatches(out()).length,
      1,
      reason: 'the notice prints once, not every tick',
    );
    io.sendLine('/exit');
    await run;
  });

  test('heartbeat: losing the lease mid-run demotes this CLI to a viewer '
      'of the new owner', () async {
    final meta = await namedSession('stolen');
    final cli = cliFor(FakeStreamFunction([]).call, sessionName: 'stolen');
    final run = cli.run();
    var live = LeaseInspect.free();
    for (var i = 0; i < 5000 && live.state != LeaseState.live; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      live = await store.inspect(meta.path);
    }
    expect(live.state, LeaseState.live, reason: 'the boot claim');

    // Another host takes the expired lease under us; our next heartbeat
    // misses and must demote.
    await seedLiveLease(meta.path, pid: 31337, bootId: 'new-owner');
    await waitForIt(
      () => out().contains('lease: lost — another host is driving'),
      reason: 'the demotion notice',
    );
    await waitForIt(
      () => out().contains('Driven by fa CLI (pid 31337)'),
      reason: 'the viewer banner of the new owner',
    );
    // The demoted composer routes to the new owner's mailbox.
    io.sendLine('anyone there?');
    await waitForIt(
      () => out().contains('anyone there?'),
      reason: 'the viewer echo',
    );
    final mail = await fabric.peek('${meta.id}/main');
    expect(mail.single.fromId, 'fa CLI user');
    expect(mail.single.text, 'anyone there?');
    io.sendLine('/exit');
    await run;
    // A viewer's exit never releases the new owner's lease.
    expect((await store.inspect(meta.path)).lease!.bootId, 'new-owner');
  });
}

/// 14:32 local wall-clock: the banner's "since HH:MM" round-trips
/// through toLocal, so this pins the exact banner text in any TZ.
final DateTime _fixedWhen = DateTime(2026, 9, 15, 14, 32);
