// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Unit tests for the app provider-queue writer (issue #561): the scoped
/// config path resolution, the env-shadow refusal, the yaml upsert shape,
/// the write-time reparse guard, and the round-trip through the real file.
/// The IO implementation is imported directly — VM-only by definition.
library;

import 'dart:io' as io;

import 'package:fa/services/providers_queue_loader_io.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

ProviderQueueEntry _entry(String model) => ProviderQueueEntry(
  providerType: 'openai-completions',
  model: model,
  apiKeyEnv: 'K_$model',
);

void main() {
  group('appQueueConfigPath', () {
    test('the project scope anchors the session project directory', () {
      expect(
        appQueueConfigPath(
          ProviderQueueScope.project,
          projectDir: '/proj',
          homeDir: '/home',
        ),
        '/proj/.fah/config.yaml',
      );
      expect(
        () => appQueueConfigPath(ProviderQueueScope.project),
        throwsStateError,
      );
    });

    test('the user scope anchors the desktop home directory', () {
      expect(
        appQueueConfigPath(
          ProviderQueueScope.user,
          projectDir: '/proj',
          homeDir: '/home',
        ),
        '/home/.fah/config.yaml',
      );
      expect(
        appQueueConfigPath(ProviderQueueScope.user),
        endsWith('/.fah/config.yaml'),
      );
    });
  });

  group('assertQueueEnvNotSet', () {
    test('a set FA_PROVIDERS_QUEUE refuses the file write', () {
      expect(
        () => assertQueueEnvNotSet({'FA_PROVIDERS_QUEUE': ' deepseek/chat '}),
        throwsStateError,
      );
    });

    test('a blank or absent FA_PROVIDERS_QUEUE allows the write', () {
      expect(
        () => assertQueueEnvNotSet({'FA_PROVIDERS_QUEUE': '   '}),
        returnsNormally,
      );
      expect(() => assertQueueEnvNotSet({}), returnsNormally);
    });
  });

  group('editedQueueYaml', () {
    test('upserts a providersQueue block into the config source', () {
      final edited = editedQueueYaml('', [_entry('gpt-5'), _entry('deepseek')]);
      final doc = loadYaml(edited) as YamlMap;
      final queue = doc['providersQueue'] as YamlList;
      expect(queue.length, 2);
      expect(
        ((queue.first as YamlMap)['provider_config'] as YamlMap)['model'],
        'gpt-5',
      );
      // A second edit replaces the block in place (one section, new body).
      final again = editedQueueYaml(edited, [_entry('claude')]);
      final doc2 = loadYaml(again) as YamlMap;
      expect((doc2['providersQueue'] as YamlList).length, 1);
    });
  });

  group('assertQueueParses', () {
    test('accepts an edited file the real parser understands', () {
      final edited = editedQueueYaml('', [_entry('gpt-5')]);
      expect(
        () => assertQueueParses(edited, '/tmp/config.yaml'),
        returnsNormally,
      );
    });

    test('rejects an unparseable section', () {
      expect(
        () => assertQueueParses('providersQueue: [broken', '/tmp/config.yaml'),
        throwsA(anything),
      );
    });
  });

  group('writeAppProviderQueue', () {
    late io.Directory temp;
    setUp(() async {
      temp = await io.Directory.systemTemp.createTemp('fa_queue_test');
    });
    tearDown(() async {
      await temp.delete(recursive: true);
    });

    test('the env scope is read-only from the app', () {
      expect(
        () => writeAppProviderQueue([
          _entry('gpt-5'),
        ], layer: ProviderQueueScope.env),
        throwsStateError,
      );
    });

    test('writes a project config the resolver reads back', () async {
      final projectDir = '${temp.path}/proj';
      final path = await writeAppProviderQueue(
        [_entry('gpt-5')],
        layer: ProviderQueueScope.project,
        projectDir: projectDir,
        homeDir: temp.path,
      );
      expect(path, '$projectDir/.fah/config.yaml');
      expect(io.File(path).existsSync(), isTrue);

      final resolution = resolveAppProviderQueue(
        projectDir: projectDir,
        homeDir: temp.path,
      );
      expect(resolution.scope, ProviderQueueScope.project);
      expect(resolution.entries.single.model, 'gpt-5');
    });

    test('a second write upserts the section instead of appending', () async {
      final projectDir = '${temp.path}/proj';
      await writeAppProviderQueue(
        [_entry('gpt-5')],
        layer: ProviderQueueScope.project,
        projectDir: projectDir,
      );
      await writeAppProviderQueue(
        [_entry('claude')],
        layer: ProviderQueueScope.project,
        projectDir: projectDir,
      );
      final body = io.File('$projectDir/.fah/config.yaml').readAsStringSync();
      expect('providersQueue'.allMatches(body), hasLength(1));
      expect(body.contains('claude'), isTrue);
      expect(body.contains('gpt-5'), isFalse);
    });
  });
}
