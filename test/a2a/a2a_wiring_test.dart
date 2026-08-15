@TestOn('vm')
library;

import 'package:flutter_agent_harness/src/a2a/a2a_client.dart';
import 'package:flutter_agent_harness/src/a2a/a2a_config.dart';
import 'package:flutter_agent_harness/src/a2a/a2a_manager.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

A2aConfig parseYaml(String yamlText, [Map<String, String>? env]) {
  final doc = loadYaml(yamlText) as YamlMap;
  return A2aConfig.fromYaml(doc['a2a'], (name) => env?[name]);
}

void main() {
  group('A2aConfig', () {
    test('parses a server with a literal token', () {
      final config = parseYaml('''
a2a:
  servers:
    translator:
      url: https://agents.example.com/translator
      token: secret
''');
      expect(config.servers, containsPair('translator', isNotNull));
      final server = config.servers['translator']!;
      expect(server.url, 'https://agents.example.com/translator');
      expect(server.token, 'secret');
    });

    test('resolves \${NAME} tokens from the environment', () {
      final config = parseYaml('''
a2a:
  servers:
    translator:
      url: https://x.example.com
      token: \${A2A_KEY}
''', {'A2A_KEY': 'env-secret'});
      expect(config.servers['translator']!.token, 'env-secret');
    });

    test('unset env token throws ConfigException', () {
      expect(
        () => parseYaml('''
a2a:
  servers:
    translator:
      url: https://x.example.com
      token: \${MISSING_KEY}
'''),
        throwsA(isA<ConfigException>()),
      );
    });

    test('missing url throws', () {
      expect(
        () => parseYaml('''
a2a:
  servers:
    broken: {}
'''),
        throwsA(isA<ConfigException>()),
      );
    });

    test('non-map section throws', () {
      expect(
        () => A2aConfig.fromYaml('nope', (name) => null),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('mapA2aTaskState', () {
    test('maps the A2A lifecycle onto subagent statuses', () {
      expect(
        mapA2aTaskState(A2aTaskState.submitted),
        SubagentLifecycle.queued,
      );
      expect(mapA2aTaskState(A2aTaskState.working), SubagentLifecycle.running);
      expect(
        mapA2aTaskState(A2aTaskState.inputRequired),
        SubagentLifecycle.idle,
      );
      expect(
        mapA2aTaskState(A2aTaskState.completed),
        SubagentLifecycle.completed,
      );
      expect(mapA2aTaskState(A2aTaskState.failed), SubagentLifecycle.failed);
      expect(
        mapA2aTaskState(A2aTaskState.canceled),
        SubagentLifecycle.aborted,
      );
    });
  });

  group('A2aManager', () {
    test('no servers when config is null', () {
      final manager = A2aManager(null);
      expect(manager.hasServers, isFalse);
      expect(manager.servers, isEmpty);
    });

    test('unknown server connect throws listing available', () {
      final config = parseYaml('''
a2a:
  servers:
    translator:
      url: https://x.example.com
''');
      final manager = A2aManager(config);
      expect(
        () => manager.connect('ghost'),
        throwsStateError,
      );
    });

    test('renderArtifacts joins text parts under the budget', () {
      final task = A2aTask(
        id: 't1',
        state: A2aTaskState.completed,
        artifacts: [
          A2aArtifact(
            parts: [A2aPart(text: 'hello '), A2aPart(text: 'world')],
          ),
        ],
      );
      expect(A2aManager.renderArtifacts(task), 'hello \nworld');
    });

    test('renderArtifacts truncates over the budget', () {
      final task = A2aTask(
        id: 't1',
        state: A2aTaskState.completed,
        artifacts: [
          A2aArtifact(
            parts: [A2aPart(text: 'x' * 200)],
          ),
        ],
      );
      final rendered = A2aManager.renderArtifacts(task, budget: 100);
      expect(rendered.length, lessThan(130));
      expect(rendered, contains('truncated'));
    });
  });
}
