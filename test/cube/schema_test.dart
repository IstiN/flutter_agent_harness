/// Guard tests for the cube schema and docs: the JSON Schema file parses
/// and mirrors [CubeSpec]'s strict parsing, the yaml example in
/// `docs/cubes.md` parses via [CubeSpec.fromYaml], and the schema's
/// enums match parser reality. Keeps docs and schema honest against the
/// parser without adding dependencies.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/cube/config/cube_spec.dart';
import 'package:flutter_agent_harness/src/cube/config/fs_policy.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Spec sections the parser accepts today. `backend` is declared in the
/// schema and docs ahead of the parser (kernel activation in review).
const parserSpecKeys = {
  'tools',
  'network',
  'filesystem',
  'env',
  'resources',
  'cache',
};

/// Spec sections the schema allows: the parser's set plus `backend`.
const schemaSpecKeys = {'backend', ...parserSpecKeys};

/// The yaml example between the first ```yaml fences in docs/cubes.md.
final RegExp _docsYamlExample = RegExp(r'```yaml\n([\s\S]*?)```');

void main() {
  Map<String, Object?> loadSchema() =>
      jsonDecode(File('schema/cube_schema.json').readAsStringSync())
          as Map<String, Object?>;

  group('schema/cube_schema.json', () {
    test('parses as JSON with draft 2020-12', () {
      final schema = loadSchema();
      expect(
        schema['\$schema'],
        'https://json-schema.org/draft/2020-12/schema',
      );
      expect(schema['\$id'], isA<String>());
      expect(schema['title'], isA<String>());
      expect(schema['description'], isA<String>());
    });

    test('object schemas forbid unknown keys at every level', () {
      void check(Object? node, String path) {
        if (node is Map<Object?, Object?>) {
          if (node['type'] == 'object') {
            expect(
              node['additionalProperties'],
              false,
              reason:
                  '$path: object schema must set additionalProperties: false',
            );
          }
          node.forEach((key, value) => check(value, '$path/$key'));
        } else if (node is List<Object?>) {
          for (var i = 0; i < node.length; i++) {
            check(node[i], '$path[$i]');
          }
        }
      }

      check(loadSchema(), r'$');
    });

    test('document and spec keys match the parser contract', () {
      final schema = loadSchema();
      final properties = schema['properties']! as Map<String, Object?>;
      expect(properties.keys.toSet(), {
        'apiVersion',
        'kind',
        'metadata',
        'spec',
      });

      final spec = properties['spec']! as Map<String, Object?>;
      final specProperties = spec['properties']! as Map<String, Object?>;
      expect(specProperties.keys.toSet(), schemaSpecKeys);
      expect(specProperties.keys.toSet().difference(parserSpecKeys), {
        'backend',
      }, reason: 'backend is schema/docs-only until kernel activation lands');

      // Strict parser: a spec key outside the contract is rejected.
      expect(
        () => CubeSpec.fromYaml(
          loadYaml(
            'apiVersion: fa/v1\nkind: Cube\nmetadata: {name: x}\n'
            'spec:\n  bogus: {}\n',
          ),
        ),
        throwsA(isA<ConfigException>()),
      );
    });

    test('enums match parser reality', () {
      final specProperties =
          (loadSchema()['properties']! as Map<String, Object?>)['spec']!
              as Map<String, Object?>;
      final spec = specProperties['properties']! as Map<String, Object?>;

      expect(
        (loadSchema()['properties']! as Map<String, Object?>)['apiVersion'],
        {'const': 'fa/v1'},
      );
      expect((loadSchema()['properties']! as Map<String, Object?>)['kind'], {
        'const': 'Cube',
      });
      expect(spec['backend'], containsPair('enum', ['policy', 'kernel']));

      final mounts =
          ((spec['filesystem']! as Map<String, Object?>)['properties']!
                  as Map<String, Object?>)['mounts']!
              as Map<String, Object?>;
      final access =
          ((mounts['items']! as Map<String, Object?>)['properties']!
                  as Map<String, Object?>)['access']!
              as Map<String, Object?>;
      expect(
        access['enum'],
        CubePathAccess.values.map((value) => value.label).toList(),
      );
    });
  });

  group('docs/cubes.md example', () {
    test('parses via CubeSpec.fromYaml (strict)', () {
      final docs = File('docs/cubes.md').readAsStringSync();
      final match = _docsYamlExample.firstMatch(docs);
      expect(
        match,
        isNotNull,
        reason: 'docs/cubes.md must contain a yaml example',
      );

      final spec = CubeSpec.fromYaml(loadYaml(match!.group(1)!));
      expect(spec.name, 'web-scraper');
      expect(spec.description, isNotNull);
    });

    test('example policies behave as documented', () {
      final docs = File('docs/cubes.md').readAsStringSync();
      final spec = CubeSpec.fromYaml(
        loadYaml(_docsYamlExample.firstMatch(docs)!.group(1)!),
      );

      expect(spec.tools.permits('curl'), isTrue);
      expect(spec.tools.permits('git status'), isTrue); // git* wildcard
      expect(spec.tools.permits('git push'), isFalse); // deny wins
      expect(spec.tools.permits('python'), isFalse); // empty-allow default off

      expect(spec.network.permits('docs.example.com', 443), isTrue);
      expect(spec.network.permits('api.github.com', 443), isTrue);
      expect(
        spec.network.permits('evil.example.com', 22),
        isFalse,
      ); // deny wins
      expect(spec.network.permits('unlisted.net', 443), isFalse);

      expect(spec.filesystem.workspace, '/workspace');
      expect(spec.env.vars, hasLength(3));
      expect(spec.resources.memoryBytes, 512 * 1024 * 1024);
      expect(spec.resources.timeout, const Duration(seconds: 3600));
      expect(spec.cache.enabled, isTrue);
      expect(spec.cache.ttl, const Duration(hours: 24));
    });
  });
}
