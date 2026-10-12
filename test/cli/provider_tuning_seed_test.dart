// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/src/cli/custom_providers.dart';
import 'package:flutter_agent_harness/src/cli/provider_tuning_seed.dart';
import 'package:flutter_agent_harness/src/providers/provider_tuning.dart';
import 'package:test/test.dart';

CustomProviderEntry _entry({
  String name = 'glm-relay',
  Duration? connect,
  Duration? idle,
}) => CustomProviderEntry(
  name: name,
  apiType: 'openai',
  baseUrl: 'https://glm.test/v1',
  modelId: 'glm-5.3-flash',
  connectTimeout: connect,
  streamIdleTimeout: idle,
);

void main() {
  // The registry is a process global — every test starts from empty.
  setUp(() => seedProviderTuning(reset: true));
  tearDown(() => seedProviderTuning(reset: true));

  group('seedProviderTuning', () {
    test('a tuned entry registers and the boot notice names it with its '
        'endpoint and sources', () {
      seedProviderTuning(
        customProviders: [
          _entry(
            connect: const Duration(seconds: 2),
            idle: const Duration(milliseconds: 1500),
          ),
        ],
      );
      expect(providerTuningBootNotices(), [
        'provider tuning glm-relay (https://glm.test/v1): '
            'connect 2s (provider:glm-relay), idle 1.5s (provider:glm-relay)',
      ]);
    });

    test('per-field fallthrough: an entry declaring only connect leaves '
        'the idle leg at the built-in default', () {
      seedProviderTuning(
        customProviders: [_entry(connect: const Duration(seconds: 2))],
      );
      expect(
        providerTuningBootNotices().single,
        contains('connect 2s (provider:glm-relay), idle 300s (default)'),
      );
    });

    test('AC6 fast path: entries without overrides never reach the table', () {
      // Seed a valid entry BESIDE the no-override one: the one notice proves
      // the seeder ran AND that the no-override entry specifically was
      // dropped by the registry.
      seedProviderTuning(
        customProviders: [
          _entry(),
          _entry(name: 'tuned', connect: const Duration(seconds: 2)),
        ],
      );
      final notices = providerTuningBootNotices();
      expect(notices, hasLength(1));
      expect(notices.single, startsWith('provider tuning tuned ('));
    });

    test('E4: reset drops removed entries — a deleted config entry cannot '
        'outlive its config', () {
      // The realistic E4 shape: a config entry WITH tuning that is later
      // removed from the config.
      seedProviderTuning(
        customProviders: [_entry(connect: const Duration(seconds: 2))],
      );
      expect(providerTuningBootNotices(), hasLength(1));
      seedProviderTuning(reset: true);
      expect(providerTuningBootNotices(), isEmpty);
    });

    test('without reset the seeder ADDS (boot runs two passes)', () {
      seedProviderTuning(
        customProviders: [_entry(connect: const Duration(seconds: 2))],
      );
      seedProviderTuning(
        customProviders: [
          _entry(name: 'second', connect: const Duration(seconds: 3)),
        ],
      );
      expect(providerTuningBootNotices(), hasLength(2));
    });
  });

  group('resolution', () {
    test(
      'built-in defaults are 180s connect / 300s idle (source: default)',
      () {
        final resolved = resolveProviderTimeouts();
        expect(resolved.connect, const Duration(seconds: 180));
        expect(resolved.streamIdle, const Duration(seconds: 300));
        expect(resolved.connectSource, ProviderTimeoutSource.builtIn);
        expect(resolved.streamIdleSource, ProviderTimeoutSource.builtIn);
      },
    );

    test('the wire seam resolves per request URL under the entry base', () {
      seedProviderTuning(
        customProviders: [_entry(connect: const Duration(seconds: 2))],
      );
      final resolved = resolveProviderTimeouts(
        url: Uri.parse('https://glm.test/v1/chat/completions'),
      );
      expect(resolved.connect, const Duration(seconds: 2));
      expect(resolved.connectSource, ProviderTimeoutSource.providerEntry);
      expect(resolved.sourceName, 'glm-relay');
    });

    test('a request to an unrelated host keeps the defaults', () {
      seedProviderTuning(
        customProviders: [_entry(connect: const Duration(seconds: 2))],
      );
      final resolved = resolveProviderTimeouts(
        url: Uri.parse('https://other.test/v1/chat'),
      );
      expect(resolved.connect, const Duration(seconds: 180));
      expect(resolved.connectSource, ProviderTimeoutSource.builtIn);
    });
  });
}
