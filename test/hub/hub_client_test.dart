import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:fah_hub_client/fah_hub_client.dart';
import 'package:test/test.dart';

import 'fake_hub.dart';

const timeout = Timeout(Duration(seconds: 10));
final tinyBackoff = (int _) => const Duration(milliseconds: 5);

Future<HubClient> connect(
  FakeHub hub,
  HubIdentity identity, {
  Map<String, String> channels = const {},
  Map<String, String> channelSecrets = const {},
  Duration Function(int)? backoff,
}) async {
  final client = HubClient(
    config: HubConfig(
      url: hub.url.toString(),
      channels: channels,
      channelSecrets: channelSecrets,
    ),
    identity: identity,
    backoff: backoff,
  );
  await client.connect();
  return client;
}

void main() {
  late FakeHub hub;

  setUp(() async {
    hub = FakeHub();
    await hub.start();
  });

  tearDown(() async {
    await hub.stop();
  });

  test(
    'hello → welcome handshake; hub verifies the ed25519 signature',
    () async {
      final identity = await HubIdentity.generate();
      final client = await connect(hub, identity);

      // agentId = hex(sha256(ed25519_pubkey_raw))[:16], independently computed
      final digest = await Sha256().hash(identity.signingPublicKey.bytes);
      final expected = digest.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join()
          .substring(0, 16);
      expect(client.agentId, expected);

      // welcomed => the hub accepted our signed hello
      expect(hub.rejectedHellos, 0);
      expect(client.welcomed, completion(expected));
      await client.disconnect();
    },
    timeout: timeout,
  );

  test('hub rejects a hello with a bad signature', () async {
    final identity = await HubIdentity.generate();
    final raw = await WebSocket.connect(hub.url.toString());
    final error = Completer<String>();
    late final StreamSubscription sub;
    sub = raw.listen((dynamic data) {
      final frame = jsonDecode(data as String) as Map;
      if (frame['op'] == 'error') {
        error.complete(frame['code'] as String);
      }
    });
    // hello claiming identity's pubkey but signed by a different key
    final impostor = await Ed25519().newKeyPair();
    final frame = <String, dynamic>{
      'op': 'hello',
      'v': 1,
      'pubkey': identity.signingPubkeyB64,
      'x25519': identity.dhPubkeyB64,
      'nonce': randomHex(16),
      'ts': DateTime.now().millisecondsSinceEpoch,
    };
    frame['sig'] = await signFrame(frame, impostor);
    raw.add(jsonEncode(frame));
    expect(
      await error.future.timeout(const Duration(seconds: 5)),
      'bad_signature',
    );
    expect(hub.rejectedHellos, 1);
    await sub.cancel();
    await raw.close();
  }, timeout: timeout);

  test(
    'signed channel send is relayed and decryptable by the other member',
    () async {
      final channelKeys = await X25519().newKeyPair();
      final channelPub = base64Encode(
        (await channelKeys.extractPublicKey()).bytes,
      );
      final channelPriv = base64Encode(
        await channelKeys.extractPrivateKeyBytes(),
      );

      final alice = await connect(
        hub,
        await HubIdentity.generate(),
        channels: {'general': channelPub},
      );
      final bob = await connect(
        hub,
        await HubIdentity.generate(),
        channels: {'general': channelPub},
        channelSecrets: {'general': channelPriv},
      );

      final received = bob.inbound
          .firstWhere((m) => m.plaintext == 'chan hello')
          .timeout(const Duration(seconds: 5));
      await alice.sendToChannel('general', 'chan hello');
      final msg = await received;

      expect(msg.channel, 'general');
      expect(msg.from, alice.agentId);
      expect(hub.deliveredTo, [bob.agentId]); // sender not echoed
      // hub routed ciphertext only
      expect(jsonEncode(hub.relayed.single), isNot(contains('chan hello')));

      await alice.disconnect();
      await bob.disconnect();
    },
    timeout: timeout,
  );

  test(
    'DM round-trip: whois first, then E2E decrypt on the recipient',
    () async {
      final alice = await connect(
        hub,
        await HubIdentity.generate(),
        backoff: tinyBackoff,
      );
      final bob = await connect(hub, await HubIdentity.generate());

      final received = bob.inbound
          .firstWhere((m) => m.plaintext == 'secret dm')
          .timeout(const Duration(seconds: 5));
      await alice.sendDm(bob.agentId!, 'secret dm');
      final msg = await received;

      expect(msg.from, alice.agentId);
      expect(msg.channel, isNull);
      expect(hub.deliveredTo, [bob.agentId]); // DM reaches recipient only
      expect(hub.whoisQueries, contains(bob.agentId)); // whois before first DM
      expect(jsonEncode(hub.relayed.single), isNot(contains('secret dm')));

      await alice.disconnect();
      await bob.disconnect();
    },
    timeout: timeout,
  );

  test('reconnect: re-hello and flush re-receives the queued DM', () async {
    final alice = await connect(
      hub,
      await HubIdentity.generate(),
      backoff: tinyBackoff,
    );
    final bob = await connect(hub, await HubIdentity.generate());

    // Drop alice's connection hub-side, wait until the hub sees her offline.
    final offline = hub.agentOffline
        .firstWhere((id) => id == alice.agentId)
        .timeout(const Duration(seconds: 5));
    await hub.closeAgent(alice.agentId!);
    await offline;

    // While alice is offline, bob DMs her → hub queues it in her mailbox.
    await bob.sendDm(alice.agentId!, 'queued while away');

    // Alice reconnects on her own (5 ms backoff), re-hellos, and flushes.
    final queued = alice.inbound
        .firstWhere((m) => m.plaintext == 'queued while away')
        .timeout(const Duration(seconds: 5));
    await hub.waitForHellos(3); // alice initial + bob + alice re-hello
    final msg = await queued;

    expect(msg.from, bob.agentId);
    expect(hub.rejectedHellos, 0);
    expect(hub.deliveredTo, isEmpty); // never delivered live: queued path

    await alice.disconnect();
    await bob.disconnect();
  }, timeout: timeout);

  test('presence query lists connected agents', () async {
    final alice = await connect(hub, await HubIdentity.generate());
    final bob = await connect(hub, await HubIdentity.generate());

    final agents = await bob.presenceQuery();
    expect(
      agents.map((a) => a.agentId),
      containsAll([alice.agentId, bob.agentId]),
    );
    expect(
      agents.firstWhere((a) => a.agentId == alice.agentId).dhPublicKey,
      isNotNull,
    );

    await alice.disconnect();
    await bob.disconnect();
  }, timeout: timeout);

  test('status: connected, identity, url, known channels, counters', () async {
    final client = HubClient(
      config: HubConfig(url: hub.url.toString(), channels: {'general': 'AA'}),
      identity: await HubIdentity.generate(),
      backoff: tinyBackoff,
    );

    // Before connecting: honest offline snapshot, channels already known.
    final before = client.status();
    expect(before.connected, isFalse);
    expect(before.agentId, isNull);
    expect(before.name, isNull);
    expect(before.url, hub.url.toString());
    expect(before.channels, ['general']);
    expect(before.hellos, 0);
    expect(before.welcomes, 0);

    await client.connect();
    final status = client.status();
    expect(status.connected, isTrue);
    expect(status.agentId, client.agentId);
    expect(status.url, hub.url.toString());
    expect(status.channels, ['general']);
    expect(status.hellos, 1); // one connection attempt so far
    expect(status.welcomes, 1); // and it was accepted

    await client.disconnect();
    final after = client.status();
    expect(after.connected, isFalse); // disconnect() is synchronous truth
    expect(after.agentId, client.agentId); // identity survives the drop
    expect(after.hellos, 1); // disconnect() disarms the reconnect loop
  }, timeout: timeout);

  test('peers: includes self with online=true and self=true', () async {
    final client = await connect(hub, await HubIdentity.generate());

    final peers = await client.peers();
    final self = peers.firstWhere((p) => p.agentId == client.agentId);
    expect(self.online, isTrue);
    expect(self.self, isTrue);
    expect(peers.length, greaterThanOrEqualTo(1));

    await client.disconnect();
  }, timeout: timeout);

  test(
    'peers: online-only always — offline agents never listed (0.2.0)',
    () async {
      final client = await connect(hub, await HubIdentity.generate());
      final ghost = await connect(hub, await HubIdentity.generate());
      final ghostGone = hub.agentOffline.firstWhere(
        (id) => id == ghost.agentId,
      );
      await ghost.disconnect(); // registered but gone → offline in presence
      await ghostGone; // hub cleaned up its connection row — query can't race it

      final online = await client.peers();
      expect(online.map((p) => p.agentId), isNot(contains(ghost.agentId)));
      expect(online.map((p) => p.agentId), contains(client.agentId));

      await client.disconnect();
    },
    timeout: timeout,
  );

  test('retarget/connectTo: bare host + name + room → second welcome, '
      'new agentId, lobby joined, retired loop stays retired', () async {
    final hub2 = FakeHub();
    await hub2.start();
    addTearDown(() => hub2.stop());
    final home = await Directory.systemTemp.createTemp('fah-dap-conn-');
    addTearDown(() => home.delete(recursive: true));

    final client = HubClient(
      config: HubConfig(url: hub.url.toString()),
      identity: await HubIdentity.generate(),
      channelStore: await ChannelStore.fromFile('${home.path}/channels.json'),
      // long enough that retarget lands while the loop parks in backoff
      backoff: (int _) => const Duration(milliseconds: 400),
    );
    await client.connect();
    final firstId = client.agentId!;
    expect(hub.hellosSeen, 1);

    // network drop → the reconnect loop parks in its 400 ms backoff
    await hub.closeAgent(firstId);
    await Future<void>.delayed(const Duration(milliseconds: 80));

    // subscribe early — the lobby join fires during connectTo itself
    final lobbyJoin = hub2.joins
        .firstWhere((j) => j.channel == 'lobby')
        .timeout(const Duration(seconds: 5));

    // bare host: no scheme, no path — normalized to ws://<host>/ws
    final result = await client.connectTo(
      '127.0.0.1:${hub2.url.port}',
      name: 'bee',
      channel: 'lobby',
      home: home.path,
    );
    expect(result.ok, isTrue);
    expect(result.url, hub2.url.toString());
    expect(result.name, 'bee');
    expect(result.agentId, isNot(firstId)); // new name = new identity
    expect(result.agentId, client.agentId); // recomputed from the new keys
    expect(result.channels, contains('lobby'));
    expect(client.status().welcomes, 2); // the second welcome
    expect(client.status().url, hub2.url.toString());

    final join = await lobbyJoin;
    expect(join.agentId, result.agentId); // lobby joined under the new id

    // name-derived key file, 0600, reloads to the same identity
    final keyFile = File('${home.path}/.dap/keys/fah/bee.key');
    expect((await keyFile.stat()).modeString(), 'rw-------');
    expect((await HubIdentity.load(keyFile.path)).agentId, result.agentId);

    // the retired loop (asleep when retargeted) must never re-hello:
    // a live rogue loop would reconnect and bump the count within ms
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(hub2.hellosSeen, 1);

    await client.disconnect();
  }, timeout: timeout);
  // ---- 0.2.3 stale-secret 401 recovery (contract from the dap side) ----
  //
  // The 401 fires at the HTTP upgrade (bearer rejected before any
  // websocket), which FakeHub never simulates: it has no bearer auth.
  // The hub side of the auth contract lives in [_AuthHub] below, kept in
  // this file on purpose — the regression travels with the contract.

  test('401 on stale config secret + master present → drop secret, '
      're-enroll once, agentId stable, new secret persisted', () async {
    final home = await Directory.systemTemp.createTemp('fah_401_');
    addTearDown(() => home.delete(recursive: true));
    final keyFile = '${home.path}/.dap/keys/fah/reg.key';
    final cfgFile = '${home.path}/.dap/config.json';
    const master = 'master-secret-regression';

    // Phase 1 — first enrollment: master-secret dial, hub issues a
    // client secret, client persists it to the config file.
    final hub1 = _AuthHub(masterSecret: master);
    await hub1.start();
    addTearDown(hub1.stop);
    final identity = await HubIdentity.load(keyFile);
    final dial1 = resolveDapClientSecret(
      environment: {'DAP_MASTER_SECRET': master},
      config: readDapConfig(cfgFile),
    );
    expect(dial1.source, DapSecretSource.master);
    final client1 = _dialClient(hub1.url, identity, dial1, cfgFile);
    addTearDown(client1.disconnect);
    final agentId = await client1.connect();
    expect(agentId, identity.agentId);
    await _persistedSecret(cfgFile, hub1.issued.single);
    await client1.disconnect();
    await hub1.stop();

    // Phase 2 — a hub restart wiped the server-side secrets: the
    // persisted config secret is now stale. Recovery: drop it, dial
    // once more in enroll-mode with the master secret, same identity
    // (production wiring: resolveDapClientSecret → HubClient).
    final hub2 = _AuthHub(masterSecret: master, configPath: cfgFile);
    await hub2.start();
    addTearDown(hub2.stop);
    final reloaded = await HubIdentity.load(keyFile);
    final dial2 = resolveDapClientSecret(
      environment: {'DAP_MASTER_SECRET': master},
      config: readDapConfig(cfgFile),
    );
    expect(dial2.source, DapSecretSource.config);
    final notices = <String>[];
    final client2 = _dialClient(
      hub2.url,
      reloaded,
      dial2,
      cfgFile,
      onNotice: notices.add,
    );
    addTearDown(client2.disconnect);

    expect(await client2.connect(), agentId); // identity NOT wiped
    expect(hub2.rejects, 1); // exactly one 401 …
    expect(hub2.enrolls, 1); // … exactly one re-enroll
    expect(hub2.bearers, [hub1.issued.single, master]);
    // the stale secret was dropped BEFORE the retry dial went out
    expect(hub2.configAtMasterDial, isNot(contains('clientSecret')));
    // the hub-issued replacement is persisted through the enroll path
    final newSecret = hub2.issued.single;
    expect(newSecret, isNot(hub1.issued.single));
    await _persistedSecret(cfgFile, newSecret);
    expect(notices, contains('enrolled: client secret persisted'));
    await client2.disconnect();
  }, timeout: timeout);

  test(
    '401 on env-sourced secret → hard fail, frozen hint, no re-enroll',
    () async {
      final home = await Directory.systemTemp.createTemp('fah_401_');
      addTearDown(() => home.delete(recursive: true));
      final cfgFile = '${home.path}/.dap/config.json';
      final hub = _AuthHub(masterSecret: 'master-secret-regression');
      await hub.start();
      addTearDown(hub.stop);
      // the env secret wins over the master secret — explicit user intent
      final dial = resolveDapClientSecret(
        environment: {
          'DAP_CLIENT_SECRET': 'env-secret-the-hub-never-issued',
          'DAP_MASTER_SECRET': 'master-secret-regression',
        },
        config: readDapConfig(cfgFile),
      );
      expect(dial.source, DapSecretSource.env);
      final client = _dialClient(
        hub.url,
        await HubIdentity.generate(),
        dial,
        cfgFile,
      );
      addTearDown(client.disconnect);
      await expectLater(
        client.connect(),
        throwsA(
          isA<HubError>()
              .having((error) => error.code, 'code', 'unauthorized')
              .having((error) => error.msg, 'msg', unauthorizedMsg),
        ),
      );
      expect(hub.rejects, 1); // single 401, no second dial
      expect(hub.enrolls, isZero);
      expect(readDapConfig(cfgFile), isNot(contains('clientSecret')));
    },
  );

  test('401 on config secret without master → frozen hint, no retry, '
      'stale secret stays persisted', () async {
    final home = await Directory.systemTemp.createTemp('fah_401_');
    addTearDown(() => home.delete(recursive: true));
    final cfgFile = '${home.path}/.dap/config.json';
    await persistDapConfig(clientSecret: 'stale-config-secret', file: cfgFile);
    final hub = _AuthHub(masterSecret: 'master-secret-regression');
    await hub.start();
    addTearDown(hub.stop);
    final dial = resolveDapClientSecret(
      environment: const {}, // no master secret anywhere
      config: readDapConfig(cfgFile),
    );
    expect(dial.source, DapSecretSource.config);
    expect(dial.master, isNull);
    final client = _dialClient(
      hub.url,
      await HubIdentity.generate(),
      dial,
      cfgFile,
    );
    addTearDown(client.disconnect);
    await expectLater(
      client.connect(),
      throwsA(
        isA<HubError>()
            .having((error) => error.code, 'code', 'unauthorized')
            .having((error) => error.msg, 'msg', unauthorizedMsg),
      ),
    );
    expect(hub.rejects, 1);
    expect(hub.enrolls, isZero);
    // nothing was dropped: without a master secret there is no recovery
    expect(readDapConfig(cfgFile)['clientSecret'], 'stale-config-secret');
  }, timeout: timeout);

  test(
    're-enroll retry rejected too → exactly one retry, then frozen hint',
    () async {
      final home = await Directory.systemTemp.createTemp('fah_401_');
      addTearDown(() => home.delete(recursive: true));
      final cfgFile = '${home.path}/.dap/config.json';
      await persistDapConfig(
        clientSecret: 'stale-config-secret',
        file: cfgFile,
      );
      // the master this client holds was rotated away — both dials 401
      final hub = _AuthHub(masterSecret: 'hub-current-secret');
      await hub.start();
      addTearDown(hub.stop);
      final dial = resolveDapClientSecret(
        environment: {'DAP_MASTER_SECRET': 'rotated-away-master'},
        config: readDapConfig(cfgFile),
      );
      expect(dial.source, DapSecretSource.config);
      final client = _dialClient(
        hub.url,
        await HubIdentity.generate(),
        dial,
        cfgFile,
      );
      addTearDown(client.disconnect);
      await expectLater(
        client.connect(),
        throwsA(
          isA<HubError>()
              .having((error) => error.code, 'code', 'unauthorized')
              .having((error) => error.msg, 'msg', unauthorizedMsg),
        ),
      );
      expect(hub.rejects, 2); // stale dial + one master retry, never a loop
      expect(hub.enrolls, isZero);
      expect(hub.bearers, ['stale-config-secret', 'rotated-away-master']);
      // the provably dead secret is still dropped from the config
      expect(readDapConfig(cfgFile), isNot(contains('clientSecret')));
    },
  );
}

/// The test's dial wiring, exactly as production builds it
/// (HubPlugin: resolveDapClientSecret → HubClient).
HubClient _dialClient(
  Uri url,
  HubIdentity identity,
  ({String? token, bool enroll, DapSecretSource source, String? master}) dial,
  String configFile, {
  void Function(String notice)? onNotice,
}) => HubClient(
  config: HubConfig(url: url.toString()),
  identity: identity,
  clientSecret: dial.token,
  enroll: dial.enroll,
  secretSource: dial.source,
  masterSecret: dial.master,
  configFile: configFile,
  onNotice: onNotice,
  backoff: tinyBackoff,
);

/// Polls the persisted config until the hub-issued [secret] shows up
/// (`_onEnrolled` persists asynchronously after the welcome); fails with
/// the last observed state instead of hanging.
Future<void> _persistedSecret(String file, String secret) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  var config = readDapConfig(file);
  while (config['clientSecret'] != secret) {
    if (DateTime.now().isAfter(deadline)) {
      fail('client secret never persisted to $file (last: $config)');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    config = readDapConfig(file);
  }
}

/// Minimal hub-side of the bearer-auth + enrollment contract, for the
/// 401 regression tests: FakeHub has no bearer auth, and the 401 fires
/// at the HTTP upgrade — before any websocket frame — so it cannot be
/// simulated through FakeHub. A dial is accepted with the master secret
/// (enroll-mode) or any issued client secret; anything else is rejected
/// with HTTP 401 exactly like the real hub. Signature checks are
/// omitted on purpose: the client never verifies the hub, and the
/// handshake itself is covered by the FakeHub suite. A `{'t':'enroll'}`
/// frame issues and remembers a fresh client secret, answered with
/// `{'t':'enrolled', …}`.
class _AuthHub {
  _AuthHub({required this.masterSecret, this.configPath});

  static var _instanceCount = 0;

  final String masterSecret;

  /// Snapshot source for [configAtMasterDial]: the config file is read
  /// the moment the recovery dial (master-secret bearer) arrives, so the
  /// test can prove the stale secret was dropped before the retry.
  final String? configPath;

  final String _prefix = 'h${_instanceCount++}';
  final List<String> issued = [];
  final List<String> bearers = [];
  Map<String, dynamic>? configAtMasterDial;
  int rejects = 0;
  int enrolls = 0;

  HttpServer? _server;

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    unawaited(_serve());
  }

  Uri get url => Uri.parse('ws://127.0.0.1:${_server!.port}/ws');

  Future<void> stop() async {
    await _server?.close(force: true);
  }

  Future<void> _serve() async {
    await for (final request in _server!) {
      final bearer = _bearerOf(request);
      bearers.add(bearer ?? '');
      if (bearer != masterSecret && !issued.contains(bearer)) {
        rejects++;
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
        continue;
      }
      if (bearer == masterSecret && configPath != null) {
        configAtMasterDial ??= readDapConfig(configPath!);
      }
      unawaited(_handle(await WebSocketTransformer.upgrade(request)));
    }
  }

  String? _bearerOf(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    return header != null && header.startsWith('Bearer ')
        ? header.substring('Bearer '.length)
        : null;
  }

  Future<void> _handle(WebSocket ws) async {
    try {
      await for (final data in ws) {
        final frame = jsonDecode(data as String) as Map<String, dynamic>;
        switch (frame['op'] as String?) {
          case 'hello':
            final digest = await Sha256().hash(
              base64Decode(frame['pubkey'] as String),
            );
            final agentId = digest.bytes
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join()
                .substring(0, 16);
            ws.add(jsonEncode({'op': 'welcome', 'agentId': agentId}));
          case 'flush':
            ws.add(jsonEncode({'op': 'flushed', 'count': 0}));
          case 'presence_query':
            ws.add(
              jsonEncode({
                'op': 'presence',
                'replyTo': frame['id'],
                'agents': const <Map<String, dynamic>>[],
              }),
            );
        }
        if (frame['t'] == 'enroll') {
          enrolls++;
          final secret = 'issued-$_prefix-$enrolls';
          issued.add(secret);
          ws.add(jsonEncode({'t': 'enrolled', 'secret': secret}));
        }
      }
    } on Object {
      // socket error — fall through to cleanup
    }
  }
}
