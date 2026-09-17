// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Unit tests for the boot module stages (issue #483): window, services,
/// storage, telemetry, the chat-analytics route table, the extension-relay
/// boot, and the restorable-config round-trip. No plugin channels — the
/// env is injected ([MemoryExecutionEnv]).
library;

import 'dart:async';

import 'package:fa/main.dart';
import 'package:fa/boot/app_boot.dart';
import 'package:fa/boot/boot_config_codec.dart';
import 'package:fa/gemma/gemma_types.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/relay_agent_service.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/transformers_js/transformers_js_types.dart';
import 'package:fa/webllm/webllm_types.dart';
import 'package:fa_browser_agent/fa_browser_agent.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory `UiPortChannel` (same pattern as relay_agent_service_test):
/// records what the UI sends and lets tests inject SW→UI envelopes.
final class FakePortChannel implements UiPortChannel {
  final _inbound = StreamController<Map<String, dynamic>>.broadcast();
  final sent = <Map<String, dynamic>>[];

  @override
  void send(Map<String, dynamic> json) => sent.add(json);

  @override
  Stream<Map<String, dynamic>> get onMessage => _inbound.stream;

  /// SW → UI: encode and deliver one protocol envelope.
  void fromWorker(UiProtocolMessage message) => _inbound.add(message.encode());

  /// The recorded UI → SW envelope of [kind] (last one wins).
  Map<String, dynamic>? sentOf(String kind) {
    for (final json in sent.reversed) {
      if (json['kind'] == kind) return json;
    }
    return null;
  }

  @override
  void close() {
    if (!_inbound.isClosed) _inbound.close();
  }

  @override
  bool get isClosed => _inbound.isClosed;
}

/// Pumps microtasks until the channel records a [kind] send (or gives up).
Future<void> _pumpUntilSent(FakePortChannel channel, String kind) async {
  for (var i = 0; i < 200 && channel.sentOf(kind) == null; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// `true` when the widgets binding is initialized. The `.instance` getter
/// throws [FlutterError] when it is not, so probe through try/catch.
bool _flutterBindingInitialized() {
  try {
    WidgetsBinding.instance;
    return true;
  } on FlutterError {
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('bootWindow (window stage)', () {
    test('installs the transport, inbox watcher, and debug tee', () {
      final originalDebugPrint = debugPrint;
      addTearDown(() => debugPrint = originalDebugPrint);
      bootWindow();
      expect(AgentService.enableInboxWatcher, isTrue);
      expect(providerHttpClientFactory, isNotNull);
      expect(identical(debugPrint, originalDebugPrint), isFalse);
    });
  });

  group('bootServices (services stage)', () {
    test('resolves the provider filter without plugin channels', () async {
      await bootServices();
      // No .env loaded under the test runner: the override stays unset.
      expect(providerFilterEnvOverride, isNull);
    });
  });

  group('loadBootStores (storage stage, injected env)', () {
    test('loads every store over a memory env', () async {
      final env = MemoryExecutionEnv();
      final stores = await loadBootStores(env);
      addTearDown(() => FaUiHost.keyResolver = null);
      expect(stores.env, same(env));
      expect(stores.sessionKeys, isA<SessionKeysStore>());
      expect(stores.registry, isA<ProviderRegistry>());
      expect(stores.lastConnection, isA<LastConnectionStore>());
      expect(stores.themeController, isNotNull);
      expect(stores.onboarding, isNotNull);
      expect(stores.themePacks, isNotNull);
      expect(stores.skillsAccess, isNotNull);
      expect(stores.mediaModels, isNotNull);
      expect(stores.taskModels, isNotNull);
      expect(stores.onDeviceConfig, isNotNull);
      expect(stores.imagePreviews, isNotNull);
      // The fa_ui key chain is wired to the app resolver.
      expect(FaUiHost.keyResolver, isNotNull);
    });
  });

  group('bootTelemetry (telemetry stage)', () {
    test(
      'installs the chat-analytics route and degrades without Firebase',
      () async {
        addTearDown(() => FaChatHost.analytics = null);
        final analytics = await bootTelemetry();
        expect(analytics, isNull); // VM test runner: no Firebase.
        expect(FaChatHost.analytics, same(routeFaChatAnalytics));
      },
    );
  });

  group('routeFaChatAnalytics (chat-event route table)', () {
    final events = <MapEntry<String, Map<String, Object>>>[];
    setUp(() {
      events.clear();
      AppAnalytics.install(
        (name, params) => events.add(MapEntry(name, params)),
      );
    });
    tearDown(() => AppAnalytics.install(null));

    test('routes every tabled event to the analytics facade', () {
      routeFaChatAnalytics('approval_mode_changed', {'mode': 'yolo'});
      routeFaChatAnalytics('secret_request', {'result': 'granted'});
      routeFaChatAnalytics('message_sent', {
        'has_attachments': true,
        'text_length': 7,
      });
      routeFaChatAnalytics('upload_added', {'count': 2});
      routeFaChatAnalytics('voice_input_used');
      routeFaChatAnalytics('screen_opened', {'screen_name': 'settings'});
      routeFaChatAnalytics('files_opened', {'source': 'composer'});
      routeFaChatAnalytics('settings_opened');
      expect(events.map((e) => e.key).toList(), [
        'approval_mode_changed',
        'secret_request',
        'message_sent',
        'upload_added',
        'voice_input_used',
        'screen_opened',
        'files_opened',
        'settings_opened',
      ]);
      // The facade normalizes at the boundary: raw text length becomes a
      // coarse bucket before it reaches the sink.
      expect(events[2].value, {
        'has_attachments': true,
        'length_bucket': '<=50',
      });
      expect(events[5].value, {'screen_name': 'settings'});
    });

    test('unknown events are ignored', () {
      routeFaChatAnalytics('no_such_event', {'x': 1});
      expect(events, isEmpty);
    });
  });

  group('bootExtensionRelay (extension-panel boot)', () {
    test('null relay funnels into onError', () async {
      final errors = <String>[];
      var reachedHome = false;
      await bootExtensionRelay(
        env: MemoryExecutionEnv(),
        createRelay: () async => null,
        onHome: (_, _) async => reachedHome = true,
        onError: errors.add,
      );
      expect(reachedHome, isFalse);
      expect(errors, ['extension service worker not reachable']);
    });

    test('a throwing createRelay funnels its error into onError', () async {
      final errors = <String>[];
      await bootExtensionRelay(
        env: MemoryExecutionEnv(),
        createRelay: () async => throw StateError('sw dead'),
        onHome: (_, _) async {},
        onError: errors.add,
      );
      expect(errors.single, contains('sw dead'));
    });

    test(
      'attaches the relay, converges the live session, reaches home',
      () async {
        final channel = FakePortChannel();
        final relay = RelayAgentService.forTest(
          WorkerRelayTransport(portFactory: () => channel, channel: channel),
        );
        // Complete the handshake BEFORE boot, like RelayAgentService.create
        // (it awaits attach) would have: the converge-once branch must run.
        await _pumpUntilSent(channel, 'hello');
        channel.fromWorker(
          HelloAckMsg(
            protoVersion: uiProtocolVersion,
            serverCapabilities: const ['stream'],
            sessionId: 'sw-9',
          ),
        );
        await _pumpUntilSent(channel, 'attach');
        channel.fromWorker(AttachedMsg(sessionId: 'sw-9', replay: const []));
        await _pumpUntilSent(channel, 'ping');

        FlutterSessionManager? homeManager;
        ProviderRegistry? homeRegistry;
        final errors = <String>[];
        await bootExtensionRelay(
          env: MemoryExecutionEnv(),
          createRelay: () async => relay,
          onHome: (manager, registry) async {
            homeManager = manager;
            homeRegistry = registry;
          },
          onError: errors.add,
        );
        expect(errors, isEmpty);
        expect(homeManager, isNotNull);
        expect(homeRegistry, isNotNull);
        // Converge-once: the attach-time session id is authoritative.
        expect(homeManager!.hostedLiveId.value, 'sw-9');
        // The adoption callback re-keys on later attach broadcasts.
        relay.onLiveSessionIdChanged!('sw-10');
        expect(homeManager!.hostedLiveId.value, 'sw-10');
      },
    );
  });

  group('seedRelaySwProvider (SW provider seeding)', () {
    test('no-op when the SW has no active provider', () async {
      final registry = ProviderRegistry.inMemory();
      await seedRelaySwProvider(registry, null);
      expect(registry.providers, isEmpty);
    });

    test(
      'adds an unknown provider and remembers the key session-only',
      () async {
        final registry = ProviderRegistry.inMemory();
        await seedRelaySwProvider(registry, {
          'baseUrl': 'https://api.example.com/v1',
          'model': 'm-1',
          'apiKey': 'k-9',
        });
        expect(registry.providers, hasLength(1));
        expect(registry.providers.single.baseUrl, 'https://api.example.com/v1');
        expect(registry.providers.single.name, 'api.example.com');
        expect(registry.keyFor(registry.providers.single.id), 'k-9');
      },
    );

    test('skips a base URL the registry already knows', () async {
      final registry = ProviderRegistry.inMemory();
      final sw = {
        'baseUrl': 'https://api.example.com/v1',
        'model': 'm-1',
        'apiKey': 'k-9',
      };
      await seedRelaySwProvider(registry, sw);
      await seedRelaySwProvider(registry, sw);
      expect(registry.providers, hasLength(1));
    });
  });

  group('restorableBootConfig round-trip (config codec)', () {
    test(
      'every hosted catalog entry round-trips through its registry row',
      () async {
        for (final spec in providerCatalog.values) {
          final registry = ProviderRegistry.inMemory();
          final provider = await registry.add(
            name: spec.name,
            baseUrl: spec.defaultBaseUrl,
            modelId: 'test-model',
          );
          registry.rememberKey(provider.id, 'k-${spec.name}');
          final connection = LastConnection.fromConfig(
            AgentConfig(
              providerKind: spec.kind,
              modelId: 'test-model',
              baseUrl: spec.defaultBaseUrl,
              apiKey: 'k-${spec.name}',
              supportsImages: false,
            ),
          );
          final restored = restorableBootConfig(
            connection: connection,
            registry: registry,
            sessionKeysStore: SessionKeysStore.inMemory(),
          );
          expect(restored, isNotNull, reason: '${spec.name} (${spec.kind})');
          expect(restored!.providerKind, spec.kind, reason: spec.name);
          expect(restored.modelId, 'test-model', reason: spec.name);
          expect(restored.baseUrl, spec.defaultBaseUrl, reason: spec.name);
          expect(restored.apiKey, 'k-${spec.name}', reason: spec.name);
        }
      },
    );

    test('on-device connections never restore (quick start re-offers)', () {
      for (final kind in [
        webLlmProviderKind,
        gemmaProviderKind,
        transformersJsProviderKind,
      ]) {
        expect(
          restorableBootConfig(
            connection: LastConnection(
              providerKind: kind,
              modelId: 'preset-1',
              baseUrl: 'http://localhost:8080',
            ),
            registry: null,
            sessionKeysStore: null,
          ),
          isNull,
          reason: kind,
        );
      }
    });
  });
  group('FaAppBoot pipeline', () {
    tearDown(() => FaUiHost.keyResolver = null);

    test('runWithEnv drives every stage over the injected env', () async {
      final env = MemoryExecutionEnv();
      final routes = <BootStores>[];
      await FaAppBoot(
        routes: (stores, analytics) async {
          routes.add(stores);
        },
      ).runWithEnv(env);
      expect(routes, hasLength(1));
      expect(routes.single.env, same(env));
    });

    test(
      'run() creates the platform env only after the window stage (#544)',
      () async {
        // TestFlight build 160 white-screened because run() awaited
        // createPlatformEnv() BEFORE bootWindow(): path_provider channels and
        // the wasm_run FFI the sandbox shell compiles through ran without the
        // binding. Pin the order — the env factory must observe an
        // initialized binding, i.e. the window+services stages already ran.
        var bindingAtEnvCreation = true;
        final env = MemoryExecutionEnv();
        final routes = <BootStores>[];
        await FaAppBoot(
          routes: (stores, analytics) async {
            routes.add(stores);
          },
          createEnv: () async {
            bindingAtEnvCreation = _flutterBindingInitialized();
            return env;
          },
        ).run();
        expect(
          bindingAtEnvCreation,
          isTrue,
          reason:
              'createPlatformEnv uses plugin channels — the binding and '
              'the wasm runtime must be up before it runs (white screen '
              'on TestFlight build 160)',
        );
        expect(routes, hasLength(1));
        expect(routes.single.env, same(env));
      },
    );
  });
}
