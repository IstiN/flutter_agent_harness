import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// A scriptable repository standing in for either transport side: the hub
/// (as a [RoutingMessagingRepository] primary) or the file fabric (as the
/// fallback).
final class _ScriptedRepo
    implements MessagingRepository, RoutingMessagingRepository {
  final sent = <AgentMessage>[];
  final inboxes = <String, List<AgentMessage>>{};
  final registered = <String>[];
  final announcedCapabilities = <String, List<AgentCapability>>{};
  final touched = <String>[];
  final busyTouched = <String>[];
  final entries = <MailboxEntry>[];

  /// Recipients [resolveTarget] answers for (the hub roster).
  final resolvable = <String>{};
  bool connected = true;

  /// File-fabric mode: sends deposit into the recipient's inbox (a sender
  /// drops mail in the peer's mailbox). Hub mode only logs the delivery.
  bool depositOnSend = false;
  bool failSends = false;
  bool failDirectory = false;
  var drainCount = 0;

  @override
  bool get isConnected => connected;

  @override
  Future<String?> resolveTarget(String toId) async =>
      resolvable.contains(toId) ? toId : null;

  void receive(String mailbox, AgentMessage message) =>
      inboxes.putIfAbsent(mailbox, () => []).add(message);

  @override
  Future<void> send(AgentMessage message) async {
    if (failSends) throw StateError('transport down');
    sent.add(message);
    if (depositOnSend) receive(message.toId, message);
  }

  @override
  Future<void> register(
    String agentId, {
    String? sessionName,
    List<AgentCapability> capabilities = const [],
  }) async {
    registered.add(agentId);
    if (capabilities.isNotEmpty) {
      announcedCapabilities[agentId] = capabilities;
    }
  }

  @override
  Future<void> touch(String agentId, {bool busy = false}) async {
    touched.add(agentId);
    if (busy) busyTouched.add(agentId);
  }

  @override
  Future<List<AgentMessage>> peek(String agentId) async => [
    ...?inboxes[agentId],
  ];

  @override
  Future<List<AgentMessage>> drain(String agentId) async {
    drainCount++;
    return inboxes.remove(agentId) ?? const [];
  }

  @override
  Future<List<MailboxEntry>> directory() async {
    if (failDirectory) throw StateError('transport down');
    return [...entries];
  }
}

AgentMessage _msg(
  String id, {
  String from = 'main',
  String to = 'hub-peer',
  String sentAt = '2026-01-01T00:00:01.000Z',
}) => AgentMessage(
  id: id,
  fromId: from,
  toId: to,
  text: 'body of $id',
  sentAt: sentAt,
);

void main() {
  late _ScriptedRepo hub;
  late _ScriptedRepo files;
  late FallbackMessagingRepository fabric;

  setUp(() {
    hub = _ScriptedRepo();
    files = _ScriptedRepo()..depositOnSend = true;
    fabric = FallbackMessagingRepository(primary: hub, fallback: files)
      ..primaryMailbox = () => 'main';
  });

  test(
    'hub-resolvable recipients route over the hub, never the files',
    () async {
      hub.resolvable.add('hub-peer');
      await fabric.send(_msg('m1'));
      expect(hub.sent, hasLength(1));
      expect(hub.sent.single.id, 'm1');
      expect(files.sent, isEmpty);
    },
  );

  test('unknown recipients land in the file fabric untouched', () async {
    await fabric.send(_msg('m1', to: 'file-peer'));
    expect(files.sent, hasLength(1));
    expect(hub.sent, isEmpty);
  });

  test('disconnected hub routes everything to files', () async {
    hub.connected = false;
    hub.resolvable.add('hub-peer');
    await fabric.send(_msg('m1', to: 'file-peer'));
    expect(files.sent, hasLength(1));
    expect(hub.sent, isEmpty);
  });

  test('channel send while the hub is down fails honestly', () async {
    hub.connected = false;
    await expectLater(
      fabric.send(_msg('m1', to: '#general')),
      throwsStateError,
    );
    expect(files.sent, isEmpty);
  });

  test('channel send over a live hub goes hub-ward', () async {
    hub.resolvable.add('#general');
    await fabric.send(_msg('m1', to: '#general'));
    expect(hub.sent.single.toId, '#general');
    expect(files.sent, isEmpty);
  });

  test(
    'hub send failure falls back to files and forwards on reconnect',
    () async {
      hub.resolvable.add('hub-peer');
      hub.failSends = true;
      await fabric.send(_msg('m1'));
      expect(files.sent, hasLength(1));
      expect(files.inboxes['hub-peer'], hasLength(1));

      // Hub heals; the next fabric send flushes the queued copy hub-ward and
      // removes it from the file inbox so a file-polling peer sees no dup.
      hub.failSends = false;
      await fabric.send(_msg('m2', to: 'file-peer'));
      expect(hub.sent.map((m) => m.id), ['m1']);
      expect(files.sent.map((m) => m.id), ['m1', 'm2']);
      expect(files.inboxes['hub-peer'], isNull);
      expect(files.inboxes['file-peer'], hasLength(1));
    },
  );

  test('forward keeps the file copy while the hub stays broken', () async {
    hub.resolvable.add('hub-peer');
    hub.failSends = true;
    await fabric.send(_msg('m1'));
    await fabric.send(_msg('m2', to: 'file-peer'));
    expect(files.inboxes['hub-peer'], hasLength(1));
    expect(files.inboxes['file-peer'], hasLength(1));
    expect(hub.sent, isEmpty);
  });

  test('drain merges hub + file mail into the primary mailbox only', () async {
    hub.receive('main', _msg('h1', sentAt: '2026-01-01T00:00:02.000Z'));
    files.receive('main', _msg('f1', sentAt: '2026-01-01T00:00:01.000Z'));

    final drained = await fabric.drain('main');
    // Oldest first regardless of transport.
    expect(drained.map((m) => m.id).toList(), ['f1', 'h1']);
    expect(hub.drainCount, 1);
    expect(await fabric.drain('main'), isEmpty);
    expect(hub.drainCount, 2); // the empty second drain still merged

    // A subagent mailbox drains from files alone — the hub is untouched.
    files.receive('sub1', _msg('s1'));
    final child = await fabric.drain('sub1');
    expect(child.single.id, 's1');
    expect(hub.drainCount, 2);
  });

  test('merged drains dedupe by message id', () async {
    hub.receive('main', _msg('d1'));
    files.receive('main', _msg('d1'));
    final drained = await fabric.drain('main');
    expect(drained, hasLength(1));
    expect(drained.single.id, 'd1');
  });

  test('a hub send failure queued while the hub DROPS stays pending', () async {
    hub.resolvable.add('hub-peer');
    hub.failSends = true;
    await fabric.send(_msg('m1')); // queued while connected (sends fail)
    expect(files.inboxes['hub-peer'], hasLength(1));

    // The hub goes down before the flush: a disconnected resolve cannot
    // distinguish "not a hub peer" from "not connected yet" — nothing may
    // be untracked.
    hub.connected = false;
    hub.failSends = false;
    await fabric.send(_msg('m2', to: 'file-peer'));
    expect(hub.sent, isEmpty);

    // Reconnect: the first PROBE (peek — the CLI's 2s inbox poll) flushes
    // the queue without waiting for the next send.
    hub.connected = true;
    await fabric.peek('main');
    expect(hub.sent.map((m) => m.id), ['m1']);
    expect(files.inboxes['hub-peer'], isNull);
  });

  test(
    're-wrapped hub frames dedupe on sender+time+body, not just id',
    () async {
      files.receive('main', _msg('d1', from: 'p1'));
      // The same logical message with the fresh frame id the wire assigns
      // per delivery: identical sender, timestamp and body, different id.
      hub.receive(
        'main',
        AgentMessage(
          id: 'fresh-frame-id',
          fromId: 'p1',
          toId: 'main',
          text: 'body of d1',
          sentAt: '2026-01-01T00:00:01.000Z',
        ),
      );
      final drained = await fabric.drain('main');
      expect(drained, hasLength(1));
      // The merge is hub-first, so the wire copy's id survives — the point
      // is ONE delivery, not which id wins.
      expect(drained.single.id, 'fresh-frame-id');
    },
  );

  test('peek reads both transports without consuming', () async {
    hub.receive('main', _msg('h1'));
    files.receive('main', _msg('f1'));
    expect((await fabric.peek('main')).map((m) => m.id), ['f1', 'h1']);
    expect((await fabric.peek('main')).map((m) => m.id), ['f1', 'h1']);
    expect(hub.drainCount, 0);
    expect(files.inboxes['main'], hasLength(1));
  });

  test('register and touch reach both transports', () async {
    await fabric.register('main', sessionName: 'goal_builder');
    await fabric.touch('main');
    expect(hub.registered, ['main']);
    expect(files.registered, ['main']);
    expect(hub.touched, ['main']);
    expect(files.touched, ['main']);
  });

  test('presence state and capabilities forward to both transports', () async {
    const capabilities = [
      AgentCapability(name: 'yoclip.render', description: 'Render to MP4'),
    ];
    await fabric.register(
      'main',
      sessionName: 'goal_builder',
      capabilities: capabilities,
    );
    await fabric.touch('main', busy: true);
    expect(hub.announcedCapabilities['main'], capabilities);
    expect(files.announcedCapabilities['main'], capabilities);
    expect(hub.busyTouched, ['main']);
    expect(files.busyTouched, ['main']);
  });

  test('directory merges both views; file entries win on collision', () async {
    files.entries.add(const MailboxEntry(id: 'local', name: 'goal_builder'));
    hub.entries.add(const MailboxEntry(id: 'hubpeer', name: 'studio'));
    hub.entries.add(const MailboxEntry(id: 'local', name: 'HUB-WINS?'));
    final entries = await fabric.directory();
    final ids = entries.map((e) => e.id).toSet();
    expect(ids, {'local', 'hubpeer'});
    expect(entries.firstWhere((e) => e.id == 'local').name, 'goal_builder');
  });

  test('broken hub hides only its own peers from the directory', () async {
    files.entries.add(const MailboxEntry(id: 'local'));
    final broken = _ScriptedRepo()
      ..failDirectory = true
      ..entries.add(const MailboxEntry(id: 'hidden'));
    final fabric2 = FallbackMessagingRepository(
      primary: broken,
      fallback: files,
    );
    final entries = await fabric2.directory();
    expect(entries.map((e) => e.id), ['local']);
  });

  test('retarget keeps identity stable across hub delivery', () async {
    hub.resolvable.add('display-name');
    await fabric.send(
      _msg('m1', to: 'display-name', sentAt: '2026-01-01T00:00:01.000Z'),
    );
    final delivered = hub.sent.single;
    expect(delivered.id, 'm1');
    expect(delivered.toId, 'display-name');
    expect(delivered.fromId, 'main');
  });
}
