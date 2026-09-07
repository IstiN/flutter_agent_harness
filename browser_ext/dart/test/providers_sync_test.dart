// Providers registry merge/routing tests (issue #34 item 3): pure Dart.
//
// UT-S2 — re-pair overwrites synced entries but NEVER silently clobbers
// local edits. E26 — a keyless synced entry routes through the relay and
// a dead relay surfaces "desktop link is down" as a clean stream error.
library;

import 'dart:io';

import '../src/providers.dart';
import 'package:flutter_agent_harness/src/cancel_token.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/event_stream.dart';
import 'package:flutter_agent_harness/src/model.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

const synced = 'synced-from-cli@desk';

Map<String, dynamic> doc(
  List<Map<String, dynamic>> providers, {
  String mode = 'proxy',
}) => {'version': 1, 'mode': mode, 'host': 'desk', 'providers': providers};

Map<String, dynamic> entryJson(
  String name, {
  String provenance = synced,
  String apiKey = '',
  String modelId = 'gpt-x',
  String baseUrl = 'https://api/v1',
}) => {
  'name': name,
  'apiType': 'openai',
  'baseUrl': baseUrl,
  'modelId': modelId,
  'provenance': provenance,
  if (apiKey.isNotEmpty) 'apiKey': apiKey,
};

ProviderEntry entry(
  String name, {
  String provenance = synced,
  String apiKey = '',
  String modelId = 'gpt-x',
  String baseUrl = 'https://api/v1',
}) => (
  name: name,
  apiType: 'openai',
  baseUrl: baseUrl,
  modelId: modelId,
  provenance: provenance,
  apiKey: apiKey,
);

void main() {
  test('mergeSyncedProviders replaces synced entries and keeps local ones', () {
    final existing = doc([
      entryJson('cli-one'),
      entryJson('mine', provenance: localProvenance, apiKey: 'sk-local'),
    ]);
    final merged = mergeSyncedProviders(existing, {
      'version': 1,
      'mode': 'copy',
      'host': 'desk',
      'providers': [
        entryJson('cli-one', modelId: 'gpt-new'),
        entryJson('cli-two'),
      ],
      'keys': {'cli-one': 'sk-staged'},
    });

    final byName = {
      for (final p in (merged['providers'] as List).cast<Map>())
        p['name'] as String: p,
    };
    // UT-S2: the local edit survives a re-pair untouched.
    expect(byName['mine']!['apiKey'], 'sk-local');
    expect(byName['mine']!['provenance'], localProvenance);
    // Synced rows are replaced wholesale; copy keys attach.
    expect(byName['cli-one']!['modelId'], 'gpt-new');
    expect(byName['cli-one']!['apiKey'], 'sk-staged');
    // Keyless synced entries omit the field entirely — never a stale key.
    expect(byName['cli-two']!['apiKey'] ?? '', '');
    expect(merged['mode'], 'copy');
  });

  test('mergeSyncedProviders on a null doc lands the sync as-is (proxy)', () {
    final merged = mergeSyncedProviders(null, {
      'version': 1,
      'mode': 'proxy',
      'host': 'desk',
      'providers': [entryJson('p1')],
    });
    expect(merged['mode'], 'proxy');
    expect((merged['providers'] as List).length, 1);
  });

  test(
    'mergeLocalProviders stamps local provenance and replaces same-name',
    () {
      final existing = doc([entryJson('p1')]);
      final merged = mergeLocalProviders(existing, [
        (
          name: 'p1',
          apiType: 'openai',
          baseUrl: 'https://imported/v1',
          modelId: 'imported-model',
          provenance: localProvenance,
          apiKey: 'sk-imported',
        ),
        (
          name: 'added',
          apiType: 'openai',
          baseUrl: 'https://b/v1',
          modelId: 'm2',
          provenance: localProvenance,
          apiKey: 'k2',
        ),
      ]);
      final byName = {
        for (final p in (merged['providers'] as List).cast<Map>())
          p['name'] as String: p,
      };
      // An explicit local import wins over a synced row.
      expect(byName['p1']!['baseUrl'], 'https://imported/v1');
      expect(byName['p1']!['provenance'], localProvenance);
      expect(byName['added']!['provenance'], localProvenance);
      expect((merged['providers'] as List).length, 2);
    },
  );

  test('removeProvider drops one entry by name', () {
    final removed = removeProvider(
      doc([entryJson('a'), entryJson('b', provenance: localProvenance)]),
      'a',
    );
    final names = (removed['providers'] as List).map((p) => p['name']);
    expect(names, ['b']);
  });

  test('pickActiveEntry: registry is primary, legacy map is the fallback', () {
    expect(
      pickActiveEntry(
        legacy: {'baseUrl': 'https://legacy', 'model': 'legacy-model'},
        doc: doc([entryJson('p1')]),
      )!.name,
      'p1',
    );
    final legacy = pickActiveEntry(
      legacy: {'baseUrl': 'https://legacy', 'apiKey': 'k', 'model': 'm'},
    );
    expect(legacy!.baseUrl, 'https://legacy');
    expect(pickActiveEntry(legacy: null, doc: null), isNull);
  });

  test(
    'routeFor: fake beats everything; keyless synced = relay; else direct',
    () {
      expect(routeFor(entry('f', modelId: 'fake:echo')), ProviderRoute.fake);
      expect(routeFor(entry('r', apiKey: '')), ProviderRoute.relay);
      expect(routeFor(entry('d', apiKey: 'sk-1')), ProviderRoute.direct);
      // Keyless LOCAL endpoints (Ollama/llama.cpp) fetch directly.
      expect(
        routeFor(entry('l', apiKey: '', provenance: localProvenance)),
        ProviderRoute.direct,
      );
    },
  );

  test(
    'E26: a dead relay surfaces "desktop link is down" as a clean error',
    () async {
      final events = relayTextStream(
        modelForConfig((baseUrl: 'https://api/v1', apiKey: '', model: 'gpt-x')),
        // The JS relay rejects with exactly this message (bridge.js E26);
        // relayTextStream must surface it as a clean ErrorEvent, not throw.
        Stream<String>.error(const SocketException('desktop link is down')),
      );
      final terminal = await events.last;
      expect(terminal, isA<ErrorEvent>());
      final error = await events.result;
      expect(error.stopReason, StopReason.error);
      expect(error.errorMessage, contains('desktop link is down'));
    },
  );

  test('relayTextStream streams deltas then DoneEvent', () async {
    final events = relayTextStream(
      modelForConfig((baseUrl: 'b', apiKey: '', model: 'm')),
      Stream<String>.fromIterable(['he', 'llo']),
    );
    final terminals = <AssistantMessageEvent>[];
    await for (final e in events) {
      terminals.add(e);
    }
    expect(terminals.first, isA<TextDeltaEvent>());
    expect((terminals.first as TextDeltaEvent).delta, 'he');
    expect(terminals.last, isA<DoneEvent>());
    expect(
      ((terminals.last as DoneEvent).message.content.single as TextContent)
          .text,
      'hello',
    );
  });

  test('resolveStreamFn: relay-routed active config uses the relay', () {
    final relayStreams = <Stream<String>>[];
    final fakeRelay = _FakeRelay(relayStreams);
    activeRelay = (relay: fakeRelay, providerName: 'p1');
    addSetterTearDown(() => activeRelay = null);

    final keyless = (baseUrl: 'https://api/v1', apiKey: '', model: 'gpt-x');
    var fn = resolveStreamFn(keyless);
    // The resolved function must call the relay, not fetch.
    fn(
      modelForConfig(keyless),
      Context(systemPrompt: null, messages: [UserMessage.text('hi')]),
    );
    expect(fakeRelay.calls, 1);

    // A keyed config ignores the installed relay.
    resolveStreamFn((baseUrl: 'https://api/v1', apiKey: 'sk', model: 'gpt-x'));
    expect(fakeRelay.calls, 1);

    // fake: stays scripted.
    expect(
      identical(
        resolveStreamFn((baseUrl: '', apiKey: '', model: 'fake:echo')),
        fakeStream,
      ),
      isTrue,
    );
  });

  test('cookie-auth hosts bypass the relay and stream direct', () {
    final relayStreams = <Stream<String>>[];
    final fakeRelay = _FakeRelay(relayStreams);
    activeRelay = (relay: fakeRelay, providerName: 'p1');
    addSetterTearDown(() => activeRelay = null);

    // A keyless CodeMie entry must NOT ride the relay — the relay would
    // strip the browser cookies and CodeMie would 401. The direct SW
    // fetch (FetchClient credentials:include) carries the jar.
    final codemie = (
      baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
      apiKey: '',
      model: 'gpt-x',
    );
    expect(isCookieAuthUrl(codemie.baseUrl), isTrue);
    final fn = resolveStreamFn(codemie);
    fn(
      modelForConfig(codemie),
      Context(systemPrompt: null, messages: [UserMessage.text('hi')]),
    );
    expect(fakeRelay.calls, 0, reason: 'cookie-auth host streams direct');

    // A non-CodeMie host keeps the relay routing.
    final relayed = resolveStreamFn((
      baseUrl: 'https://api/v1',
      apiKey: '',
      model: 'gpt-x',
    ));
    relayed(
      modelForConfig((baseUrl: 'https://api/v1', apiKey: '', model: 'gpt-x')),
      Context(systemPrompt: null, messages: [UserMessage.text('hi')]),
    );
    expect(fakeRelay.calls, 1);
  });

  test('isCookieAuthUrl: classification edges', () {
    expect(isCookieAuthUrl('https://codemie.lab.epam.com/'), isTrue);
    expect(isCookieAuthUrl('https://api.openai.com/v1'), isFalse);
    expect(isCookieAuthUrl('not a url'), isFalse);
    expect(isCookieAuthUrl(''), isFalse);
  });
}

void addSetterTearDown(void Function() fn) => addTearDown(fn);

class _FakeRelay implements BridgeLlmRelay {
  _FakeRelay(this.streams);

  final List<Stream<String>> streams;
  int calls = 0;

  @override
  bool get connected => true;

  @override
  AssistantMessageEventStream stream(
    Model model,
    Context context, {
    CancelToken? cancelToken,
    String? providerName,
  }) {
    calls++;
    return relayTextStream(model, Stream<String>.empty());
  }
}
