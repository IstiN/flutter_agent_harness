// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The host-session stream decorator tests (gh-2391): the quota terminal
/// notice, the one-shot 401 bridge re-resolution, and the sign-in card on
/// persistent failure. Pure stream plumbing — no agent loop involved.
library;

import 'package:fa/boot/host_connection_resolver.dart';
import 'package:fa/boot/host_session_bridge.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

const _quotaSection = {
  'status': 429,
  'errorCode': 'limit_reached',
  'url': 'https://app.example/allowance',
};

HostSessionState _state({required String bridgedKey}) {
  final connection = HostConnectionConfig.fromJson(
    {
      'baseUrl': 'https://api.ain.example/v1',
      'sessionBridge': {'storage': 'localStorage', 'key': 'ain_session'},
      'defaultModel': 'ain/ain_flash',
      'quota': _quotaSection,
    },
    apiEndpoint: Uri.parse('https://api.ain.example/v1'),
    displayName: () => 'AIN',
  );
  return HostSessionState(
    provider: const CustomProvider(
      id: 'host',
      name: 'AIN',
      baseUrl: 'https://api.ain.example/v1',
      modelId: 'ain/ain_flash',
      provenance: 'host',
      kind: 'host-session',
    ),
    bridgedKey: bridgedKey,
    connection: connection,
  );
}

/// A scripted stream: one ErrorEvent with [errorText], then end.
StreamFunction _errorStream(String errorText, {int invocations = 0}) {
  return (model, context, {cancelToken}) {
    invocations++;
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: const [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.error,
      errorMessage: errorText,
      timestamp: DateTime.now(),
    );
    stream.push(ErrorEvent(reason: StopReason.error, error: message));
    stream.end();
    return stream;
  };
}

Model get _model => Model(
  id: 'ain/ain_flash',
  name: 'ain',
  api: 'openai-completions',
  provider: 'openai-completions',
  baseUrl: 'https://api.ain.example/v1',
  contextWindow: 100000,
  maxTokens: 4096,
);

Future<List<Object>> _collect(StreamFunction fn) async {
  final events = <Object>[];
  await for (final event in fn(_model, Context(messages: const []))) {
    events.add(event);
  }
  return events;
}

void main() {
  tearDown(() => HostSessionHandle.instance.uninstall());

  group('decorateHostSession (gh-2391)', () {
    test('a quota-shaped error becomes the terminal marker with the '
        'profile link', () async {
      final registry = ProviderRegistry.inMemory();
      final bridge = _Bridge({'ain_session': 'k1'});
      HostSessionHandle.instance.install(
        _state(bridgedKey: 'k1'),
        registry: registry,
        bridge: bridge,
      );
      final events = await _collect(
        decorateHostSession(
          _errorStream(
            '429: {"error":{"code":"limit_reached","message":"out"}}',
          ),
          AgentConfig(
            providerKind: 'openai-completions',
            modelId: 'ain/ain_flash',
            baseUrl: 'https://api.ain.example/v1',
            apiKey: 'k1',
          ),
        ),
      );
      expect(events, hasLength(1));
      final error = events.single as ErrorEvent;
      expect(
        error.error.errorMessage,
        '[[host-quota:https://app.example/allowance]]',
      );
    });

    test('the same status with a different error code passes through '
        '(the normal failure path)', () async {
      HostSessionHandle.instance.install(
        _state(bridgedKey: 'k1'),
        registry: ProviderRegistry.inMemory(),
        bridge: _Bridge({'ain_session': 'k1'}),
      );
      final events = await _collect(
        decorateHostSession(
          _errorStream('429: {"error":{"code":"server_busy"}}'),
          AgentConfig(
            providerKind: 'openai-completions',
            modelId: 'ain/ain_flash',
            baseUrl: 'https://api.ain.example/v1',
            apiKey: 'k1',
          ),
        ),
      );
      expect(events, hasLength(1));
      expect(
        (events.single as ErrorEvent).error.errorMessage,
        '429: {"error":{"code":"server_busy"}}',
      );
    });

    test('a 401 with a rotated bridge key re-resolves once and retries '
        'transparently', () async {
      final registry = ProviderRegistry.inMemory();
      final host = await registry.upsert(
        const CustomProvider(
          id: 'host',
          name: 'AIN',
          baseUrl: 'https://api.ain.example/v1',
          modelId: 'ain/ain_flash',
          provenance: 'host',
          kind: 'host-session',
        ),
      );
      registry.rememberSessionKey('host', 'k1');
      final bridge = _Bridge({'ain_session': 'k2'});
      HostSessionHandle.instance.install(
        _state(bridgedKey: 'k1'),
        registry: registry,
        bridge: bridge,
      );
      var attempts = 0;
      final rebuiltKeys = <String>[];
      final events = await _collect(
        decorateHostSession(
          _errorStream('401: unauthorized'),
          AgentConfig(
            providerKind: 'openai-completions',
            modelId: 'ain/ain_flash',
            baseUrl: 'https://api.ain.example/v1',
            apiKey: 'k1',
          ),
          rebuildWithKey: (freshKey) {
            rebuiltKeys.add(freshKey);
            attempts++;
            // The second attempt succeeds (the fresh key works).
            return (model, context, {cancelToken}) {
              final stream = AssistantMessageEventStream();
              stream.push(
                DoneEvent(
                  reason: StopReason.stop,
                  message: AssistantMessage(
                    content: [TextContent(text: 'ok')],
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    usage: Usage.zero,
                    stopReason: StopReason.stop,
                    timestamp: DateTime.now(),
                  ),
                ),
              );
              stream.end();
              return stream;
            };
          },
        ),
      );
      expect(rebuiltKeys, ['k2']);
      expect(registry.keyFor('host'), 'k2');
      expect(
        events.whereType<ErrorEvent>(),
        isEmpty,
        reason: 'the transparent retry never surfaces the 401',
      );
      expect(events, hasLength(1));
    });

    test('a 401 with an unchanged bridge surfaces the host sign-in card '
        'exactly once', () async {
      final registry = ProviderRegistry.inMemory();
      HostSessionHandle.instance.install(
        _state(bridgedKey: 'k1'),
        registry: registry,
        bridge: _Bridge({'ain_session': 'k1'}),
      );
      var rebuilt = 0;
      final events = await _collect(
        decorateHostSession(
          _errorStream('401: unauthorized'),
          AgentConfig(
            providerKind: 'openai-completions',
            modelId: 'ain/ain_flash',
            baseUrl: 'https://api.ain.example/v1',
            apiKey: 'k1',
          ),
          rebuildWithKey: (_) {
            rebuilt++;
            return _errorStream('401: unauthorized');
          },
        ),
      );
      expect(rebuilt, 0, reason: 'no fresh key — no retry');
      expect(events, hasLength(1));
      expect(
        (events.single as ErrorEvent).error.errorMessage,
        '[[auth-expired: host]]',
      );
    });

    test(
      'non-host connections are untouched (no quota match, no re-read)',
      () async {
        // No handle installed at all: the decorator passes everything through.
        final events = await _collect(
          decorateHostSession(
            _errorStream('429: {"error":{"code":"limit_reached"}}'),
            AgentConfig(
              providerKind: 'openai-completions',
              modelId: 'm',
              baseUrl: 'https://other.example/v1',
              apiKey: '',
            ),
          ),
        );
        expect(events, hasLength(1));
        expect(
          (events.single as ErrorEvent).error.errorMessage,
          '429: {"error":{"code":"limit_reached"}}',
        );
      },
    );
  });

  group('HostSessionHandle.reResolveKey (gh-2391)', () {
    test(
      'a fresh key updates the registry and the state, returns true',
      () async {
        final registry = ProviderRegistry.inMemory();
        final host = await registry.upsert(
          const CustomProvider(
            id: 'host',
            name: 'AIN',
            baseUrl: 'https://api.ain.example/v1',
            modelId: 'ain/ain_flash',
            provenance: 'host',
            kind: 'host-session',
          ),
        );
        registry.rememberSessionKey('host', 'old');
        HostSessionHandle.instance.install(
          _state(bridgedKey: 'old'),
          registry: registry,
          bridge: _Bridge({'ain_session': 'new'}),
        );
        expect(HostSessionHandle.instance.reResolveKey(), isTrue);
        expect(registry.keyFor('host'), 'new');
        expect(HostSessionHandle.instance.state!.bridgedKey, 'new');
      },
    );

    test('an unchanged or empty bridge returns false', () async {
      HostSessionHandle.instance.install(
        _state(bridgedKey: 'k1'),
        registry: ProviderRegistry.inMemory(),
        bridge: _Bridge({'ain_session': 'k1'}),
      );
      expect(HostSessionHandle.instance.reResolveKey(), isFalse);
      HostSessionHandle.instance.install(
        _state(bridgedKey: 'k1'),
        registry: ProviderRegistry.inMemory(),
        bridge: const _Bridge({}),
      );
      expect(HostSessionHandle.instance.reResolveKey(), isFalse);
    });
  });
}

final class _Bridge implements HostSessionBridge {
  const _Bridge(this.values);
  final Map<String, String> values;

  @override
  String? read(String key) => values[key];
}
