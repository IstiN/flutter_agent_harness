/// Issue #221: `saveCliConfig` must never rewrite `~/.fah/config.yaml`
/// from a stale in-memory snapshot (cross-process last-writer-wins ate the
/// owner's `kimi_me` entry repeatedly), must write atomically, and must
/// never persist or resurrect "ghost" entries named after built-in
/// catalog providers (`openai`).
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

CustomProviderEntry entry(
  String name, {
  String modelId = 'm1',
  String apiType = 'openai',
}) => CustomProviderEntry(
  name: name,
  apiType: apiType,
  baseUrl: 'https://$name.example.com/v1',
  modelId: modelId,
);

File configFile(Directory tmp) => File('${tmp.path}/.fah/config.yaml');

List<String> providerNames(CliConfig config) =>
    [for (final e in config.customProviders) e.name];

void main() {
  group('saveCliConfig merge-before-write (issue #221)', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fah-config-merge-test-');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test(
      'a stale snapshot save keeps providers another process added '
      '(IT-clobber: kimi_me survives)',
      () async {
        // Process A boots (snapshot: ira-1 only).
        await saveCliConfig(tmp.path, CliConfig(customProviders: [entry('ira-1')]));
        final staleA = loadCliConfig(tmp.path);
        // Process B boots later, adds kimi_me, saves.
        final freshB = loadCliConfig(tmp.path);
        await saveCliConfig(
          tmp.path,
          CliConfig(customProviders: [...freshB.customProviders, entry('kimi_me')]),
        );
        // A saves ANY unrelated change from its hours-old snapshot.
        await saveCliConfig(
          tmp.path,
          CliConfig(
            mode: 'architect',
            customProviders: staleA.customProviders,
          ),
        );
        final reloaded = loadCliConfig(tmp.path);
        expect(providerNames(reloaded), containsAll(['ira-1', 'kimi_me']));
        expect(reloaded.mode, 'architect');
      },
    );

    test(
      'concurrent writers adding different providers both land '
      '(no lost update under interleaved writes)',
      () async {
        await saveCliConfig(tmp.path, CliConfig(customProviders: [entry('ira-1')]));
        final a = loadCliConfig(tmp.path);
        final b = loadCliConfig(tmp.path);
        await Future.wait([
          saveCliConfig(
            tmp.path,
            CliConfig(customProviders: [...a.customProviders, entry('kimi_me')]),
          ),
          saveCliConfig(
            tmp.path,
            CliConfig(customProviders: [...b.customProviders, entry('minimax-x', apiType: 'minimax')]),
          ),
        ]);
        final reloaded = loadCliConfig(tmp.path);
        expect(
          providerNames(reloaded),
          containsAll(['ira-1', 'kimi_me', 'minimax-x']),
        );
      },
    );

    test(
      'concurrent writers adding the SAME provider yield one entry (E1)',
      () async {
        await saveCliConfig(tmp.path, CliConfig());
        final a = loadCliConfig(tmp.path);
        final b = loadCliConfig(tmp.path);
        await Future.wait([
          saveCliConfig(
            tmp.path,
            CliConfig(customProviders: [...a.customProviders, entry('kimi_me', modelId: 'k1')]),
          ),
          saveCliConfig(
            tmp.path,
            CliConfig(customProviders: [...b.customProviders, entry('kimi_me', modelId: 'k2')]),
          ),
        ]);
        final reloaded = loadCliConfig(tmp.path);
        expect(
          providerNames(reloaded).where((name) => name == 'kimi_me'),
          hasLength(1),
        );
      },
    );

    test(
      'an edit to an existing entry and another writer\'s add both land (E2)',
      () async {
        await saveCliConfig(
          tmp.path,
          CliConfig(customProviders: [entry('ira-1', modelId: 'old')]),
        );
        final a = loadCliConfig(tmp.path);
        final b = loadCliConfig(tmp.path);
        // B adds a new entry first.
        await saveCliConfig(
          tmp.path,
          CliConfig(customProviders: [...b.customProviders, entry('kimi_me')]),
        );
        // A (stale) edits ira-1's last-used model and saves after.
        await saveCliConfig(
          tmp.path,
          CliConfig(customProviders: [
            for (final e in a.customProviders) entry(e.name, modelId: 'new'),
          ]),
        );
        final reloaded = loadCliConfig(tmp.path);
        expect(providerNames(reloaded), containsAll(['ira-1', 'kimi_me']));
        expect(
          reloaded.customProviders.firstWhere((e) => e.name == 'ira-1').modelId,
          'new',
        );
      },
    );

    test(
      'a deleted ghost stays deleted: a stale save never resurrects an '
      'entry named after a built-in provider',
      () async {
        configFile(tmp)
          ..createSync(recursive: true)
          ..writeAsStringSync(
            'mode: code\n'
            'customProviders:\n'
            '  - name: ira-1\n'
            '    apiType: openai\n'
            '    baseUrl: https://ira-1.example.com/v1\n'
            '    modelId: m1\n'
            '  - name: openai\n'
            '    apiType: openai\n'
            '    baseUrl: https://ghost.example.com/v1\n'
            '    modelId: g1\n',
          );
        // The ghost never enters memory (load drops reserved names)...
        final stale = loadCliConfig(tmp.path);
        expect(providerNames(stale), ['ira-1']);
        // ...the user deletes it from the file...
        configFile(tmp).writeAsStringSync(
          'mode: code\n'
          'customProviders:\n'
          '  - name: ira-1\n'
          '    apiType: openai\n'
          '    baseUrl: https://ira-1.example.com/v1\n'
          '    modelId: m1\n',
        );
        // ...and a stale save must not bring it back.
        await saveCliConfig(
          tmp.path,
          CliConfig(mode: 'chat', customProviders: stale.customProviders),
        );
        final text = configFile(tmp).readAsStringSync();
        expect(text, isNot(contains('ghost.example.com')));
        expect(providerNames(loadCliConfig(tmp.path)), ['ira-1']);
      },
    );

    test('a ghost entry built in memory is never persisted', () async {
      await saveCliConfig(
        tmp.path,
        CliConfig(customProviders: [entry('openai'), entry('ira-1')]),
      );
      expect(providerNames(loadCliConfig(tmp.path)), ['ira-1']);
    });

    test(
      'corrupt yaml on disk makes the save refuse loudly without '
      'clobbering the file (E3)',
      () async {
        configFile(tmp)
          ..createSync(recursive: true)
          ..writeAsStringSync('not yaml: [unclosed');
        await expectLater(
          saveCliConfig(tmp.path, CliConfig(mode: 'chat')),
          throwsA(isA<ConfigException>()),
        );
        expect(configFile(tmp).readAsStringSync(), 'not yaml: [unclosed');
      },
    );

    test(
      'writes are atomic: concurrent large saves leave no temp files and '
      'always a parseable document',
      () async {
        await saveCliConfig(tmp.path, CliConfig(customProviders: [entry('ira-1')]));
        final seed = loadCliConfig(tmp.path);
        await Future.wait([
          for (var i = 0; i < 12; i++)
            saveCliConfig(
              tmp.path,
              CliConfig(
                customProviders: [
                  ...seed.customProviders,
                  entry('provider-$i'),
                ],
                allowedTools: [for (var j = 0; j < 50; j++) 'tool-$i-$j'],
              ),
            ),
        ]);
        final leftovers = Directory(
          '${tmp.path}/.fah',
        ).listSync().where((f) => f.path.contains('.tmp')).toList();
        expect(leftovers, isEmpty, reason: 'temp files must be renamed away');
        final reloaded = loadCliConfig(tmp.path);
        // Every provider from every interleaved writer survived the merge.
        expect(
          providerNames(reloaded),
          containsAll(['ira-1', for (var i = 0; i < 12; i++) 'provider-$i']),
        );
      },
    );
  });

  group('reserved provider names (issue #221 ghost)', () {
    test('CustomProviderRegistry.add rejects catalog names', () {
      final registry = CustomProviderRegistry([]);
      for (final reserved in ['openai', 'OpenAI', 'anthropic', 'codemie']) {
        expect(
          () => registry.add(entry(reserved)),
          throwsA(isA<ConfigException>()),
          reason: '$reserved must be rejected',
        );
      }
      expect(registry.entries, isEmpty);
    });

    test('CustomProviderRegistry.add still accepts ordinary names', () {
      final registry = CustomProviderRegistry([]);
      registry.add(entry('openai-2'));
      registry.add(entry('ira-1'));
      expect(providerNames(CliConfig(customProviders: registry.entries)), [
        'openai-2',
        'ira-1',
      ]);
    });

    test('load drops reserved-name entries with the rest intact', () {
      final doc = loadYaml(
        'customProviders:\n'
        '  - name: openai\n'
        '    apiType: openai\n'
        '    baseUrl: https://ghost.example.com/v1\n'
        '    modelId: g1\n'
        '  - name: kimi_me\n'
        '    apiType: kimi\n'
        '    baseUrl: https://kimi.example.com/v1\n'
        '    modelId: k1\n',
      );
      final config = CliConfig.fromYaml(doc as YamlMap);
      expect(providerNames(config), ['kimi_me']);
    });
  });
}
