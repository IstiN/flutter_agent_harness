/// Tests for `CubeSpec`: strict apiVersion/kind/name validation, safe
/// defaults for a minimal document, full-section parsing, and the stable
/// [CubeSpec.toCanonicalMap] form used for cache keys.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/src/cube/config/cube_spec.dart';
import 'package:flutter_agent_harness/src/cube/config/env_policy.dart';
import 'package:flutter_agent_harness/src/cube/config/fs_policy.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  CubeSpec parse(String yaml, {String sourcePath = 'cube'}) =>
      CubeSpec.fromYaml(loadYaml(yaml), sourcePath: sourcePath);

  group('CubeSpec.fromYaml', () {
    test('minimal document parses with safe defaults', () {
      final spec = parse('''
apiVersion: fa/v1
kind: Cube
metadata:
  name: web-scraper
''');
      expect(spec.name, 'web-scraper');
      expect(spec.description, isNull);
      expect(spec.tools.permits('anything'), isFalse); // deny-all tools
      expect(spec.network.permits('example.com', 443), isFalse);
      expect(spec.network.allowsAnyNetwork, isFalse);
      expect(spec.filesystem.workspace, '/workspace');
      expect(spec.env.isEmpty, isTrue);
      expect(spec.resources.memoryBytes, isNull);
      expect(spec.cache.enabled, isFalse);
    });

    test('parses a full document', () {
      final spec = parse('''
apiVersion: fa/v1
kind: Cube
metadata:
  name: web-scraper
  description: "Fetches pages"
spec:
  tools:
    allow: [curl, "git*"]
    deny: ["git push"]
  network:
    allow: [{host: "*.example.com", ports: [80, 443]}]
    deny: [{host: "*", ports: [22]}]
  filesystem:
    workspace: /workspace
    mounts:
      - {path: /usr/bin, access: ro}
      - {path: ~/.ssh, access: deny}
  env:
    - {name: FAH_MODE, value: sandboxed}
    - {name: SCRAPER_KEY, valueFrom: "env:API_KEY"}
  resources:
    limits: {cpu: "50%", memory: 512Mi}
    timeout: 3600s
  cache:
    paths: [/workspace/.cache]
    ttl: 24h
''');
      expect(spec.description, 'Fetches pages');
      expect(spec.tools.permits('curl'), isTrue);
      expect(spec.tools.permits('git push'), isFalse);
      expect(spec.network.permits('api.example.com', 443), isTrue);
      expect(spec.network.permits('api.example.com', 22), isFalse);
      expect(
        spec.filesystem.accessFor('/usr/bin/curl'),
        CubePathAccess.readOnly,
      );
      expect(spec.env.vars[1], isA<CubeEnvValueFrom>());
      expect(spec.resources.memoryBytes, 512 * 1024 * 1024);
      expect(spec.resources.timeout, const Duration(hours: 1));
      expect(spec.cache.ttl, const Duration(hours: 24));
    });

    test('rejects a non-map document', () {
      expect(
        () => CubeSpec.fromYaml('nope'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('cube: must be a yaml map'),
          ),
        ),
      );
    });

    test('rejects wrong or missing apiVersion and kind', () {
      expect(
        () => parse('apiVersion: fa/v2\nkind: Cube\nmetadata: {name: a}'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('cube.apiVersion'),
          ),
        ),
      );
      expect(
        () => parse('apiVersion: fa/v1\nkind: Box\nmetadata: {name: a}'),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => parse('kind: Cube\nmetadata: {name: a}'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('rejects invalid cube names', () {
      for (final name in ['Web', '1x', 'a_b', 'a b', '']) {
        expect(
          () => parse('apiVersion: fa/v1\nkind: Cube\nmetadata: {name: $name}'),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              contains('cube.metadata.name'),
            ),
          ),
          reason: 'name "$name" must be rejected',
        );
      }
    });

    test('accepts the documented name shape', () {
      final spec = parse(
        'apiVersion: fa/v1\nkind: Cube\nmetadata: {name: web-scraper-2}',
      );
      expect(spec.name, 'web-scraper-2');
    });

    test('rejects unknown keys at the top level and in metadata', () {
      expect(
        () => parse('''
apiVersion: fa/v1
kind: Cube
metadata: {name: a}
extra: true
'''),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('cube: unknown key "extra"'),
          ),
        ),
      );
      expect(
        () => parse(
          'apiVersion: fa/v1\nkind: Cube\n'
          'metadata: {name: a, labels: {x: y}}',
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('cube.metadata: unknown key "labels"'),
          ),
        ),
      );
    });

    test('rejects unknown spec sections and a non-map spec', () {
      expect(
        () => parse(
          'apiVersion: fa/v1\nkind: Cube\nmetadata: {name: a}\n'
          'spec: {gpu: true}',
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('cube.spec: unknown key "gpu"'),
          ),
        ),
      );
      expect(
        () => parse(
          'apiVersion: fa/v1\nkind: Cube\nmetadata: {name: a}\n'
          'spec: [1]',
        ),
        throwsA(isA<ConfigException>()),
      );
    });

    test('sourcePath names the file in error messages', () {
      expect(
        () => parse('kind: Cube\nmetadata: {name: a}', sourcePath: '/c/x.yaml'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            startsWith('/c/x.yaml.'),
          ),
        ),
      );
    });
  });

  group('CubeSpec.toCanonicalMap', () {
    final fullYaml = '''
apiVersion: fa/v1
kind: Cube
metadata:
  name: web-scraper
  description: Fetches pages
spec:
  tools:
    allow: [curl, "git*"]
  env:
    - {name: ZED, value: last}
    - {name: ABC, value: first}
  resources:
    limits: {memory: 512Mi}
''';

    test('two parses of the same document produce equal maps', () {
      final a = parse(fullYaml).toCanonicalMap();
      final b = parse(fullYaml).toCanonicalMap();
      expect(a, equals(b));
    });

    test('equivalent documents with different order produce equal maps', () {
      final reordered = parse('''
kind: Cube
apiVersion: fa/v1
metadata: {name: web-scraper, description: Fetches pages}
spec:
  resources: {limits: {memory: 512Mi}}
  env:
    - {name: ABC, value: first}
    - {name: ZED, value: last}
  tools: {allow: ["git*", curl]}
''');
      expect(
        reordered.toCanonicalMap(),
        equals(parse(fullYaml).toCanonicalMap()),
      );
    });

    test('map is JSON-encodable and includes name plus spec', () {
      final map = parse(fullYaml).toCanonicalMap();
      expect(jsonEncode(map), isA<String>()); // no encode errors
      expect((map['metadata'] as Map)['name'], 'web-scraper');
      expect(map['apiVersion'], 'fa/v1');
      expect(map['kind'], 'Cube');
      final spec = map['spec'] as Map;
      expect((spec['tools'] as Map)['allow'], ['curl', 'git*']); // sorted
      final envVars = spec['env'] as List;
      expect((envVars.first as Map)['name'], 'ABC'); // sorted by name
      expect((spec['resources'] as Map)['memoryBytes'], 512 * 1024 * 1024);
    });

    test('durations serialize as seconds and nulls are omitted', () {
      final map = parse(
        'apiVersion: fa/v1\nkind: Cube\n'
        'metadata: {name: a}\n'
        'spec: {resources: {timeout: 90s}}',
      ).toCanonicalMap();
      final resources = (map['spec'] as Map)['resources'] as Map;
      expect(resources['timeout'], 90);
      expect(resources.containsKey('cpu'), isFalse);
      expect(resources.containsKey('memoryBytes'), isFalse);
    });
  });
}
