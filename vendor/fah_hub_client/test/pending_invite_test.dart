/// Pending auto-invite by name (mirrors omp-extension's pending invites):
/// config back-compat for the `invites` key, arming (unknown/offline name
/// → no error, channel auto-created, connect line returned, deduped),
/// the immediate paths (16-hex id, online name), the ambiguity guard,
/// poller-tick delivery, the shared-config self-invite guard, and
/// welcome-time redelivery after a restart.
library;

import 'dart:convert';
import 'dart:io';

import 'package:fah_hub_client/fah_hub_client.dart';
import 'package:test/test.dart';

import 'fake_hub.dart';

const timeout = Timeout(Duration(seconds: 10));

Future<Directory> tmpHome(String prefix) =>
    Directory.systemTemp.createTemp(prefix);

Future<HubClient> connectNamed(
  FakeHub hub,
  String name,
  String channelsFile,
) async {
  final client = HubClient(
    config: HubConfig(url: hub.url.toString(), name: name),
    identity: await HubIdentity.generate(),
    channelStore: await ChannelStore.fromFile(channelsFile),
  );
  await client.connect();
  return client;
}

void main() {
  test('config back-compat: missing/non-array invites → [], persist '
      'replaces authoritatively and keeps other keys', () async {
    final tmp = await tmpHome('fah-pend-cfg-');
    addTearDown(() => tmp.delete(recursive: true));
    final cfgFile = '${tmp.path}/config.json';

    // File written before invites existed: key absent → empty list.
    await File(cfgFile).writeAsString(jsonEncode(
        {'url': 'ws://legacy:9/ws', 'name': 'legacy', 'channels': ['ops']}));
    expect(readPendingInvites(cfgFile), isEmpty);

    // Authoritative persist: invites replaced, other keys untouched.
    await persistDapConfig(
        invites: [const PendingInvite(name: 'newbie', channel: 'general')],
        file: cfgFile);
    final after = readDapConfig(cfgFile);
    expect(readPendingInvites(cfgFile),
        [const PendingInvite(name: 'newbie', channel: 'general')]);
    expect(after['url'], 'ws://legacy:9/ws');
    expect((after['channels'] as List).cast<String>(), ['ops']);

    // Delivery removal: an empty list persists (entry leaves the file).
    await persistDapConfig(invites: const [], file: cfgFile);
    expect(readPendingInvites(cfgFile), isEmpty);

    // Non-array invites key → empty; malformed entries are skipped.
    await File(cfgFile)
        .writeAsString(jsonEncode({'invites': 'corrupt'}));
    expect(readPendingInvites(cfgFile), isEmpty);
    await File(cfgFile).writeAsString(jsonEncode({
      'invites': [
        {'name': 3, 'channel': 'general'},
        {'name': 'ok', 'channel': 'team'},
        'junk',
      ]
    }));
    expect(readPendingInvites(cfgFile),
        [const PendingInvite(name: 'ok', channel: 'team')]);
  });

  test('dapHostOf: scheme and trailing /ws stripped for connect lines',
      () {
    expect(dapHostOf('ws://127.0.0.1:8787/ws'), '127.0.0.1:8787');
    expect(dapHostOf('wss://hub.example.com/ws'), 'hub.example.com');
    expect(dapHostOf('ws://h:1/other'), 'h:1/other');
    expect(dapHostOf('127.0.0.1:1'), '127.0.0.1:1');
  });

  test('arm: unknown name does not error — channel auto-created + joined '
      'at arm time, invite persisted (deduped), connect line returned',
      () async {
    final hub = FakeHub();
    await hub.start();
    addTearDown(() => hub.stop());
    final tmp = await tmpHome('fah-pend-arm-');
    addTearDown(() => tmp.delete(recursive: true));
    final cfgFile = '${tmp.path}/config.json';
    final storeFile = '${tmp.path}/channels.json';

    final a = await connectNamed(hub, 'alice', storeFile);
    addTearDown(a.disconnect);
    final poller = PendingInvites(client: a, configFile: cfgFile);

    final aJoined = hub.joins
        .firstWhere((j) => j.agentId == a.agentId && j.channel == 'general')
        .timeout(const Duration(seconds: 5));
    final result = await poller.invite('carol');

    expect(result.ok, isTrue);
    expect(result.pending, isTrue);
    expect(result.channel, 'general');
    expect(result.to, 'carol');
    expect(result.connectLine,
        'send to carol:  /dap 127.0.0.1:${hub.url.port} carol');
    expect((await aJoined).agentId, a.agentId); // inviter joined at arm
    expect(await loadChannelKeys(storeFile), contains('general'));
    expect(readPendingInvites(cfgFile),
        [const PendingInvite(name: 'carol', channel: 'general')]);

    // Same (name, channel) with different case: deduped, still one entry.
    final again = await poller.invite('CAROL', channel: 'general');
    expect(again.pending, isTrue);
    expect(readPendingInvites(cfgFile), hasLength(1));
    expect(poller.pending, hasLength(1));

    // Not connected: honest failure, nothing armed.
    final offline = HubClient(
      config: HubConfig(url: hub.url.toString()),
      identity: await HubIdentity.generate(),
    );
    final down = await PendingInvites(client: offline, configFile: cfgFile)
        .invite('carol');
    expect(down.ok, isFalse);
    expect(down.pending, isFalse);
    expect(down.error, contains('not connected'));
  }, timeout: timeout);

  test('online name: immediate chankey DM (case-insensitive), nothing '
      'armed in config', () async {
    final hub = FakeHub();
    await hub.start();
    addTearDown(() => hub.stop());
    final tmp = await tmpHome('fah-pend-on-');
    addTearDown(() => tmp.delete(recursive: true));
    final cfgFile = '${tmp.path}/config.json';
    final fileA = '${tmp.path}/a.json';
    final fileB = '${tmp.path}/b.json';
    await File(fileB).writeAsString('{}'); // B literally starts empty

    final a = await connectNamed(hub, 'alice', fileA);
    addTearDown(a.disconnect);
    final b = await connectNamed(hub, 'bob', fileB);
    addTearDown(b.disconnect);
    final poller = PendingInvites(client: a, configFile: cfgFile);

    final notice = b.inbound
        .firstWhere((m) => m.plaintext!.startsWith('[hub] invited'))
        .timeout(const Duration(seconds: 5));
    final bJoined = hub.joins
        .firstWhere((j) => j.agentId == b.agentId && j.channel == 'general')
        .timeout(const Duration(seconds: 5));

    final result = await poller.invite('BoB'); // case-insensitive match

    expect(result.ok, isTrue);
    expect(result.pending, isFalse);
    expect(result.to, b.agentId);
    expect(await notice, isNotNull);
    await bJoined;
    expect((await loadChannelKeys(fileB))['general']!.pub,
        (await loadChannelKeys(fileA))['general']!.pub);
    expect(File(cfgFile).existsSync(), isFalse); // nothing ever armed
  }, timeout: timeout);

  test('16-hex agent id: immediate chankey DM on the explicit channel',
      () async {
    final hub = FakeHub();
    await hub.start();
    addTearDown(() => hub.stop());
    final tmp = await tmpHome('fah-pend-id-');
    addTearDown(() => tmp.delete(recursive: true));
    final cfgFile = '${tmp.path}/config.json';
    final fileA = '${tmp.path}/a.json';
    final fileB = '${tmp.path}/b.json';

    final a = await connectNamed(hub, 'alice', fileA);
    addTearDown(a.disconnect);
    final b = await connectNamed(hub, 'bob', fileB);
    addTearDown(b.disconnect);
    final poller = PendingInvites(client: a, configFile: cfgFile);

    final bJoined = hub.joins
        .firstWhere((j) => j.agentId == b.agentId && j.channel == 'team')
        .timeout(const Duration(seconds: 5));
    final result = await poller.invite(b.agentId!, channel: 'team');

    expect(result.ok, isTrue);
    expect(result.pending, isFalse);
    expect(result.channel, 'team');
    await bJoined;
    expect(readPendingInvites(cfgFile), isEmpty);
  }, timeout: timeout);

  test('ambiguous name: honest error listing both ids, nothing armed',
      () async {
    final hub = FakeHub();
    await hub.start();
    addTearDown(() => hub.stop());
    final tmp = await tmpHome('fah-pend-amb-');
    addTearDown(() => tmp.delete(recursive: true));
    final cfgFile = '${tmp.path}/config.json';

    // One offline registry entry + one online, same display name.
    final gone = await connectNamed(hub, 'dup', '${tmp.path}/gone.json');
    await gone.disconnect();
    final live = await connectNamed(hub, 'dup', '${tmp.path}/live.json');
    addTearDown(live.disconnect);
    final a = await connectNamed(hub, 'alice', '${tmp.path}/a.json');
    addTearDown(a.disconnect);
    final poller = PendingInvites(client: a, configFile: cfgFile);

    final result = await poller.invite('dup');

    expect(result.ok, isFalse);
    expect(result.error, contains('ambiguous'));
    expect(result.error, contains(gone.agentId!));
    expect(result.error, contains(live.agentId!));
    expect(readPendingInvites(cfgFile), isEmpty);
  }, timeout: timeout);

  test('poller tick: invitee connects later → chankey DM, joins, keypair '
      'persisted, pending removed, notice surfaced', () async {
    final hub = FakeHub();
    await hub.start();
    addTearDown(() => hub.stop());
    final tmp = await tmpHome('fah-pend-tick-');
    addTearDown(() => tmp.delete(recursive: true));
    final cfgFile = '${tmp.path}/config.json';
    final fileA = '${tmp.path}/a.json';
    final fileB = '${tmp.path}/b.json';
    await File(fileB).writeAsString('{}');

    final a = await connectNamed(hub, 'alice', fileA);
    addTearDown(a.disconnect);
    final notices = <String>[];
    final poller = PendingInvites(
      client: a,
      configFile: cfgFile,
      onNotice: notices.add,
      interval: const Duration(milliseconds: 10),
    )..start();
    addTearDown(poller.dispose);

    expect((await poller.invite('carol')).pending, isTrue); // armed

    final b = await connectNamed(hub, 'carol', fileB);
    addTearDown(b.disconnect);

    final notice = await b.inbound
        .firstWhere((m) => m.plaintext!.startsWith('[hub] invited'))
        .timeout(const Duration(seconds: 5));
    expect(notice.plaintext, '[hub] invited to #general by ${a.agentId}');
    await hub.joins
        .firstWhere((j) => j.agentId == b.agentId && j.channel == 'general')
        .timeout(const Duration(seconds: 5));

    expect((await loadChannelKeys(fileB))['general']!.pub,
        (await loadChannelKeys(fileA))['general']!.pub);
    expect(readPendingInvites(cfgFile), isEmpty); // consumed after delivery
    expect(poller.pending, isEmpty);
    expect(notices, contains('invited carol to #general'));
    // The hub only ever saw ciphertext, never the chankey payload.
    final dm = hub.relayed.firstWhere((f) => f['to'] == b.agentId);
    expect(dm['ciphertext'] as String, isNot(contains('chankey')));
  }, timeout: timeout);

  test('shared-config self-invite guard: own name never self-delivers',
      () async {
    final hub = FakeHub();
    await hub.start();
    addTearDown(() => hub.stop());
    final tmp = await tmpHome('fah-pend-self-');
    addTearDown(() => tmp.delete(recursive: true));
    final cfgFile = '${tmp.path}/config.json';

    final a = await connectNamed(hub, 'alice', '${tmp.path}/a.json');
    addTearDown(a.disconnect);

    // A pending armed under our own display name (case-insensitive).
    await persistDapConfig(
        invites: [const PendingInvite(name: 'Alice', channel: 'general')],
        file: cfgFile);
    final poller = PendingInvites(client: a, configFile: cfgFile)..start();
    addTearDown(poller.dispose);

    await poller.deliver();

    expect(poller.pending, hasLength(1)); // kept, never self-delivered
    expect(hub.relayed.where((f) => f['to'] == a.agentId), isEmpty);
  }, timeout: timeout);

  test('welcome-time redelivery: a fresh inviter instance delivers '
      'without waiting a tick', () async {
    final hub = FakeHub();
    await hub.start();
    addTearDown(() => hub.stop());
    final tmp = await tmpHome('fah-pend-restart-');
    addTearDown(() => tmp.delete(recursive: true));
    final cfgFile = '${tmp.path}/config.json';
    final fileA = '${tmp.path}/a.json';
    final fileB = '${tmp.path}/b.json';
    await File(fileB).writeAsString('{}');

    // Inviter arms the invite, then goes away entirely (restart).
    final a1 = await connectNamed(hub, 'alice', fileA);
    final poller1 = PendingInvites(client: a1, configFile: cfgFile);
    final a1Joined = hub.joins
        .firstWhere((j) => j.agentId == a1.agentId && j.channel == 'general')
        .timeout(const Duration(seconds: 5));
    expect((await poller1.invite('carol')).pending, isTrue);
    await a1Joined; // arm completed: channel created, pending persisted
    await poller1.dispose();
    await a1.disconnect();

    // The invitee connects while the inviter is gone.
    final b = await connectNamed(hub, 'carol', fileB);
    addTearDown(b.disconnect);

    // Fresh inviter instance, same config: welcome-time check delivers.
    final a2 = HubClient(
      config: HubConfig(url: hub.url.toString(), name: 'alice2'),
      identity: await HubIdentity.generate(),
      channelStore: await ChannelStore.fromFile(fileA),
    );
    addTearDown(a2.disconnect);
    final poller2 = PendingInvites(client: a2, configFile: cfgFile)..start();
    addTearDown(poller2.dispose);
    await a2.connect();

    final notice = await b.inbound
        .firstWhere((m) => m.plaintext!.startsWith('[hub] invited'))
        .timeout(const Duration(seconds: 5));
    expect(notice.plaintext, '[hub] invited to #general by ${a2.agentId}');
    await hub.joins
        .firstWhere((j) => j.agentId == b.agentId && j.channel == 'general')
        .timeout(const Duration(seconds: 5));
    expect(readPendingInvites(cfgFile), isEmpty); // consumed after restart
  }, timeout: timeout);

  test('HubPlugin.inviteTo: pending result, invites persisted under '
      '~/.dap/config.json, StateError before start', () async {
    final hub = FakeHub();
    await hub.start();
    addTearDown(() => hub.stop());
    final tmp = await tmpHome('fah-pend-plugin-');
    addTearDown(() => tmp.delete(recursive: true));

    final plugin = HubPlugin(environment: {}, home: tmp.path);
    plugin.register(PluginContext(config: {
      'hub': {'url': hub.url.toString(), 'name': 'zed'},
    }));
    await plugin.start();
    // Subscribe before the invite — the join fires during the call.
    final zedJoined = hub.joins
        .firstWhere((j) => j.agentId == plugin.agentId && j.channel == 'general')
        .timeout(const Duration(seconds: 5));

    final result = await plugin.inviteTo('carol');
    expect(result.ok, isTrue);
    expect(result.pending, isTrue);
    expect(result.connectLine,
        'send to carol:  /dap 127.0.0.1:${hub.url.port} carol');
    expect(readPendingInvites('${tmp.path}/.dap/config.json'),
        [const PendingInvite(name: 'carol', channel: 'general')]);
    expect((await zedJoined).agentId, plugin.agentId); // created + joined
    await plugin.dispose();

    // Before start: honest StateError, not a silent result.
    final unstarted = HubPlugin(environment: {});
    unstarted.register(PluginContext());
    expect(unstarted.inviteTo('carol'), throwsStateError);
  }, timeout: timeout);
}
