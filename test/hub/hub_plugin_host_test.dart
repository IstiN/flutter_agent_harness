@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:fa_hub_client/fa_hub_client.dart' as hub;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/startup.dart'
    show buildRedactionPipeline;
import 'package:flutter_agent_harness/src/hub/dap_membership.dart';
import 'package:test/test.dart';

import '../../bin/fah_hub_plugin.dart';

const _hubUrl = 'ws://unit.test/ws';
const _selfId = 'self-agent';

final class _IO implements PluginIO {
  final lines = <String>[];

  @override
  void write(String text) => lines.add(text);

  @override
  void writeln(String text) => lines.add(text);

  String get text => lines.join('\n');
}

final class _MemoryHubRepository extends hub.HubMessagingRepository {
  _MemoryHubRepository(super.client);

  final inboxes = <String, List<hub.AgentMessage>>{};
  final sent = <hub.AgentMessage>[];

  void add(hub.AgentMessage message) {
    inboxes.putIfAbsent(message.toId, () => []).add(message);
  }

  @override
  Future<List<hub.AgentMessage>> peek(String agentId) async {
    return List.of(inboxes[agentId] ?? const []);
  }

  @override
  Future<List<hub.AgentMessage>> drain(String agentId) async {
    return inboxes.remove(agentId) ?? [];
  }

  @override
  Future<void> send(hub.AgentMessage message) async {
    sent.add(message);
  }
}

final class _StubHubPlugin extends hub.HubPlugin {
  _StubHubPlugin({
    required Map<String, String> environment,
    required String home,
    required this.currentStatus,
    required this.memoryRepository,
    this.peerList = const [],
  }) : super(environment: environment, home: home);

  hub.HubStatus currentStatus;
  final _MemoryHubRepository memoryRepository;
  List<hub.AgentInfo> peerList;
  var startCalls = 0;
  final connectCalls = <({String host, String? name, String? channel})>[];

  @override
  Future<void> start({hub.HubIdentity? identity}) async {
    startCalls++;
  }

  @override
  Future<hub.HubStatus> status() async => currentStatus;

  @override
  Future<List<hub.AgentInfo>> peers() async => peerList;

  @override
  hub.HubMessagingRepository get repository => memoryRepository;

  @override
  String get agentId => _selfId;

  @override
  Future<hub.DapConnection> connectTo(
    String host, {
    String? name,
    String? channel,
  }) async {
    connectCalls.add((host: host, name: name, channel: channel));
    return (
      ok: true,
      url: host,
      name: name,
      agentId: _selfId,
      channels: [?channel],
    );
  }
}

final class _HostFixture {
  _HostFixture(this.plugin, this.context, this.io, this.host);

  final _StubHubPlugin plugin;
  final PluginContext context;
  final _IO io;
  final HubPluginHost host;

  _MemoryHubRepository get repository => plugin.memoryRepository;

  AgentTool tool(String name) {
    return context.tools.singleWhere((tool) => tool.name == name);
  }

  ExternalInbox get hubInbox {
    return context.externalInboxes.singleWhere(
      (inbox) => inbox.hasPending != null,
    );
  }
}

const _connectedStatus = hub.HubStatus(
  connected: true,
  agentId: _selfId,
  name: 'self',
  url: _hubUrl,
  channels: ['room'],
  welcomes: 1,
  hellos: 1,
);

DapChannelMembership _membership(
  String channel, {
  String hubUrl = _hubUrl,
  String? pub,
  String? priv,
}) {
  return DapChannelMembership(
    hubUrl: hubUrl,
    channelId: channel,
    scope: DapChannelScope.session,
    joinedAt: DateTime.utc(2026, 1, 1),
    pub: pub,
    priv: priv,
  );
}

hub.AgentMessage _mail(
  String id,
  String toId, {
  String fromId = 'sender',
  String text = 'body',
  int hops = 0,
}) {
  return hub.AgentMessage(
    id: id,
    fromId: fromId,
    toId: toId,
    text: text,
    sentAt: '2026-01-01T00:00:00.000Z',
    hops: hops,
  );
}

Future<void> _waitUntil(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('condition did not become true');
}

Future<_HostFixture> _fixture(
  Directory home, {
  List<DapChannelMembership> memberships = const [],
  List<hub.AgentInfo> peers = const [],
  hub.HubStatus status = _connectedStatus,
  PluginPickOption? pick,
  PluginAskLine? ask,
}) async {
  final environment = <String, String>{
    hub.envMasterSecret: 'test-master',
    'DAP_HUB_URL': _hubUrl,
    'DAP_KEY_PASSPHRASE': 'pass',
  };
  final client = hub.HubClient(
    config: const hub.HubConfig(url: _hubUrl),
    identity: await hub.HubIdentity.generate(),
  )..agentId = _selfId;
  final repository = _MemoryHubRepository(client);
  final plugin = _StubHubPlugin(
    environment: environment,
    home: home.path,
    currentStatus: status,
    memoryRepository: repository,
    peerList: peers,
  );
  final io = _IO();
  final context = PluginContext(
    env: MemoryExecutionEnv(cwd: home.path),
    io: io,
    pickOption: pick,
    askLine: ask,
    readSessionRecords: (type) async => [
      for (final membership in memberships) membership.toJson(),
    ],
  );
  final host = HubPluginHost(
    plugin,
    environment: environment,
    home: home.path,
    localHubUrl: _hubUrl,
    hubHealthProbe: (port) async => false,
    hubSpawner: (port) async {},
  );
  host.register(context);
  await _waitUntil(() async => plugin.startCalls > 0);
  await Future<void>.delayed(Duration.zero);
  return _HostFixture(plugin, context, io, host);
}

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('hub-plugin-host-test');
  });

  tearDown(() async {
    if (!await home.exists()) return;
    // Boot seeding is intentionally fire-and-forget. Give an in-flight
    // atomic overlay rename a bounded chance to settle before recursively
    // deleting the fixture, rather than failing on transient ENOTEMPTY.
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        await home.delete(recursive: true);
        return;
      } on FileSystemException {
        if (attempt == 9 || !await home.exists()) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  });

  test(
    'publicChannelFor distinguishes keyless, keyed, and other-hub channels',
    () async {
      final fixture = await _fixture(
        home,
        memberships: [
          _membership('public'),
          _membership('private', pub: 'pub', priv: 'priv'),
          _membership('elsewhere', hubUrl: 'ws://other.test/ws'),
        ],
      );

      expect(
        await HubPluginHost.publicChannelFor(fixture.plugin, 'public'),
        isTrue,
      );
      expect(
        await HubPluginHost.publicChannelFor(fixture.plugin, 'private'),
        isFalse,
      );
      expect(
        await HubPluginHost.publicChannelFor(fixture.plugin, 'elsewhere'),
        isFalse,
      );
      expect(
        await HubPluginHost.publicChannelFor(fixture.plugin, 'missing'),
        isFalse,
      );
      expect(
        await HubPluginHost.publicChannelFor(hub.HubPlugin(), 'public'),
        isFalse,
      );
    },
  );

  test('a torn priv-without-pub membership is never public and fails '
      'closed instead of auto-keygen (gh-1888 review)', () async {
    final fixture = await _fixture(
      home,
      memberships: [_membership('torn', priv: 'private-key')],
    );

    expect(
      await HubPluginHost.publicChannelFor(fixture.plugin, 'torn'),
      isFalse,
    );
    expect(
      await HubPluginHost.privateChannelKeyMissing(fixture.plugin, 'torn'),
      isTrue,
    );
  });

  test(
    'boot surfaces malformed scoped-membership warnings to the user',
    () async {
      final dir = Directory('${home.path}/.fah')..createSync();
      File(
        '${dir.path}/dap.json',
      ).writeAsStringSync('{"channels":[{"channelId":"broken"}]}');

      final fixture = await _fixture(home);
      expect(
        fixture.io.text,
        contains('skipped a malformed project membership'),
      );
    },
  );

  test('plugin dispose removes the runtime plaintext-key overlay', () async {
    final fixture = await _fixture(
      home,
      memberships: [_membership('private', pub: 'pub', priv: 'priv')],
    );
    final overlay = File('${home.path}/.dap/runtime/channels.json');
    expect(await overlay.exists(), isTrue);

    await fixture.host.dispose();
    expect(await overlay.exists(), isFalse);
    await fixture.host.dispose(); // idempotent teardown
  });

  test('dispose() before register() never lets the host seed plaintext '
      'keys and does not permanently disable cleanup (gh-1895 review)', () async {
    final environment = <String, String>{
      hub.envMasterSecret: 'test-master',
      'DAP_HUB_URL': _hubUrl,
      'DAP_KEY_PASSPHRASE': 'pass',
    };
    final client = hub.HubClient(
      config: const hub.HubConfig(url: _hubUrl),
      identity: await hub.HubIdentity.generate(),
    )..agentId = _selfId;
    final plugin = _StubHubPlugin(
      environment: environment,
      home: home.path,
      currentStatus: _connectedStatus,
      memoryRepository: _MemoryHubRepository(client),
    );
    final host = HubPluginHost(
      plugin,
      environment: environment,
      home: home.path,
      localHubUrl: _hubUrl,
      hubHealthProbe: (port) async => false,
      hubSpawner: (port) async {},
    );

    // Teardown before register(): _scoped does not exist yet, so the
    // memoized dispose is a no-op — it must not become permanent.
    await host.dispose();

    // A later register() on the same host (embedded-host lifecycle) must
    // NOT reseed the plaintext overlay for an already-disposed host.
    host.register(
      PluginContext(
        env: MemoryExecutionEnv(cwd: home.path),
        io: _IO(),
        readSessionRecords: (type) async => [
          _membership('private', pub: 'pub', priv: 'priv').toJson(),
        ],
      ),
    );
    await _waitUntil(() async => plugin.startCalls > 0);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final overlay = File('${home.path}/.dap/runtime/channels.json');
    expect(await overlay.exists(), isFalse);

    // The early no-op dispose must have re-armed: a later dispose runs
    // the real cleanup path and completes without throwing.
    await host.dispose();
    expect(await overlay.exists(), isFalse);
  });

  test('the public/private decision comes from the STORED shape: an '
      'undecryptable private envelope is still PRIVATE, and the missing '
      'key is reported for a loud send refusal (gh-1888 review)', () async {
    final environment = <String, String>{
      // NOTE: no DAP_KEY_PASSPHRASE — the envelope cannot be opened.
      'DAP_HUB_URL': _hubUrl,
    };
    final client = hub.HubClient(
      config: const hub.HubConfig(url: _hubUrl),
      identity: await hub.HubIdentity.generate(),
    )..agentId = _selfId;
    final plugin = _StubHubPlugin(
      environment: environment,
      home: home.path,
      currentStatus: _connectedStatus,
      memoryRepository: _MemoryHubRepository(client),
    );
    final host = HubPluginHost(
      plugin,
      environment: environment,
      home: home.path,
      localHubUrl: _hubUrl,
      hubHealthProbe: (port) async => false,
      hubSpawner: (port) async {},
    );
    final context = PluginContext(
      env: MemoryExecutionEnv(cwd: home.path),
      io: _IO(),
      readSessionRecords: (type) async => [
        _membership('locked', pub: 'pub', priv: 'dapkey1.undecodable').toJson(),
        _membership('open').toJson(),
      ],
    );
    host.register(context);

    // Even though runtimeEffective() yields priv == null for 'locked',
    // it is NOT public: pub != null at rest means private.
    expect(await HubPluginHost.publicChannelFor(plugin, 'locked'), isFalse);
    expect(await HubPluginHost.publicChannelFor(plugin, 'open'), isTrue);
    expect(
      await HubPluginHost.privateChannelKeyMissing(plugin, 'locked'),
      isTrue,
    );
    expect(
      await HubPluginHost.privateChannelKeyMissing(plugin, 'open'),
      isFalse,
    );
    expect(
      await HubPluginHost.privateChannelKeyMissing(plugin, 'missing'),
      isFalse,
    );
  });

  test(
    'private key lookup fails closed when the membership store errors',
    () async {
      final environment = <String, String>{'DAP_HUB_URL': _hubUrl};
      await Directory('${home.path}/.dap').create(recursive: true);
      await File(
        '${home.path}/.dap/config.json',
      ).writeAsString('{"channels":"not-a-list"}');
      final client = hub.HubClient(
        config: const hub.HubConfig(url: _hubUrl),
        identity: await hub.HubIdentity.generate(),
      )..agentId = _selfId;
      final plugin = _StubHubPlugin(
        environment: environment,
        home: home.path,
        currentStatus: _connectedStatus,
        memoryRepository: _MemoryHubRepository(client),
      );
      final host = HubPluginHost(
        plugin,
        environment: environment,
        home: home.path,
        localHubUrl: _hubUrl,
        hubHealthProbe: (port) async => false,
        hubSpawner: (port) async {},
      );
      host.register(
        PluginContext(
          env: MemoryExecutionEnv(cwd: home.path),
          io: _IO(),
        ),
      );

      // A store error means the key cannot be proven available. Returning
      // false here would let sendChannelFanet1 auto-generate an unreadable
      // keypair; true makes the fabric refuse before any wire write.
      expect(
        await HubPluginHost.privateChannelKeyMissing(plugin, 'unknown'),
        isTrue,
      );
    },
  );

  test(
    'AC8/AC14: the DAP env secrets AND runtime-resolved in-memory keys '
    'are registered with both masking systems at plugin register time',
    () async {
      const envPriv = 'ENV_CHANNEL_PRIV_0123456789abcdef';
      const envPassphrase = 'env-passphrase-0123456789';
      const runtimePriv = 'runtime-decrypted-priv-0123456789abcdef';
      final environment = <String, String>{
        'DAP_HUB_URL': _hubUrl,
        'DAP_CHANNELS_JSON': '[{"channel":"env","pub":"P","priv":"$envPriv"}]',
        'DAP_KEY_PASSPHRASE': envPassphrase,
      };
      final client = hub.HubClient(
        config: const hub.HubConfig(url: _hubUrl),
        identity: await hub.HubIdentity.generate(),
      )..agentId = _selfId;
      final plugin = _StubHubPlugin(
        environment: environment,
        home: home.path,
        currentStatus: _connectedStatus,
        memoryRepository: _MemoryHubRepository(client),
      );
      final redactor = SecretRedactor();
      final pipeline = buildRedactionPipeline(null);
      final host = HubPluginHost(
        plugin,
        environment: environment,
        home: home.path,
        localHubUrl: _hubUrl,
        hubHealthProbe: (port) async => false,
        hubSpawner: (port) async {},
        secretRedactor: redactor,
        redactionPipeline: pipeline,
      );
      host.register(
        PluginContext(
          env: MemoryExecutionEnv(cwd: home.path),
          io: _IO(),
          readSessionRecords: (type) async => [
            _membership('runtime', pub: 'pub', priv: runtimePriv).toJson(),
          ],
        ),
      );

      // 1. The env values never survive an `env`-dump-style tool result.
      final dump = environment.entries
          .map((e) => '${e.key}=${e.value}')
          .join('\n');
      final redacted = redactor.redact(dump);
      expect(redacted, isNot(contains(envPriv)));
      expect(redacted, isNot(contains(envPassphrase)));
      expect(redacted, contains('DAP_HUB_URL=$_hubUrl'));

      // 2. The layered pipeline carries the same env values.
      expect(
        pipeline!.registeredSecrets,
        contains(environment['DAP_CHANNELS_JSON']),
      );

      // 3. A plaintext key resolved into memory at runtime (session
      // record pass-through) is masked too — this is what the AC8
      // byte-scan covers end to end.
      await HubPluginHost.publicChannelFor(plugin, 'runtime');
      final transcript = redactor.redact('the key is $runtimePriv ok?');
      expect(transcript, isNot(contains(runtimePriv)));
    },
  );

  test(
    'status and menu connect preserve output and default prompt semantics',
    () async {
      final questions = <String>[];
      var menuChoice = 'connect';
      final fixture = await _fixture(
        home,
        pick: (title, options, {initialKey}) async => menuChoice,
        ask: (question, {secret = false}) async {
          questions.add(question);
          return '';
        },
      );

      await fixture.context.slashCommands['/dap']!([]);

      expect(fixture.plugin.connectCalls.single.host, _hubUrl);
      expect(fixture.plugin.connectCalls.single.name, isNull);
      expect(fixture.plugin.connectCalls.single.channel, isNull);
      expect(questions.first, contains('empty = $_hubUrl'));
      expect(fixture.io.text, contains('connected to $_hubUrl as $_selfId'));

      fixture.io.lines.clear();
      fixture.plugin.currentStatus = const hub.HubStatus(
        connected: false,
        agentId: null,
        name: null,
        url: _hubUrl,
        channels: [],
        welcomes: 0,
        hellos: 1,
      );
      menuChoice = 'status';
      await fixture.context.slashCommands['/dap']!([]);
      expect(fixture.io.text, contains('hub disconnected — $_hubUrl'));
      expect(fixture.io.text, contains('Run /dap start'));

      fixture.io.lines.clear();
      await fixture.context.slashCommands['/dap']!(['unexpected-host']);
      expect(fixture.plugin.connectCalls.last.host, 'unexpected-host');
    },
  );

  test('headless connected status includes identity, name, and url', () async {
    final fixture = await _fixture(home);
    await fixture.context.slashCommands['/dap']!([]);
    expect(fixture.io.text, contains('hub connected'));
    expect(fixture.io.text, contains('agentId: $_selfId'));
    expect(fixture.io.text, contains('name: self'));
    expect(fixture.io.text, contains('url: $_hubUrl'));
  });

  test(
    'dap_dm resolves exact ids and unique names, and diagnoses bad names',
    () async {
      final peers = [
        hub.AgentInfo(agentId: 'id-alice', name: 'alice', online: true),
        hub.AgentInfo(agentId: 'id-exact', name: 'twin', online: true),
        hub.AgentInfo(agentId: 'id-twin-2', name: 'twin', online: false),
      ];
      final fixture = await _fixture(home, peers: peers);
      final dm = fixture.tool('dap_dm');

      final byName = await dm.execute(
        {'to': 'alice', 'text': 'hello alice'},
        null,
        null,
      );
      expect(fixture.repository.sent.single.toId, 'id-alice');
      expect((byName.content.single as TextContent).text, contains('id-alice'));

      await dm.execute({'to': 'id-exact', 'text': 'hello exact'}, null, null);
      expect(fixture.repository.sent.last.toId, 'id-exact');

      await expectLater(
        () => dm.execute({'to': 'twin', 'text': 'ambiguous'}, null, null),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains('ambiguous'), contains('(offline)')),
          ),
        ),
      );
      await expectLater(
        () => dm.execute({'to': 'nobody', 'text': 'missing'}, null, null),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('no online peer matches "nobody"'),
          ),
        ),
      );
      expect(fixture.repository.sent, hasLength(2));
    },
  );

  test(
    'pending probes do not drain direct or channel mail; drain maps and filters',
    () async {
      final fixture = await _fixture(home, memberships: [_membership('room')]);
      final inbox = fixture.hubInbox;
      final pending = inbox.hasPending!;

      expect(await pending(), isFalse);
      fixture.repository.add(
        _mail('dm-1', _selfId, text: 'direct hello', hops: 4),
      );
      expect(await pending(), isTrue);
      expect(await pending(), isTrue, reason: 'peek is non-draining');
      final direct = await inbox.drain();
      expect(direct.single.id, 'dm-1');
      expect(direct.single.text, 'direct hello');
      expect(direct.single.hops, 4);
      expect(await pending(), isFalse);

      fixture.repository.add(
        _mail('channel-1', '#room', text: 'channel hello'),
      );
      expect(await pending(), isTrue);
      expect(await pending(), isTrue, reason: 'channel peek is non-draining');
      final channel = await inbox.drain();
      expect(channel.single.id, 'channel-1');
      expect(channel.single.toId, '#room');
      expect(await pending(), isFalse);

      fixture.repository.add(
        _mail('own-channel', '#room', fromId: _selfId, text: 'own echo'),
      );
      expect(await pending(), isTrue);
      expect(
        await inbox.drain(),
        isEmpty,
        reason: 'own channel echoes are filtered',
      );
      expect(await pending(), isFalse);
    },
  );
}
