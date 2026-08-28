/// Zero-config parity tests (mirrors omp-extension test/dap.test.ts):
/// settings precedence (env > yaml > ~/.dap/config.json > defaults,
/// per-adapter key dir, shared channels file), channel auto-keygen with
/// persistence across client instances, and the chankey invite flow over
/// the fake hub.
library;

import 'dart:convert';
import 'dart:io';

import 'package:fah_hub_client/fah_hub_client.dart';
import 'package:test/test.dart';

import 'fake_hub.dart';

const timeout = Timeout(Duration(seconds: 10));

Future<Directory> tmpHome(String prefix) =>
    Directory.systemTemp.createTemp(prefix);

void main() {
  test(
      'settings precedence: env > yaml > ~/.dap/config.json > defaults; '
      'fah key dir, shared channels file', () async {
    final home = await tmpHome('fah-dap-cfg-');
    addTearDown(() => home.delete(recursive: true));
    final root = home.path;

    // Plain defaults: url, hostname-derived key in the fah subdir,
    // machine-shared channels file. A second agent on the machine needs
    // nothing but a name (or DAP_AGENT_NAME) to get its own identity.
    var s = resolveDapSettings(environment: const {}, home: root);
    expect(s.url, defaultDapUrl);
    final hostname =
        Platform.localHostname.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    expect(s.keyPath, '$root/.dap/keys/fah/$hostname.key');
    expect(s.channelsFile, '$root/.dap/channels.json');
    expect(s.name, isNull);

    // A named agent gets its own default key file.
    s = resolveDapSettings(
        config: const HubConfig(name: 'second'),
        environment: const {},
        home: root);
    expect(s.keyPath, '$root/.dap/keys/fah/second.key');

    // ~/.dap/config.json fills every unset field.
    await Directory('$root/.dap').create(recursive: true);
    final cfgFile = File('$root/.dap/config.json');
    await cfgFile.writeAsString(jsonEncode({
      'url': 'ws://cfg:1/ws',
      'name': 'cfg-agent',
      'keyPath': '/cfg/key',
      'channelsFile': '/cfg/channels.json',
    }));
    s = resolveDapSettings(environment: const {}, home: root);
    expect(s.url, 'ws://cfg:1/ws');
    expect(s.name, 'cfg-agent');
    expect(s.keyPath, '/cfg/key');
    expect(s.channelsFile, '/cfg/channels.json');

    // yaml (explicit tier) beats the file; env beats yaml; file beats
    // defaults; DAP_CHANNELS_FILE (env-only field) wins outright.
    final env = {
      HubConfig.envUrl: 'ws://env:2/ws',
      envChannelsFile: '/env/channels.json',
    };
    s = resolveDapSettings(
      config: HubConfig.fromMap(
          {'url': 'ws://yaml:1/ws', 'keyPath': '/yaml/key'}, env),
      environment: env,
      home: root,
    );
    expect(s.url, 'ws://env:2/ws');
    expect(s.keyPath, '/yaml/key');
    expect(s.channelsFile, '/env/channels.json');

    // An invalid config file counts as absent.
    await cfgFile.writeAsString('{not json');
    s = resolveDapSettings(environment: const {}, home: root);
    expect(s.url, defaultDapUrl);
    expect(s.channelsFile, '$root/.dap/channels.json');
  });

  test('auto-keygen: first send persists keys; a second instance picks them '
      'up, auto-joins, and decrypts', () async {
    final hub = FakeHub();
    await hub.start();
    addTearDown(() => hub.stop());
    final home = await tmpHome('fah-dap-auto-');
    addTearDown(() => home.delete(recursive: true));
    final channelsFile = '${home.path}/nested/dir/channels.json';

    final a = HubClient(
      config: HubConfig(url: hub.url.toString()),
      identity: await HubIdentity.generate(),
      channelStore: await ChannelStore.fromFile(channelsFile),
    );
    await a.connect();

    // First-ever use of #general: keygen + persist + join, then the send.
    final joinedGeneral = hub.joins.firstWhere(
        (j) => j.agentId == a.agentId && j.channel == 'general');
    await a.sendToChannel('general', 'zero config');
    expect((await joinedGeneral).channel, 'general');

    // A second unknown channel: read-modify-write keeps the first one.
    final joinedRandom = hub.joins
        .firstWhere((j) => j.agentId == a.agentId && j.channel == 'random');
    await a.sendToChannel('random', 'still zero config');
    await joinedRandom;

    final saved = await loadChannelKeys(channelsFile);
    expect(saved.keys, ['general', 'random']);
    expect(base64Decode(saved['general']!.pub), hasLength(32));
    expect(base64Decode(saved['general']!.priv), hasLength(32));
    expect(hub.channelMembers['general'], contains(a.agentId));

    // Fresh client, same channels file: zero config pickup + auto-join
    // after welcome. (Subscribe the broadcast stream before connecting.)
    final bJoined = hub.joins.firstWhere(
        (j) => j.agentId != a.agentId && j.channel == 'general');
    final b = HubClient(
      config: HubConfig(url: hub.url.toString()),
      identity: await HubIdentity.generate(),
      channelStore: await ChannelStore.fromFile(channelsFile),
    );
    final inbound = b.inbound
        .firstWhere((m) => m.plaintext == 'second message')
        .timeout(const Duration(seconds: 5));
    await b.connect();
    expect((await bJoined).agentId, b.agentId);
    expect(hub.channelMembers['general'], contains(b.agentId));

    await a.sendToChannel('general', 'second message');
    final msg = await inbound;
    expect(msg.channel, 'general');
    expect(msg.plaintext, 'second message');

    await b.disconnect();
    await a.disconnect();
  }, timeout: timeout);

  test('invite: chankey E2E DM auto-persists + joins + notices on the '
      'steering source; later channel sends decrypt', () async {
    final hub = FakeHub();
    await hub.start();
    addTearDown(() => hub.stop());
    final homeA = await tmpHome('fah-dap-inv-a-');
    final homeB = await tmpHome('fah-dap-inv-b-');
    addTearDown(() => homeA.delete(recursive: true));
    addTearDown(() => homeB.delete(recursive: true));
    final fileA = '${homeA.path}/channels.json';
    final fileB = '${homeB.path}/channels.json';
    await File(fileB).writeAsString('{}'); // B literally starts empty

    final a = HubClient(
      config: HubConfig(url: hub.url.toString(), name: 'alice'),
      identity: await HubIdentity.generate(),
      channelStore: await ChannelStore.fromFile(fileA),
    );
    final b = HubClient(
      config: HubConfig(url: hub.url.toString(), name: 'bob'),
      identity: await HubIdentity.generate(),
      channelStore: await ChannelStore.fromFile(fileB),
    );
    final repositoryB = HubMessagingRepository(b);

    await a.connect();
    await repositoryB.start();

    // Invite on a channel A doesn't hold yet: zero-config creation inlined.
    final aJoined = hub.joins.firstWhere(
        (j) => j.agentId == a.agentId && j.channel == 'general');
    final notice = b.inbound
        .firstWhere((m) => m.plaintext!.startsWith('[hub] invited'))
        .timeout(const Duration(seconds: 5));
    final bJoined = hub.joins.firstWhere(
        (j) => j.agentId == b.agentId && j.channel == 'general');
    await a.inviteTo('general', b.agentId!);

    expect((await aJoined).channel, 'general');
    expect((await loadChannelKeys(fileA))['general']!.pub, isNotEmpty);

    // B got the short notice — not the key JSON — and joined.
    final noticeMsg = await notice;
    expect(noticeMsg.plaintext, '[hub] invited to #general by ${a.agentId}');
    await bJoined;
    expect((await loadChannelKeys(fileB))['general']!.pub,
        (await loadChannelKeys(fileA))['general']!.pub);
    expect(hub.channelMembers['general'], contains(b.agentId));

    // The invite rode a normal E2E DM: the hub only ever saw ciphertext.
    final dm = hub.relayed.firstWhere((f) => f['to'] == b.agentId);
    expect(dm['ciphertext'] as String, isNot(contains('chankey')));

    // The steering source surfaces the notice, never the raw keypair.
    final drained = await repositoryB.drain(b.agentId!);
    expect(drained, hasLength(1));
    expect(drained.single.text, '[hub] invited to #general by ${a.agentId}');

    // A's next channel send decrypts on B.
    final inbound =
        b.inbound.firstWhere((m) => m.plaintext == 'welcome aboard');
    await a.sendToChannel('general', 'welcome aboard');
    expect((await inbound.timeout(const Duration(seconds: 5))).plaintext,
        'welcome aboard');

    await repositoryB.dispose();
    await a.disconnect();
  }, timeout: timeout);

  test('HubPlugin zero-config: no yaml url/keyPath defaults still work — '
      'fah key dir (mkdir -p, 0600), DAP_CHANNELS_FILE store', () async {
    final hub = FakeHub();
    await hub.start();
    addTearDown(() => hub.stop());
    final home = await tmpHome('fah-dap-plugin-');
    addTearDown(() => home.delete(recursive: true));

    final channelsFile = '${home.path}/custom/channels.json';
    final lobbyKeys = await newChannelKeypair();
    await persistChannelKeys(channelsFile, 'lobby', lobbyKeys);

    final plugin = HubPlugin(
      environment: {envChannelsFile: channelsFile},
      home: home.path,
    );
    plugin.register(PluginContext(config: {
      'hub': {'url': hub.url.toString(), 'name': 'zero'},
    }));
    final lobbyJoin =
        hub.joins.firstWhere((j) => j.channel == 'lobby'); // auto-join
    await plugin.start();

    // Identity landed in the per-adapter default dir, 0600, parents made.
    final key = File('${home.path}/.dap/keys/fah/zero.key');
    expect(await key.exists(), isTrue);
    expect((await key.stat()).modeString(), 'rw-------');

    // The channel store came from DAP_CHANNELS_FILE and auto-joined after
    // the welcome.
    expect((await lobbyJoin.timeout(const Duration(seconds: 5))).agentId,
        plugin.agentId);
    expect(plugin.repository!.client.channelStore?.pubOf('lobby'),
        lobbyKeys.pub);

    await plugin.dispose();
  }, timeout: timeout);
}
