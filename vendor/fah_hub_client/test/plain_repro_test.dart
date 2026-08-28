import 'dart:async';
import 'dart:io';

import 'package:fah_hub_client/fah_hub_client.dart';
import 'package:test/test.dart';

import 'fake_hub.dart';

const timeout = Timeout(Duration(seconds: 10));
final tinyBackoff = (int _) => const Duration(milliseconds: 5);

void main() {
  late FakeHub hub;
  setUp(() async {
    hub = FakeHub();
    await hub.start();
  });
  tearDown(() async {
    await hub.stop();
  });

  test('PLAIN: after connectTo(name:) the agent still receives DMs',
      () async {
    final home = await Directory.systemTemp.createTemp('dap_plain');
    addTearDown(() => home.delete(recursive: true));

    // A auto-connects under its default (hostname) identity.
    final a = HubClient(
      config: HubConfig(url: hub.url.toString()),
      identity:
          await HubIdentity.load('${home.path}/default.key'),
      backoff: tinyBackoff,
    );
    await a.connect();

    // B is connected and known.
    final b = HubClient(
      config: HubConfig(url: hub.url.toString()),
      identity: await HubIdentity.load('${home.path}/b.key'),
      backoff: tinyBackoff,
    );
    await b.connect();

    // The exact user command shape: /dap host name
    final conn = await a.connectTo(
      '127.0.0.1:${hub.url.port}',
      name: 'flutter_agent_harness',
      home: home.path,
    );
    expect(conn.ok, isTrue);

    // B DMs A's NEW agentId — the exact reported symptom.
    await b.sendDm(conn.agentId, 'plain path hello');
    final inbound = await a.inbound.first
        .timeout(const Duration(seconds: 3))
        .onError((Object e, StackTrace s) => throw 'NO INBOUND DM: $e');
    expect(inbound.plaintext, 'plain path hello');

    await a.disconnect();
    await b.disconnect();
  }, timeout: timeout);

  test('mismatched x25519pub line in a key file must not deafen the agent',
      () async {
    final dir = await Directory.systemTemp.createTemp('dap_key');
    addTearDown(() => dir.delete(recursive: true));
    final keyPath = '${dir.path}/flutter_agent_harness.key';

    // Real identity on disk, but the stored pub line is some OTHER key.
    await HubIdentity.load(keyPath);
    final lines = await File(keyPath).readAsLines();
    final otherPub = (await HubIdentity.generate()).dhPubkeyB64;
    await File(keyPath).writeAsString([
      lines.firstWhere((l) => l.startsWith('ed25519:')),
      lines.firstWhere((l) => l.startsWith('x25519:')),
      'x25519pub:$otherPub',
      '',
    ].join('\n'));

    final b = HubClient(
      config: HubConfig(url: hub.url.toString()),
      identity: await HubIdentity.load(keyPath),
      backoff: tinyBackoff,
    );
    await b.connect();
    final a = HubClient(
      config: HubConfig(url: hub.url.toString()),
      identity: await HubIdentity.generate(),
      backoff: tinyBackoff,
    );
    await a.connect();

    await a.sendDm(b.agentId!, 'must arrive');
    final inbound =
        await b.inbound.first.timeout(const Duration(seconds: 3));
    expect(inbound.plaintext, 'must arrive');

    await a.disconnect();
    await b.disconnect();
  }, timeout: timeout);

  test('identity round-trip: derived pub equals generated pub; stable id',
      () async {
    final dir = await Directory.systemTemp.createTemp('dap_rt');
    addTearDown(() => dir.delete(recursive: true));
    final keyPath = '${dir.path}/rt.key';
    final first = await HubIdentity.load(keyPath);
    final second = await HubIdentity.load(keyPath);
    expect(second.agentId, first.agentId);
    expect(second.dhPublicKey.bytes, first.dhPublicKey.bytes);
    expect(second.signingPubkeyB64, first.signingPubkeyB64);
  }, timeout: timeout);

  test('torn x25519pub line does not break load', () async {
    final dir = await Directory.systemTemp.createTemp('dap_torn');
    addTearDown(() => dir.delete(recursive: true));
    final keyPath = '${dir.path}/torn.key';
    await HubIdentity.load(keyPath);
    final lines = await File(keyPath).readAsLines();
    await File(keyPath).writeAsString([
      lines.firstWhere((l) => l.startsWith('ed25519:')),
      lines.firstWhere((l) => l.startsWith('x25519:')),
      'x25519pub:%%%TORN',
      '',
    ].join('\n'));
    final identity = await HubIdentity.load(keyPath);
    expect(identity.agentId, isNotNull);
  }, timeout: timeout);
}
