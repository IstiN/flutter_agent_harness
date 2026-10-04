@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// A mutable fake wall clock (issue #259): hosts freeze with OS sleep, so
/// scheduling math rides an injectable clock — never real sleeps in tests.
final class _FakeClock {
  DateTime now = DateTime.utc(2026, 9, 13, 2);
  void jump(Duration d) => now = now.add(d);
}

/// A repo whose `send` throws for selected texts (issue #270): a failing
/// send must be isolated from the delivery heartbeat, not fatal to it.
final class _FlakyRepo implements MessagingRepository {
  _FlakyRepo(this._inner);

  final MessagingRepository _inner;
  final failingTexts = <String>{};

  /// Records whose send already failed once: the throw happens exactly
  /// once per record (AC3 — the retry on the next leg must succeed).
  final _failedOnce = <String>{};
  final sends = <AgentMessage>[];

  @override
  Future<void> send(AgentMessage message) async {
    sends.add(message);
    final text = message.text.startsWith('[scheduled] ')
        ? message.text.substring('[scheduled] '.length)
        : message.text;
    if (failingTexts.any(text.contains) && _failedOnce.add(message.id)) {
      throw StateError('injected send failure for "$text"');
    }
    await _inner.send(message);
  }

  @override
  Future<void> register(
    String agentId, {
    String? sessionName,
    List<AgentCapability> capabilities = const [],
  }) => _inner.register(
    agentId,
    sessionName: sessionName,
    capabilities: capabilities,
  );

  @override
  Future<void> touch(String agentId, {bool busy = false}) =>
      _inner.touch(agentId, busy: busy);

  @override
  Future<List<AgentMessage>> peek(String agentId) => _inner.peek(agentId);

  @override
  Future<List<AgentMessage>> drain(String agentId) => _inner.drain(agentId);

  @override
  Future<List<MailboxEntry>> directory() => _inner.directory();
}

/// An env whose `listDir` fails for the first [failFirst] calls
/// (AC5): one transient IO error on a scan leg must re-arm the
/// heartbeat loudly instead of silently disarming it.
final class _FlakyScanEnv implements ExecutionEnv {
  _FlakyScanEnv(this._delegate, {required this.failFirst});

  final MemoryExecutionEnv _delegate;
  int failFirst;
  int failures = 0;

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) async {
    if (failures < failFirst) {
      failures++;
      return Err(
        FileError(
          FileErrorCode.unknown,
          'injected listDir failure',
          path: path,
        ),
      );
    }
    return _delegate.listDir(path);
  }

  @override
  String get cwd => _delegate.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _delegate.absolutePath(path);

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _delegate.readBinaryFile(path);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _delegate.readTextFile(path);

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _delegate.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _delegate.writeBinaryFile(path, content);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _delegate.writeFile(path, content);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _delegate.appendFile(path, content);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _delegate.fileInfo(path);

  @override
  Future<Result<bool, FileError>> exists(String path) => _delegate.exists(path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _delegate.createDir(path, recursive: recursive);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _delegate.remove(path, recursive: recursive, force: force);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _delegate.joinPath(parts);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// An env whose `listDir` fails exactly the next [failNext] calls
/// (review follow-up): the AC5 pin covers a failure on the ARMING scan,
/// but the same `_scanPending` throw inside a timer tick's DELIVERY pass
/// must ALSO leave a `scan_failed` receipt when the failure is transient
/// (the re-arm scan after it succeeds — so the arming-path catch never
/// runs and, pre-fix, the failed pass left no trail at all).
final class _GatedScanEnv implements ExecutionEnv {
  _GatedScanEnv(this._delegate);

  final MemoryExecutionEnv _delegate;
  int failNext = 0;

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) async {
    if (failNext > 0) {
      failNext--;
      return Err(
        FileError(
          FileErrorCode.unknown,
          'injected listDir failure',
          path: path,
        ),
      );
    }
    return _delegate.listDir(path);
  }

  @override
  String get cwd => _delegate.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _delegate.absolutePath(path);

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _delegate.readBinaryFile(path);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _delegate.readTextFile(path);

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _delegate.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _delegate.writeBinaryFile(path, content);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _delegate.writeFile(path, content);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _delegate.appendFile(path, content);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _delegate.fileInfo(path);

  @override
  Future<Result<bool, FileError>> exists(String path) => _delegate.exists(path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _delegate.createDir(path, recursive: recursive);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _delegate.remove(path, recursive: recursive, force: force);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _delegate.joinPath(parts);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

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

  test('gh-1180 review T7: an adopted self-record re-addressed to the LIVE '
      'mailbox delivers FROM the live mailbox too — the resumed chain stays '
      'self-shaped (from == to) and lands in the exempt wake lane across a '
      'session-id change', () async {
    // The restart shape from the ticket: a session re-created under a
    // new id adopts its reminders, and _deliveryTarget rewrites `to` to
    // the live mailbox. If `from` keeps the pinned historical address,
    // the delivery is from=old/to=new — foreign-chatter shaped — and
    // the resumed night-watch dies again within <=10 wakes.
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
      text: 'night-watch sweep',
      delay: const Duration(milliseconds: 500),
    );
    queue.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    self = 'sid-2/main';
    final restarted = ScheduledMessageQueue(
      env: env,
      repo: () => repo,
      root: () => root,
      selfMailbox: () => self,
    );
    await restarted.start();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final delivered = (await repo.peek('sid-2/main')).single;
    expect(delivered.fromId, 'sid-2/main', reason: 're-addressed with `to`');
    expect(delivered.toId, 'sid-2/main');
    expect(
      InboxWakePolicy.isScheduledSelfMail(delivered),
      isTrue,
      reason: 'the resumed chain must stay in the exempt lane, not chatter',
    );
  });

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

  group('wall-clock catch-up (issue #259)', () {
    (ScheduledMessageQueue, FileMessagingRepository, _FakeClock) harness(
      MemoryExecutionEnv env,
    ) {
      const root = '/sessions/--work--/messages';
      final repo = FileMessagingRepository(
        env: env,
        root: root,
        homeDir: '/home/user',
        decodeSessionCwd: decodeSessionCwd,
      );
      final clock = _FakeClock();
      final queue = ScheduledMessageQueue(
        env: env,
        repo: () => repo,
        root: () => root,
        selfMailbox: () => 'sid-1/main',
        ownerPrefix: () => 'sid-1',
        clock: () => clock.now,
      );
      return (queue, repo, clock);
    }

    test('an overdue record is delivered by the catch-up sweep immediately '
        '(turn start), not at the next timer tick', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final (queue, repo, clock) = harness(env);
      await queue.schedule(
        text: 'standup notes',
        delay: const Duration(minutes: 30),
      );
      // The record came due while no tick ran (host busy/asleep): the
      // sweep a turn start performs must deliver it NOW — the armed
      // real-time timer is still ~30 minutes out and must not be the
      // delivery path this test waits on.
      clock.jump(const Duration(minutes: 31));
      expect(await queue.deliverDue(), 1);
      final mail = await repo.peek('sid-1/main');
      expect(mail.single.text, contains('[scheduled] standup notes'));
      queue.dispose();
    });

    test('a clock jump (system sleep) catches up immediately and delivers '
        'each due record exactly once (no N-fold replay)', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final (queue, repo, clock) = harness(env);
      for (var i = 0; i < 3; i++) {
        await queue.schedule(
          text: 'cycle $i',
          delay: Duration(minutes: 30 * (i + 1)),
        );
      }
      // Six hours of "sleep": every record is overdue on wake.
      clock.jump(const Duration(hours: 6));
      // The post-wake heartbeat + a concurrent turn-start sweep race:
      // the in-flight guard keeps delivery exactly-once per record.
      final counts = await Future.wait([
        queue.deliverDue(),
        queue.deliverDue(),
      ]);
      expect(counts.fold<int>(0, (a, b) => a + b), 3);
      // A repeated sweep must not replay missed cycles.
      expect(await queue.deliverDue(), 0);
      final mail = await repo.peek('sid-1/main');
      expect(mail, hasLength(3));
      // No pending record files survive the catch-up.
      final left =
          (await env.listDir(
            '/sessions/--work--/messages/_scheduled',
          )).valueOrNull ??
          const [];
      expect(left.where((e) => e.path.endsWith('.json')), isEmpty);
      queue.dispose();
    });

    test('normal awake timing is unchanged: no early fire', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final (queue, repo, clock) = harness(env);
      await queue.schedule(
        text: 'half minute',
        delay: const Duration(seconds: 30),
      );
      clock.jump(const Duration(seconds: 29));
      expect(await queue.deliverDue(), 0);
      expect(await repo.peek('sid-1/main'), isEmpty);
      clock.jump(const Duration(seconds: 1));
      expect(await queue.deliverDue(), 1);
      expect((await repo.peek('sid-1/main')).single.text, contains('half'));
      queue.dispose();
    });

    test(
      'a recurring self re-arm after a clock jump resumes from "now"',
      () async {
        final env = MemoryExecutionEnv(cwd: '/work');
        final (queue, repo, clock) = harness(env);
        await queue.schedule(
          text: 'monitor',
          delay: const Duration(minutes: 30),
        );
        clock.jump(const Duration(hours: 6));
        expect(await queue.deliverDue(), 1);
        // The agent re-arms the next cycle from the CURRENT wall clock —
        // the missed 02:34/03:04/… cycles are not replayed.
        await queue.schedule(
          text: 'monitor',
          delay: const Duration(minutes: 30),
        );
        final dir = '/sessions/--work--/messages/_scheduled';
        final entry = (await env.listDir(
          dir,
        )).valueOrNull!.singleWhere((e) => e.path.endsWith('.json'));
        final path = entry.path.contains('/')
            ? entry.path
            : '$dir/${entry.path}';
        final record =
            jsonDecode((await env.readTextFile(path)).valueOrNull!)
                as Map<String, dynamic>;
        expect(
          record['dueMs'],
          clock.now.millisecondsSinceEpoch +
              const Duration(minutes: 30).inMilliseconds,
        );
        clock.jump(const Duration(minutes: 30));
        expect(await queue.deliverDue(), 1);
        expect(await repo.peek('sid-1/main'), hasLength(2));
        queue.dispose();
      },
    );
  });
  group('leg-timer failure isolation (issue #270)', () {
    test(
      'a failed send re-arms the leg timer and delivers on the next leg',
      () async {
        final env = MemoryExecutionEnv(cwd: '/work');
        const root = '/sessions/--work--/messages';
        final repo = FileMessagingRepository(
          env: env,
          root: root,
          homeDir: '/home/user',
          decodeSessionCwd: decodeSessionCwd,
        );
        final flaky = _FlakyRepo(repo)..failingTexts.add('flaky');
        final clock = _FakeClock();
        final errors = <String>[];
        final queue = ScheduledMessageQueue(
          env: env,
          repo: () => flaky,
          root: () => root,
          selfMailbox: () => 'sid-1/main',
          clock: () => clock.now,
          failureBackoff: const Duration(milliseconds: 40),
          onError: errors.add,
        );
        await repo.register('sid-1/main');
        await queue.schedule(
          text: 'flaky reminder',
          delay: const Duration(milliseconds: 30),
        );
        clock.jump(const Duration(milliseconds: 30));
        // Leg 1: the send throws. Pre-fix the error escaped the timer
        // callback unhandled and _arm() never ran — the heartbeat chain
        // died silently. Post-fix: logged, record kept, timer re-armed.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(errors.single, contains('injected send failure'));
        // The re-armed timer delivered the kept record on the next leg.
        final mail = await repo.peek('sid-1/main');
        expect(mail.single.text, contains('[scheduled] flaky reminder'));
        expect((await queue.pendingSummary()).count, 0);
        queue.dispose();
      },
    );

    test(
      'one failing record does not block its sweep-mates and is retried',
      () async {
        final env = MemoryExecutionEnv(cwd: '/work');
        const root = '/sessions/--work--/messages';
        final repo = FileMessagingRepository(
          env: env,
          root: root,
          homeDir: '/home/user',
          decodeSessionCwd: decodeSessionCwd,
        );
        final flaky = _FlakyRepo(repo)..failingTexts.add('poison');
        final clock = _FakeClock();
        final errors = <String>[];
        final queue = ScheduledMessageQueue(
          env: env,
          repo: () => flaky,
          root: () => root,
          selfMailbox: () => 'sid-1/main',
          clock: () => clock.now,
          failureBackoff: const Duration(milliseconds: 40),
          onError: errors.add,
        );
        await repo.register('sid-1/main');
        // Poison sorts ahead of the healthy record (scheduled first, and
        // ids are timestamp-ordered): a mid-sweep abort would starve it.
        await queue.schedule(text: 'poison reminder', delay: Duration.zero);
        await queue.schedule(text: 'healthy reminder', delay: Duration.zero);
        await queue.deliverDue();
        // The re-armed timer retries the failed record on the next leg
        // (failureBackoff 40ms); every interleaving of that retry with
        // the explicit sweeps above converges to the same end state.
        await Future<void>.delayed(const Duration(milliseconds: 120));
        // The sweep survived the poison failure (healthy mail delivered
        // despite poison sorting ahead of it), the failed record was not
        // lost — it was retried and delivered exactly once — and the
        // failure was logged.
        final mail = await repo.peek('sid-1/main');
        expect(mail, hasLength(2));
        expect(mail.where((m) => m.text.contains('poison')), hasLength(1));
        expect(mail.where((m) => m.text.contains('healthy')), hasLength(1));
        expect((await queue.pendingSummary()).count, 0);
        expect(errors, isNotEmpty);
        expect(errors.every((e) => e.contains('poison')), isTrue);
        queue.dispose();
      },
    );
  });

  group('gh-970: a subagent self-reminder fires into the subagent inbox', () {
    (ScheduledMessageQueue, FileMessagingRepository, _FakeClock) harness(
      MemoryExecutionEnv env,
    ) {
      const root = '/sessions/--work--/messages';
      final repo = FileMessagingRepository(
        env: env,
        root: root,
        homeDir: '/home/user',
        decodeSessionCwd: decodeSessionCwd,
      );
      final clock = _FakeClock();
      final queue = ScheduledMessageQueue(
        env: env,
        repo: () => repo,
        root: () => root,
        selfMailbox: () => 'sid-1/main',
        ownerPrefix: () => 'sid-1',
        clock: () => clock.now,
      );
      return (queue, repo, clock);
    }

    test('a self-addressed record naming a subagent mailbox is NOT '
        're-addressed to main', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final (queue, repo, clock) = harness(env);
      // The child scheduled a self-reminder: to == from == its own
      // namespaced mailbox (subagent_scope resolved the default).
      await queue.schedule(
        text: 'next monitoring pass',
        delay: const Duration(minutes: 15),
        to: 'sid-1/monitor-a',
        from: 'sid-1/monitor-a',
      );
      clock.jump(const Duration(minutes: 16));
      expect(await queue.deliverDue(), 1);
      final childMail = await repo.peek('sid-1/monitor-a');
      expect(
        childMail,
        hasLength(1),
        reason:
            'gh-970: the sweeper used to re-address every self-addressed '
            'record to its own mailbox, stealing the child reminder into '
            'main',
      );
      expect(childMail.single.text, contains('[scheduled] next monitoring'));
      expect(childMail.single.fromId, 'sid-1/monitor-a');
      expect(await repo.peek('sid-1/main'), isEmpty);
      queue.dispose();
    });

    test('a foreign-owned subagent reminder is left for its owner (theft '
        'guard covers child mail too)', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final (queue, repo, clock) = harness(env);
      // Hand-written record owned by ANOTHER session (the only way this
      // shape exists — the tool always stamps the scheduler's own owner):
      // session sid-2's monitor scheduled itself; sid-1's sweeper must
      // neither deliver it (anywhere) nor delete it.
      final dir = '/sessions/--work--/messages/_scheduled';
      (await env.createDir(dir)).getOrThrow();
      (await env.writeFile(
        '$dir/foreign.json',
        jsonEncode({
          'id': 'foreign',
          'dueMs': clock.now.millisecondsSinceEpoch,
          'to': 'sid-2/monitor-b',
          'from': 'sid-2/monitor-b',
          'text': 'other session monitor',
          'owner': 'sid-2',
        }),
      )).getOrThrow();
      clock.jump(const Duration(minutes: 2));
      expect(await queue.deliverDue(), 0);
      expect(await repo.peek('sid-2/monitor-b'), isEmpty);
      expect(await repo.peek('sid-1/main'), isEmpty);
      // The record stays on disk for its owner's sweeper.
      final record = jsonDecode(
        (await env.readTextFile('$dir/foreign.json')).valueOrNull!,
      );
      expect(record['id'], 'foreign');
      queue.dispose();
    });

    test('schedule_message resolves the subagent sender as the default '
        'recipient', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final (queue, repo, clock) = harness(env);
      final tool = scheduleMessageTool(
        queue,
        // The host wiring: the active subagent's mailbox, or null on the
        // main agent (legacy defaulting).
        senderMailbox: () => 'sid-1/monitor-a',
      );
      final result = await tool.execute(
        {'text': 'next monitoring pass', 'delay': '15m'},
        null,
        null,
      );
      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect(text, isNot(contains('error')));
      clock.jump(const Duration(minutes: 16));
      expect(await queue.deliverDue(), 1);
      final mail = await repo.peek('sid-1/monitor-a');
      expect(mail, hasLength(1));
      expect(mail.single.fromId, 'sid-1/monitor-a');
      expect(await repo.peek('sid-1/main'), isEmpty);
      queue.dispose();
    });

    test('schedule_message on the main agent (null sender) keeps the legacy '
        'self default', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final (queue, repo, clock) = harness(env);
      final tool = scheduleMessageTool(queue);
      await tool.execute({'text': 'standup', 'delay': '1m'}, null, null);
      clock.jump(const Duration(minutes: 2));
      expect(await queue.deliverDue(), 1);
      final mail = await repo.peek('sid-1/main');
      expect(mail, hasLength(1));
      expect(mail.single.text, contains('[scheduled] standup'));
      queue.dispose();
    });
  });

  group('gh-1180: receipts + loud scan re-arm', () {
    /// Reads the receipts trail as decoded JSON lines (missing file: []).
    Future<List<Map<String, dynamic>>> receiptEvents(
      ExecutionEnv env,
      String root,
    ) async {
      final text = (await env.readTextFile(
        '$root/_scheduled/receipts.jsonl',
      )).valueOrNull;
      if (text == null || text.isEmpty) return const [];
      return [
        for (final line in text.trim().split('\n'))
          jsonDecode(line) as Map<String, dynamic>,
      ];
    }

    /// Waits out an async condition (no real-clock dependency).
    Future<void> waitForTrue(Future<bool> Function() condition) async {
      for (var i = 0; i < 400; i++) {
        if (await condition()) return;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      fail('timed out waiting: async condition');
    }

    test(
      'AC5: a listDir failure on a leg is logged + receipted and the '
      'heartbeat re-arms — the record still delivers after recovery',
      () async {
        const root = '/sessions/--work--/messages';
        final env = _FlakyScanEnv(
          MemoryExecutionEnv(cwd: '/work'),
          // Budget covers the arming scan plus the first backoff legs; the
          // point is the failure is LOUD and the heartbeat SURVIVES it.
          failFirst: 2,
        );
        final repo = FileMessagingRepository(
          env: env,
          root: root,
          homeDir: '/home/user',
          decodeSessionCwd: decodeSessionCwd,
        );
        final clock = _FakeClock();
        final errors = <String>[];
        final queue = ScheduledMessageQueue(
          env: env,
          repo: () => repo,
          root: () => root,
          selfMailbox: () => 'sid-1/main',
          clock: () => clock.now,
          failureBackoff: const Duration(milliseconds: 40),
          onError: errors.add,
          receipts: ScheduledReceiptLog(
            env: env,
            path: () => '$root/_scheduled/receipts.jsonl',
          ),
        );
        await repo.register('sid-1/main');
        await queue.schedule(
          text: 'survivor',
          delay: const Duration(milliseconds: 60),
        );
        // The arming scan hit the injected failure: logged, receipted,
        // re-armed at the backoff (pre-fix the queue silently disarmed).
        await waitForTrue(
          () async => errors.any((e) => e.contains('scan failed')),
        );
        final events = await receiptEvents(env, root);
        expect(
          events.any((e) => e['event'] == 'scan_failed'),
          isTrue,
          reason: 'the scan failure is receipted',
        );
        // The recovered heartbeat delivers the record once due.
        clock.jump(const Duration(milliseconds: 60));
        await waitForTrue(
          () async => (await repo.peek(
            'sid-1/main',
          )).any((m) => m.text.contains('survivor')),
        );
        queue.dispose();
      },
    );

    test(
      'gh-1180 review: a scan failure inside a DELIVERY pass is receipted '
      'too — the arming path and the delivery pass leave the identical '
      'scan_failed trail (AC4)',
      () async {
        const root = '/sessions/--work--/messages';
        final env = _GatedScanEnv(MemoryExecutionEnv(cwd: '/work'));
        final repo = FileMessagingRepository(
          env: env,
          root: root,
          homeDir: '/home/user',
          decodeSessionCwd: decodeSessionCwd,
        );
        final clock = _FakeClock();
        final errors = <String>[];
        final queue = ScheduledMessageQueue(
          env: env,
          repo: () => repo,
          root: () => root,
          selfMailbox: () => 'sid-1/main',
          clock: () => clock.now,
          failureBackoff: const Duration(milliseconds: 40),
          onError: errors.add,
          receipts: ScheduledReceiptLog(
            env: env,
            path: () => '$root/_scheduled/receipts.jsonl',
          ),
        );
        await repo.register('sid-1/main');
        // The arming scan runs first (it succeeds, the timer arms for the
        // due time); gate ONLY the next listDir — the timer tick's
        // delivery-pass scan. The failure is transient: the re-arm scan
        // right after succeeds, so the arming-path catch never runs.
        await queue.schedule(
          text: 'delayed reminder',
          delay: const Duration(milliseconds: 30),
        );
        env.failNext = 1;
        clock.jump(const Duration(milliseconds: 30));
        // The recovered heartbeat delivers the record once the re-armed
        // leg fires.
        await waitForTrue(
          () async => (await repo.peek(
            'sid-1/main',
          )).any((m) => m.text.contains('delayed reminder')),
        );
        final events = await receiptEvents(env, root);
        expect(
          events.any((e) => e['event'] == 'scan_failed'),
          isTrue,
          reason:
              'a TRANSIENT delivery-pass scan failure must still leave a '
              'scan_failed receipt — pre-fix the re-arm scan recovered '
              'silently and the post-mortem saw nothing between the last '
              'scheduled line and the delivered one (AC4)',
        );
        queue.dispose();
      },
    );

    test('AC4: the queue receipts the whole lifecycle — scheduled, '
        'delivery_failed (isolated), delivered with lag', () async {
      const root = '/sessions/--work--/messages';
      final env = MemoryExecutionEnv(cwd: '/work');
      final repo = FileMessagingRepository(
        env: env,
        root: root,
        homeDir: '/home/user',
        decodeSessionCwd: decodeSessionCwd,
      );
      final flaky = _FlakyRepo(repo)..failingTexts.add('poison');
      final clock = _FakeClock();
      final queue = ScheduledMessageQueue(
        env: env,
        repo: () => flaky,
        root: () => root,
        selfMailbox: () => 'sid-1/main',
        clock: () => clock.now,
        failureBackoff: const Duration(milliseconds: 40),
        onError: (_) {},
        receipts: ScheduledReceiptLog(
          env: env,
          path: () => '$root/_scheduled/receipts.jsonl',
        ),
      );
      await repo.register('sid-1/main');
      await queue.schedule(
        text: 'poison',
        delay: const Duration(milliseconds: 30),
      );
      await queue.schedule(
        text: 'healthy',
        delay: const Duration(milliseconds: 30),
      );
      // Leg 1: the poison send fails (receipted, record kept); the
      // healthy one delivers. The re-armed leg retries the poison.
      clock.jump(const Duration(milliseconds: 30));
      await waitForTrue(
        () async => (await repo.peek('sid-1/main')).length == 2,
      );
      final events = await receiptEvents(env, root);
      final byEvent = [for (final e in events) e['event'] as String];
      expect(byEvent.where((e) => e == 'scheduled'), hasLength(2));
      expect(byEvent.where((e) => e == 'delivery_failed'), hasLength(1));
      expect(byEvent.where((e) => e == 'delivered'), hasLength(2));
      final delivered = events.where((e) => e['event'] == 'delivered');
      // lagMs: every delivered receipt carries its delivery lag.
      for (final e in delivered) {
        expect(e['lagMs'], isA<int>());
      }
      // A post-mortem can correlate by record id.
      final poisonId = (events.firstWhere(
        (e) => e['event'] == 'delivery_failed',
      ))['id'];
      expect(
        delivered.any((e) => e['id'] == poisonId),
        isTrue,
        reason: 'the retried record delivers under the same id',
      );
      queue.dispose();
    });

    test(
      'schedule() itself is receipted (id, due, target, text preview)',
      () async {
        const root = '/sessions/--work--/messages';
        final env = MemoryExecutionEnv(cwd: '/work');
        final repo = FileMessagingRepository(
          env: env,
          root: root,
          homeDir: '/home/user',
          decodeSessionCwd: decodeSessionCwd,
        );
        final clock = _FakeClock();
        final queue = ScheduledMessageQueue(
          env: env,
          repo: () => repo,
          root: () => root,
          selfMailbox: () => 'sid-1/main',
          clock: () => clock.now,
          receipts: ScheduledReceiptLog(
            env: env,
            path: () => '$root/_scheduled/receipts.jsonl',
          ),
        );
        await repo.register('sid-1/main');
        await queue.schedule(
          text: 'standup reminder',
          delay: const Duration(minutes: 5),
        );
        final events = await receiptEvents(env, root);
        final scheduled = events
            .where((e) => e['event'] == 'scheduled')
            .toList();
        expect(scheduled, hasLength(1));
        expect(scheduled.single['text'], 'standup reminder');
        expect(scheduled.single['to'], 'sid-1/main');
        expect(scheduled.single['dueMs'], isA<int>());
        expect(scheduled.single['id'], isA<String>());
        queue.dispose();
      },
    );
  });
}
