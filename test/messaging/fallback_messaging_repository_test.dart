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
  final touched = <String>[];
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
  Future<void> register(String agentId, {String? sessionName}) async {
    registered.add(agentId);
  }

  @override
  Future<void> touch(String agentId) async {
    touched.add(agentId);
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
