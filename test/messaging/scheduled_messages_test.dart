@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  test('parseDelay handles units and combinations', () {
    expect(parseDelay('90s'), const Duration(seconds: 90));
    expect(parseDelay('25m'), const Duration(minutes: 25));
    expect(parseDelay('1h30m'), const Duration(minutes: 90));
    expect(parseDelay('1d'), const Duration(days: 1));
    expect(parseDelay('500ms'), const Duration(milliseconds: 500));
    expect(parseDelay('0.5m'), const Duration(seconds: 30));
    expect(parseDelay('1.5h'), const Duration(minutes: 90));
    expect(parseDelay('abc'), isNull);
    expect(parseDelay('0m'), isNull);
  });

  test('due messages land in the inbox and rearm works', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final repo = FileMessagingRepository(
      env: env,
      root: '/sessions/--work--/messages',
      homeDir: '/home/user',
      decodeSessionCwd: decodeSessionCwd,
    );
    final queue = ScheduledMessageQueue(
      env: env,
      repo: () => repo,
      root: () => '/sessions/--work--/messages',
    );
    await repo.register('main');
    await queue.schedule(
      text: 'check the build',
      delay: const Duration(milliseconds: 30),
      to: 'main',
      from: 'main',
    );
    // Not yet due.
    expect(await repo.peek('main'), isEmpty);
    // The queue's own timer delivers when due; a manual deliverDue is an
    // idempotent catch-up for restarts.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final mail = await repo.peek('main');
    expect(mail, hasLength(1));
    expect(mail.single.text, contains('[scheduled] check the build'));
    // Delivered records are consumed, not re-delivered.
    expect(await queue.deliverDue(), 0);
  });

  test(
    'overdue records survive a restart (new queue instance delivers)',
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final root = '/sessions/--work--/messages';
      final repo = FileMessagingRepository(
        env: env,
        root: root,
        homeDir: '/home/user',
        decodeSessionCwd: decodeSessionCwd,
      );
      final first = ScheduledMessageQueue(
        env: env,
        repo: () => repo,
        root: () => root,
      );
      await first.schedule(
        text: 'ping later',
        delay: const Duration(milliseconds: 20),
        to: 'main',
      );
      // A fresh queue (host restart) re-arms and delivers overdue records.
      final second = ScheduledMessageQueue(
        env: env,
        repo: () => repo,
        root: () => root,
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await second.start();
      expect((await repo.peek('main')).single.text, contains('ping later'));
    },
  );

  test(
    'self-scheduled mail resolves to the host mailbox, not a "self" dir',
    () async {
      // Regression: without a `to`, records stored the literal string 'self',
      // and delivery wrote into a phantom <root>/self mailbox nobody drains —
      // self-reminders were lost forever (38 on one production machine).
      final env = MemoryExecutionEnv(cwd: '/work');
      final root = '/sessions/--work--/messages';
      final repo = FileMessagingRepository(
        env: env,
        root: root,
        homeDir: '/home/user',
        decodeSessionCwd: decodeSessionCwd,
      );
      final queue = ScheduledMessageQueue(
        env: env,
        repo: () => repo,
        root: () => root,
        selfMailbox: () => 'sid-1/main',
      );
      await queue.schedule(
        text: 'ping me',
        delay: const Duration(milliseconds: 20),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final mail = await repo.peek('sid-1/main');
      expect(mail.single.text, contains('[scheduled] ping me'));
      expect(mail.single.fromId, 'sid-1/main');
      expect(mail.single.toId, 'sid-1/main');
      // Nothing must be left behind in the phantom self mailbox.
      expect((await repo.peek('self')).isEmpty, isTrue);
    },
  );

  test('cross-mailbox schedule attributes the message to the sender', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final root = '/sessions/--work--/messages';
    final repo = FileMessagingRepository(
      env: env,
      root: root,
      homeDir: '/home/user',
      decodeSessionCwd: decodeSessionCwd,
    );
    final queue = ScheduledMessageQueue(
      env: env,
      repo: () => repo,
      root: () => root,
      selfMailbox: () => 'sid-1/main',
    );
    await queue.schedule(
      text: 'hey jsr',
      delay: const Duration(milliseconds: 20),
      to: 'jsr/main',
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await queue.deliverDue();
    final mail = await repo.peek('jsr/main');
    expect(mail.single.fromId, 'sid-1/main');
  });

  test('legacy "self" inbox mail is migrated into the real mailbox', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final root = '/sessions/--work--/messages';
    final repo = FileMessagingRepository(
      env: env,
      root: root,
      homeDir: '/home/user',
      decodeSessionCwd: decodeSessionCwd,
    );
    await repo.register('sid-1/main');
    // A message delivered by a build predating the self-mailbox fix.
    await repo.send(
      AgentMessage(
        id: 'legacy-1',
        fromId: 'self',
        toId: 'self',
        text: '[scheduled] old reminder',
        sentAt: DateTime.now().toUtc().toIso8601String(),
        hops: 0,
      ),
    );
    final queue = ScheduledMessageQueue(
      env: env,
      repo: () => repo,
      root: () => root,
      selfMailbox: () => 'sid-1/main',
    );
    await queue.start();
    final mail = await repo.peek('sid-1/main');
    expect(mail.single.text, '[scheduled] old reminder');
    expect(mail.single.fromId, 'sid-1/main');
    expect((await repo.peek('self')).isEmpty, isTrue);
  });

  test('concurrent delivery runs send each record once', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final root = '/sessions/--work--/messages';
    final repo = FileMessagingRepository(
      env: env,
      root: root,
      homeDir: '/home/user',
      decodeSessionCwd: decodeSessionCwd,
    );
    final queue = ScheduledMessageQueue(
      env: env,
      repo: () => repo,
      root: () => root,
      selfMailbox: () => 'sid-1/main',
    );
    await queue.schedule(text: 'once', delay: const Duration(milliseconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await Future.wait([queue.deliverDue(), queue.deliverDue()]);
    expect(await repo.peek('sid-1/main'), hasLength(1));
  });

  test('schedule/fire notices are surfaced to the host', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final root = '/sessions/--work--/messages';
    final repo = FileMessagingRepository(
      env: env,
      root: root,
      homeDir: '/home/user',
      decodeSessionCwd: decodeSessionCwd,
    );
    final scheduledNotices = <String>[];
    final firedNotices = <String>[];
    final queue = ScheduledMessageQueue(
      env: env,
      repo: () => repo,
      root: () => root,
      selfMailbox: () => 'sid-1/main',
      onScheduled: scheduledNotices.add,
      onFired: firedNotices.add,
    );
    await queue.schedule(
      text: 'check CI',
      delay: const Duration(milliseconds: 10),
    );
    expect(scheduledNotices.single, contains('check CI'));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(firedNotices.single, contains('check CI'));
  });

  test('schedule_message tool validates and schedules', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final root = '/sessions/--work--/messages';
    final repo = FileMessagingRepository(
      env: env,
      root: root,
      homeDir: '/home/user',
      decodeSessionCwd: decodeSessionCwd,
    );
    final queue = ScheduledMessageQueue(
      env: env,
      repo: () => repo,
      root: () => root,
    );
    final tool = scheduleMessageTool(queue);

    String content(dynamic result) =>
        result.content.whereType<TextContent>().map((b) => b.text).join();

    final bad = await tool.execute({'text': 'x', 'delay': 'soon'}, null, null);
    expect(content(bad), contains('error: delay'));

    final ok = await tool.execute(
      {'text': 'remind me', 'delay': '10m', 'to': 'main'},
      null,
      null,
    );
    expect(content(ok), contains('scheduled'));
    final pending = (await env.listDir('$root/_scheduled')).valueOrNull ?? [];
    expect(pending.where((e) => e.kind == FileKind.file), hasLength(1));
  });

  test(
    'self-addressed records follow the live mailbox after a re-address',
    () async {
      // Regression (issue #59): a record pins the self mailbox at schedule
      // time, but hosts re-address mailboxes (session switch, app restart) —
      // delivering to the stale recorded address strands the reminder in a
      // mailbox nobody drains while the tool already reported success.
      final env = MemoryExecutionEnv(cwd: '/work');
      const root = '/sessions/--work--/messages';
      final repo = FileMessagingRepository(
        env: env,
        root: root,
        homeDir: '/home/user',
        decodeSessionCwd: decodeSessionCwd,
      );
      var self = 'sid-1/main';
      final queue = ScheduledMessageQueue(
        env: env,
        repo: () => repo,
        root: () => root,
        selfMailbox: () => self,
      );
      await queue.schedule(
        text: 'watch the PRs',
        delay: const Duration(milliseconds: 20),
      );
      // The host re-addresses its mailbox before the record comes due.
      self = 'sid-2/main';
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final mail = await repo.peek('sid-2/main');
      expect(mail.single.text, contains('[scheduled] watch the PRs'));
      // Nothing stranded under the stale address.
      expect(await repo.peek('sid-1/main'), isEmpty);
    },
  );

  test(
    'junk records in _scheduled never disarm or phantom-deliver (skip branches)',
    () async {
      // The scans must tolerate every corrupt shape alongside a valid
      // record: non-json names, malformed json, valid-json-wrong-shape,
      // and records without dueMs (which must NOT deliver as due=0).
      final env = MemoryExecutionEnv(cwd: '/work');
      const root = '/sessions/--work--/messages';
      final repo = FileMessagingRepository(
        env: env,
        root: root,
        homeDir: '/home/user',
        decodeSessionCwd: decodeSessionCwd,
      );
      final queue = ScheduledMessageQueue(
        env: env,
        repo: () => repo,
        root: () => root,
        selfMailbox: () => 'main',
      );
      await repo.register('main');
      await queue.schedule(
        text: 'real one',
        delay: const Duration(milliseconds: 30),
      );
      // Seed the junk next to the valid record.
      (await env.writeFile(
        '$root/_scheduled/notes.txt',
        'not json',
      )).getOrThrow();
      (await env.writeFile(
        '$root/_scheduled/broken.json',
        '{nope',
      )).getOrThrow();
      (await env.writeFile(
        '$root/_scheduled/nodue.json',
        '{"text": "x"}',
      )).getOrThrow();
      (await env.writeFile('$root/_scheduled/list.json', '[1,2]')).getOrThrow();
      await queue.deliverDue(); // scans across the junk
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final mail = await repo.peek('main');
      expect(mail, hasLength(1));
      expect(mail.single.text, contains('[scheduled] real one'));
    },
  );

  test(
    'disposed queue holds delivery; a fresh start delivers the record',
    () async {
      // A host that tears a session down (app sheet dispose) must not let its
      // orphaned timer strand the record in the dead session's mailbox — the
      // pending file survives and the next start() delivers it to the live one.
      final env = MemoryExecutionEnv(cwd: '/work');
      const root = '/sessions/--work--/messages';
      final repo = FileMessagingRepository(
        env: env,
        root: root,
        homeDir: '/home/user',
        decodeSessionCwd: decodeSessionCwd,
      );
      var self = 'sid-1/main';
      final queue = ScheduledMessageQueue(
        env: env,
        repo: () => repo,
        root: () => root,
        selfMailbox: () => self,
      );
      await queue.schedule(
        text: 'ping later',
        delay: const Duration(milliseconds: 500),
      );
      queue.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      // Held, not delivered.
      expect(await repo.peek('sid-1/main'), isEmpty);
      // Restart with a re-addressed mailbox: the record surfaces there.
      self = 'sid-2/main';
      final restarted = ScheduledMessageQueue(
        env: env,
        repo: () => repo,
        root: () => root,
        selfMailbox: () => self,
      );
      // start() re-arms the not-yet-due record; the queue's own timer
      // delivers it once due.
      await restarted.start();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(
        (await repo.peek('sid-2/main')).single.text,
        contains('[scheduled] ping later'),
      );
      expect(await repo.peek('sid-1/main'), isEmpty);
    },
  );

  test(
    'a sweeper never steals another instance\'s due record (owner prefix)',
    () async {
      // Regression (issue #59 RCA): queues sharing one messages root each
      // sweep _scheduled/ — a sweeper re-addressing every self-addressed
      // record into ITS live mailbox stole the owner's reminder and deleted
      // the file. A record owned by another prefix must be left untouched.
      final env = MemoryExecutionEnv(cwd: '/work');
      const root = '/sessions/--work--/messages';
      final repo = FileMessagingRepository(
        env: env,
        root: root,
        homeDir: '/home/user',
        decodeSessionCwd: decodeSessionCwd,
      );
      final owner = ScheduledMessageQueue(
        env: env,
        repo: () => repo,
        root: () => root,
        selfMailbox: () => 'sid-a/main',
        ownerPrefix: () => 'sid-a',
      );
      // Seed a DUE self-addressed record owned by sid-a directly: using
      // schedule() would arm the owner's own timer and race the sweeper.
      const id = 'due-foreign-owned';
      (await env.writeFile(
        '$root/_scheduled/$id.json',
        jsonEncode({
          'id': id,
          'dueMs': DateTime.now().millisecondsSinceEpoch - 1000,
          'to': 'sid-a/main',
          'from': 'sid-a/main',
          'text': 'watch the PRs',
          'owner': 'sid-a',
        }),
      )).getOrThrow();
      // Queue B (another session, same shared root) sweeps first.
      final sweeper = ScheduledMessageQueue(
        env: env,
        repo: () => repo,
        root: () => root,
        selfMailbox: () => 'sid-b/main',
        ownerPrefix: () => 'sid-b',
      );
      await sweeper.start();
      // Not delivered into B, not deleted.
      expect(await repo.peek('sid-b/main'), isEmpty);
      expect(
        (await env.readTextFile('$root/_scheduled/$id.json')).valueOrNull,
        isNotNull,
      );
      // The owner still delivers it into its own live mailbox.
      await owner.deliverDue();
      expect(
        (await repo.peek('sid-a/main')).single.text,
        contains('[scheduled] watch the PRs'),
      );
      expect(
        (await env.readTextFile('$root/_scheduled/$id.json')).valueOrNull,
        isNull,
      );
    },
  );

  test(
    'adoption carries only the adopted session\'s records; others stay put',
    () async {
      // Regression (issue #59 RCA): the queue root pinned the LAUNCH cwd,
      // and the naive fix (move everything on a root change) steals the
      // OTHER instance's records from the shared old root. Production
      // reassigns the owner prefix to the ADOPTED session on adoption
      // (_syncMailboxPrefix), so the migration must carry only records the
      // adopted session owns; the previous session's reminders stay in
      // their folder root and deliver when that session is active again.
      final env = MemoryExecutionEnv(cwd: '/work');
      const launchRoot = '/sessions/--work--/messages';
      const adoptedRoot = '/sessions/--other--/messages';
      final repo = FileMessagingRepository(
        env: env,
        root: launchRoot,
        homeDir: '/home/user',
        decodeSessionCwd: decodeSessionCwd,
      );
      var cwd = '/work';
      var prefix = 'sid-1';
      final queue = ScheduledMessageQueue(
        env: env,
        repo: () => repo,
        root: () => '/sessions/${encodeSessionCwd(cwd)}/messages',
        selfMailbox: () => '$prefix/main',
        ownerPrefix: () => prefix,
      );
      // The record the OLD session schedules: owned by sid-1 in the work
      // folder's root.
      final sid1Id = await queue.schedule(
        text: 'follow me',
        delay: const Duration(minutes: 5),
      );
      // A record owned by the session ABOUT to be adopted, sitting in the
      // old root and already due.
      const adoptedId = 'due-owned-by-sid-2';
      (await env.writeFile(
        '$launchRoot/_scheduled/$adoptedId.json',
        jsonEncode({
          'id': adoptedId,
          'to': 'sid-2/main',
          'from': 'sid-2/main',
          'text': 'carried with the adoption',
          'owner': 'sid-2',
          'dueMs': DateTime.now().millisecondsSinceEpoch - 1000,
        }),
      )).getOrThrow();
      // A due record owned by a third instance on the same root: the
      // adoption must leave it exactly where its owner sweeps.
      const foreignId = 'due-owned-by-sid-a';
      (await env.writeFile(
        '$launchRoot/_scheduled/$foreignId.json',
        jsonEncode({
          'id': foreignId,
          'to': 'sid-a/main',
          'from': 'sid-a/main',
          'text': 'not yours',
          'owner': 'sid-a',
          'dueMs': DateTime.now().millisecondsSinceEpoch - 1000,
        }),
      )).getOrThrow();
      // The host adopts sid-2 from a different project folder: the prefix
      // and the queue root are reassigned together.
      prefix = 'sid-2';
      cwd = '/other';
      await queue.start();
      // The adopted session's due record was carried to the new root and
      // delivered into its live mailbox.
      expect(
        (await repo.peek('sid-2/main')).single.text,
        contains('[scheduled] carried with the adoption'),
      );
      expect(
        (await env.readTextFile(
          '$adoptedRoot/_scheduled/$adoptedId.json',
        )).valueOrNull,
        isNull,
      );
      // The previous session's reminder stayed in its folder root
      // (undelivered: sid-1 is not active here).
      expect(
        (await env.readTextFile(
          '$launchRoot/_scheduled/$sid1Id.json',
        )).valueOrNull,
        isNotNull,
      );
      expect(await repo.peek('sid-1/main'), isEmpty);
      // The third instance's record was not stolen by the move either.
      expect(
        (await env.readTextFile(
          '$launchRoot/_scheduled/$foreignId.json',
        )).valueOrNull,
        isNotNull,
      );
      expect(await repo.peek('sid-a/main'), isEmpty);
    },
  );

  test(
    'restart re-arm delivers to the original owner; foreign prefix waits',
    () async {
      // Regression (issue #59 RCA): re-arm from an on-disk record may
      // re-address to the LIVE mailbox only when the stored owner prefix
      // matches — a restart of the same session delivers, a different
      // session's queue leaves the record for its owner.
      final env = MemoryExecutionEnv(cwd: '/work');
      const root = '/sessions/--work--/messages';
      final repo = FileMessagingRepository(
        env: env,
        root: root,
        homeDir: '/home/user',
        decodeSessionCwd: decodeSessionCwd,
      );
      // A DUE on-disk record left by session sid-1 (seeded directly so no
      // armed timer races the sweeps).
      const id = 'due-owned-by-sid-1';
      (await env.writeFile(
        '$root/_scheduled/$id.json',
        jsonEncode({
          'id': id,
          'dueMs': DateTime.now().millisecondsSinceEpoch - 1000,
          'to': 'sid-1/main',
          'from': 'sid-1/main',
          'text': 'ping later',
          'owner': 'sid-1',
        }),
      )).getOrThrow();
      // A different session's queue re-arms from the same on-disk record:
      // foreign prefix, so it must neither deliver nor delete.
      final foreign = ScheduledMessageQueue(
        env: env,
        repo: () => repo,
        root: () => root,
        selfMailbox: () => 'sid-2/main',
        ownerPrefix: () => 'sid-2',
      );
      await foreign.start();
      expect(await repo.peek('sid-2/main'), isEmpty);
      expect(
        (await env.readTextFile('$root/_scheduled/$id.json')).valueOrNull,
        isNotNull,
      );
      // Restart of the SAME session (matching prefix): the record surfaces
      // in the original owner's live mailbox.
      final restarted = ScheduledMessageQueue(
        env: env,
        repo: () => repo,
        root: () => root,
        selfMailbox: () => 'sid-1/main',
        ownerPrefix: () => 'sid-1',
      );
      await restarted.start();
      expect(
        (await repo.peek('sid-1/main')).single.text,
        contains('[scheduled] ping later'),
      );
      expect(await repo.peek('sid-2/main'), isEmpty);
      // Delivered records are consumed from disk.
      expect(
        (await env.readTextFile('$root/_scheduled/$id.json')).valueOrNull,
        isNull,
      );
    },
  );

  test(
    'pendingSummary reports deliverable count and the nearest due',
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      const root = '/sessions/--work--/messages';
      final repo = FileMessagingRepository(
        env: env,
        root: root,
        homeDir: '/home/user',
        decodeSessionCwd: decodeSessionCwd,
      );
      final queue = ScheduledMessageQueue(
        env: env,
        repo: () => repo,
        root: () => root,
        selfMailbox: () => 'sid/main',
      );
      expect(await queue.pendingSummary(), (count: 0, nextDueMs: null));

      await queue.schedule(text: 'later', delay: const Duration(hours: 2));
      await queue.schedule(text: 'sooner', delay: const Duration(minutes: 25));
      final before = DateTime.now().millisecondsSinceEpoch;
      final summary = await queue.pendingSummary();
      expect(summary.count, 2);
      expect(summary.nextDueMs, greaterThan(before));
      expect(
        summary.nextDueMs,
        lessThanOrEqualTo(before + const Duration(minutes: 26).inMilliseconds),
        reason: 'the nearest due is the 25m record',
      );

      // Delivery consumes records; the summary follows the files.
      await queue.schedule(
        text: 'now',
        delay: const Duration(milliseconds: 10),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await queue.deliverDue();
      expect((await queue.pendingSummary()).count, 2);
    },
  );

  test('pendingSummary skips foreign-owned self-addressed records', () async {
    // Same visibility rule as the delivery timer: a record another live
    // instance owns is not ours to deliver — and not ours to show (the
    // issue #115 indicator must not count reminders that will never fire
    // into this session).
    final env = MemoryExecutionEnv(cwd: '/work');
    const root = '/sessions/--work--/messages';
    final repo = FileMessagingRepository(
      env: env,
      root: root,
      homeDir: '/home/user',
      decodeSessionCwd: decodeSessionCwd,
    );
    final queue = ScheduledMessageQueue(
      env: env,
      repo: () => repo,
      root: () => root,
      selfMailbox: () => 'sid-b/main',
      ownerPrefix: () => 'sid-b',
    );
    const id = 'foreign-pending';
    (await env.writeFile(
      '$root/_scheduled/$id.json',
      jsonEncode({
        'id': id,
        'dueMs': DateTime.now().millisecondsSinceEpoch + 60000,
        'to': 'sid-a/main',
        'from': 'sid-a/main',
        'text': 'not mine',
        'owner': 'sid-a',
      }),
    )).getOrThrow();
    expect(await queue.pendingSummary(), (count: 0, nextDueMs: null));
  });

  test(
    'dispose releases ownership of pending self-addressed records (#59+#88)',
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      const root = '/sessions/--work--/messages';
      final repo = FileMessagingRepository(
        env: env,
        root: root,
        homeDir: '/home/user',
        decodeSessionCwd: decodeSessionCwd,
      );
      await repo.register('sid-1/main');
      final first = ScheduledMessageQueue(
        env: env,
        repo: () => repo,
        root: () => root,
        selfMailbox: () => 'sid-1/main',
        ownerPrefix: () => 'sid-1',
      );
      await first.start();
      await first.schedule(
        text: 'ping later',
        delay: const Duration(minutes: 5),
      );
      // Tearing the session down clears the owner tag so the NEXT
      // session's queue adopts the record (legacy ownerless path).
      first.dispose();
      // The release is fire-and-forget — give it a beat.
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final entries = await env.listDir('$root/_scheduled');
        final file = entries.valueOrNull?.firstOrNull;
        if (file == null) break;
        final text = await env.readTextFile(
          file.path.contains('/') ? file.path : '$root/_scheduled/${file.path}',
        );
        final owner = jsonDecode(text.valueOrNull ?? '{}')['owner'];
        if (owner == '') break;
      }
      final second = ScheduledMessageQueue(
        env: env,
        repo: () => repo,
        root: () => root,
        selfMailbox: () => 'sid-2/main',
        ownerPrefix: () => 'sid-2',
      );
      await second.start();
      // Not due yet (5 minutes) — but the record must be ADOPTABLE: force
      // delivery by making it due, then a sweep lands it in sid-2's inbox.
      final dir = '$root/_scheduled';
      final entry = (await env.listDir(dir)).valueOrNull!.first;
      final path = entry.path.contains('/') ? entry.path : '$dir/${entry.path}';
      final record =
          jsonDecode((await env.readTextFile(path)).valueOrNull!)
              as Map<String, dynamic>;
      expect(record['owner'], '');
      record['dueMs'] = DateTime.now().millisecondsSinceEpoch - 1;
      (await env.writeFile(path, jsonEncode(record))).getOrThrow();
      await second.deliverDue();
      final inbox = await repo.peek('sid-2/main');
      expect(inbox, hasLength(1));
      second.dispose();
    },
  );

  test('dispose never touches foreign-owned records (#88)', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    const root = '/sessions/--work--/messages';
    final repo = FileMessagingRepository(
      env: env,
      root: root,
      homeDir: '/home/user',
      decodeSessionCwd: decodeSessionCwd,
    );
    const id = 'foreign-owned';
    (await env.createDir('$root/_scheduled')).getOrThrow();
    (await env.writeFile(
      '$root/_scheduled/$id.json',
      jsonEncode({
        'id': id,
        'dueMs': DateTime.now().millisecondsSinceEpoch + 60000,
        'to': 'sid-9/main',
        'from': 'sid-9/main',
        'text': 'not yours',
        'owner': 'sid-9',
      }),
    )).getOrThrow();
    final queue = ScheduledMessageQueue(
      env: env,
      repo: () => repo,
      root: () => root,
      selfMailbox: () => 'sid-2/main',
      ownerPrefix: () => 'sid-2',
    );
    await queue.start();
    queue.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final record =
        jsonDecode(
              (await env.readTextFile(
                '$root/_scheduled/$id.json',
              )).valueOrNull!,
            )
            as Map<String, dynamic>;
    expect(record['owner'], 'sid-9');
  });
}
