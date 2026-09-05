// Pure-Dart tests for the SW wiring pieces that need no chrome global
// (issue #30 v2): the originOf seed helper (exfil-gate visited set), the
// UiHostAdapter settings/passthrough logic, and one end-to-end protocol
// smoke — UiPortServer over the adapter with a fake backend + channel.
// The js_interop layers (agent_main, chrome_api_js) are gated by
// `dart compile js agent_main.dart`, never by these tests.
import 'dart:async';

import 'package:test/test.dart';

import '../src/security/exfil_gate.dart';
import '../src/ui_host_adapter.dart';
import '../src/ui_port_server.dart';
import '../src/ui_protocol.dart';
import '../src/ui_transport.dart';

void main() {
  group('originOf (visited-set seeding)', () {
    test('http(s) origins normalize to scheme://host[:port]', () {
      expect(
        originOf('https://example.com/a/b?q=1#frag'),
        'https://example.com',
      );
      expect(originOf('http://localhost:8080/x'), 'http://localhost:8080');
    });

    test('chrome:// and chrome-extension:// keep their scheme://host form', () {
      // The gate compares seeds against outboundOrigin output — the exact
      // same string a tabs_open to a settings page computes later.
      expect(originOf('chrome://newtab/'), 'chrome://newtab');
      expect(
        originOf('chrome-extension://abc123/panel/panel.html'),
        'chrome-extension://abc123',
      );
    });

    test('origin-less and invalid urls are null', () {
      expect(originOf(null), isNull);
      expect(originOf(''), isNull);
      expect(originOf('data:text/html,<h1>x</h1>'), isNull);
      expect(originOf('about:blank'), isNull);
      expect(originOf('file:///etc/hosts'), isNull);
      expect(originOf('not a url'), isNull);
    });
  });

  group('UiHostAdapter settings mapping', () {
    late UiHostAdapter adapter;
    final persisted = <String, Object?>{};
    var applied = 0;

    setUp(() {
      persisted.clear();
      applied = 0;
      adapter = UiHostAdapter(
        backend: () => null,
        onSettings: (_) => applied++,
        persist: (key, value) async => persisted[key] = value,
      );
    });

    test('seed merges recognized stored keys only', () {
      adapter.seed({
        'faProvider': {'model': 'm1'},
        'faApproval': 'yolo',
        'unknownKey': 42,
      });
      expect(adapter.settingsGet(), {
        'faProvider': {'model': 'm1'},
        'faApproval': 'yolo',
      });
    });

    test('settings_put merges partial puts and persists per key', () {
      adapter.seed({
        'faProvider': {'model': 'm1', 'apiKey': 'k'},
        'faApproval': 'ask',
      });
      adapter.settingsPut({'faApproval': 'yolo', 'junk': true});

      // faProvider survives; junk never enters storage.
      expect(adapter.settingsGet()['faApproval'], 'yolo');
      expect((adapter.settingsGet()['faProvider'] as Map)['model'], 'm1');
      expect(adapter.settingsGet().containsKey('junk'), isFalse);
      expect(persisted, {'faApproval': 'yolo'});
      expect(applied, 1);
    });

    test('unknown-only put changes nothing', () {
      adapter.seed({'faApproval': 'ask'});
      adapter.settingsPut({'junk': true});
      expect(persisted, isEmpty);
      expect(applied, 0);
      expect(adapter.settingsGet(), {'faApproval': 'ask'});
    });

    test('persist failures never break the in-memory snapshot', () async {
      final adapter = UiHostAdapter(
        backend: () => null,
        onSettings: (_) {},
        persist: (key, value) async => throw StateError('storage blocked'),
      );
      adapter.settingsPut({'faApproval': 'write'});
      await Future<void>.delayed(Duration.zero); // let the sink reject
      expect(adapter.settingsGet(), {'faApproval': 'write'});
    });
  });

  group('UiHostAdapter host pass-through', () {
    test('resolves the backend lazily and survives a null host', () {
      final backend = _FakeBackend();
      var live = true;
      final adapter = UiHostAdapter(
        backend: () => live ? backend : null,
        onSettings: (_) {},
      );

      adapter.sendUser('hi');
      adapter.cancelTurn();
      adapter.decide('ap-1', true);
      expect(backend.sent, ['hi']);
      expect(backend.cancelled, 1);
      expect(backend.decisions, [('ap-1', true)]);
      expect(adapter.state(), {'running': false, 'booted': true});
      expect(adapter.sessionId, 'sess-1');
      expect(adapter.sessionsList(), [
        {'id': 'sess-1', 'messages': 3, 'running': false},
      ]);

      // Pre-boot and mid-restart the adapter degrades, never throws.
      live = false;
      expect(adapter.state(), {'booted': false});
      expect(adapter.sessionId, '');
      expect(adapter.sessionsList(), isEmpty);
      adapter.sendUser('ignored');
      adapter.cancelTurn();
      adapter.decide('ap-2', false);
      expect(backend.sent, ['hi']);
    });
  });

  group('protocol smoke: UiPortServer over UiHostAdapter', () {
    test('hello, deduped prompt, cancel and settings flow', () async {
      final backend = _FakeBackend();
      final persisted = <String, Object?>{};
      final adapter = UiHostAdapter(
        backend: () => backend,
        onSettings: (_) {},
        persist: (key, value) async => persisted[key] = value,
      );
      adapter.seed({'faApproval': 'ask'});
      final server = UiPortServer(host: adapter, replayCap: 10);
      final channel = _FakeChannel();
      server.serve(channel);

      channel.receive(
        HelloMsg(
          protoVersion: uiProtocolVersion,
          capabilities: const ['stream'],
        ).encode(),
      );
      await Future<void>.delayed(Duration.zero);
      final helloAck = channel.message<HelloAckMsg>();
      expect(helloAck.sessionId, 'sess-1');
      expect(helloAck.serverCapabilities, contains('settings'));

      // Prompt id dedup: same id twice runs once.
      channel.receive(const PromptMsg(id: 'p1', text: 'do it').encode());
      channel.receive(const PromptMsg(id: 'p1', text: 'do it').encode());
      channel.receive(const SteerMsg(text: 'and this').encode());
      channel.receive(const CancelMsg().encode());
      await Future<void>.delayed(Duration.zero);
      expect(backend.sent, ['do it', 'and this']);
      expect(backend.cancelled, 1);

      channel.receive(
        const SettingsPutMsg(
          settings: {
            'faApproval': 'yolo',
            'faDap': {'url': 'wss://hub'},
          },
        ).encode(),
      );
      await Future<void>.delayed(Duration.zero);
      final settings = channel.message<SettingsResultMsg>().settings;
      expect(settings['faApproval'], 'yolo');
      expect(persisted['faApproval'], 'yolo');
      expect(persisted.containsKey('faDap'), isTrue);

      // Host events fan out to the channel as stream envelopes.
      server.onHostEvent({'type': 'delta', 'text': 'partial'});
      await Future<void>.delayed(Duration.zero);
      final stream = channel.message<StreamMsg>();
      expect(stream.event, {'type': 'delta', 'text': 'partial'});
    });
  });
}

final class _FakeBackend implements UiHostBackend {
  final sent = <String>[];
  final decisions = <(String, bool)>[];
  var cancelled = 0;

  @override
  void sendUser(String text) => sent.add(text);

  @override
  void cancelTurn() => cancelled++;

  @override
  void decide(String id, bool allow) => decisions.add((id, allow));

  @override
  Map<String, dynamic> getState() => {'running': false, 'booted': true};

  @override
  String get sessionId => 'sess-1';

  @override
  List<Map<String, dynamic>> sessionsList() => [
    {'id': 'sess-1', 'messages': 3, 'running': false},
  ];
}

final class _FakeChannel implements UiPortChannel {
  final _sent = <Map<String, dynamic>>[];
  final _inbound = StreamController<Map<String, dynamic>>.broadcast();
  var _closed = false;

  void receive(Map<String, dynamic> json) => _inbound.add(json);

  /// First decoded message of [T] kind the server put on the wire.
  T message<T extends UiProtocolMessage>() {
    for (final json in _sent) {
      final decoded = UiProtocolMessage.decode(json);
      if (decoded is T) return decoded;
    }
    throw StateError('no $T message on the wire');
  }

  @override
  void send(Map<String, dynamic> json) => _sent.add(json);

  @override
  Stream<Map<String, dynamic>> get onMessage => _inbound.stream;

  @override
  void close() => _closed = true;

  @override
  bool get isClosed => _closed;
}
