/// Tests for `CubeEnvPolicy`: literal values, `env:` resolution, hidden
/// vars, the clean-env trio, and strict schema errors.
library;

import 'package:flutter_agent_harness/src/cube/config/env_policy.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  CubeEnvPolicy parse(String yaml) => CubeEnvPolicy.fromYaml(loadYaml(yaml));

  final hostEnv = {
    'PATH': '/usr/bin',
    'HOME': '/home/dev',
    'TMPDIR': '/tmp',
    'HOST_SECRET': 'leaked',
  };

  group('CubeEnvPolicy.fromYaml', () {
    test('null section is empty and passes the host env through', () {
      final policy = CubeEnvPolicy.fromYaml(null);
      expect(policy.isEmpty, isTrue);
      final applied = policy.apply(hostEnv);
      expect(applied, same(hostEnv));
      expect(applied['HOST_SECRET'], 'leaked');
    });

    test('parses value, valueFrom and hidden entries', () {
      final policy = parse('''
- {name: FAH_MODE, value: sandboxed}
- {name: SCRAPER_KEY, valueFrom: "env:API_KEY"}
- {name: HOME, hidden: true}
''');
      expect(policy.vars, hasLength(3));
      expect(policy.vars[0], isA<CubeEnvValue>());
      expect((policy.vars[0] as CubeEnvValue).value, 'sandboxed');
      expect(policy.vars[1], isA<CubeEnvValueFrom>());
      expect((policy.vars[1] as CubeEnvValueFrom).source, 'env:API_KEY');
      expect(policy.vars[2], isA<CubeEnvHidden>());
    });

    test('rejects valueFrom without the env: prefix', () {
      expect(
        () => parse('- {name: X, valueFrom: "secret:API_KEY"}'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('cube.spec.env[0].valueFrom'),
          ),
        ),
      );
      expect(
        () => parse('- {name: X, valueFrom: "env:"}'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('rejects entries with none or several of value/valueFrom/hidden', () {
      expect(() => parse('- {name: X}'), throwsA(isA<ConfigException>()));
      expect(
        () => parse('- {name: X, value: a, hidden: true}'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('rejects unknown keys and duplicate names', () {
      expect(
        () => parse('- {name: X, default: a}'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('cube.spec.env[0]: unknown key "default"'),
          ),
        ),
      );
      expect(
        () => parse('- {name: X, value: a}\n- {name: X, value: b}'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('duplicate variable "X"'),
          ),
        ),
      );
    });
  });

  group('CubeEnvPolicy.apply', () {
    test('injects literal values', () {
      final policy = parse('- {name: FAH_MODE, value: sandboxed}');
      final result = policy.apply(hostEnv);
      expect(result['FAH_MODE'], 'sandboxed');
    });

    test('resolves valueFrom from the host env', () {
      final policy = parse('- {name: KEY, valueFrom: "env:HOST_SECRET"}');
      expect(policy.apply(hostEnv)['KEY'], 'leaked');
    });

    test('missing valueFrom source is simply absent', () {
      final policy = parse('- {name: KEY, valueFrom: "env:MISSING_VAR"}');
      final result = policy.apply(hostEnv);
      expect(result.containsKey('KEY'), isFalse);
    });

    test('hidden vars are stripped', () {
      final policy = parse('- {name: PATH, hidden: true}');
      expect(policy.apply(hostEnv).containsKey('PATH'), isFalse);
    });

    test('clean-env trio survives; other host vars do not', () {
      final policy = parse('- {name: FAH_MODE, value: sandboxed}');
      final result = policy.apply(hostEnv);
      expect(result['PATH'], '/usr/bin');
      expect(result['HOME'], '/home/dev');
      expect(result['TMPDIR'], '/tmp');
      expect(result.containsKey('HOST_SECRET'), isFalse);
    });

    test('declared var overrides a trio variable', () {
      final policy = parse('- {name: HOME, value: /workspace}');
      expect(policy.apply(hostEnv)['HOME'], '/workspace');
    });

    test('trio dropped entirely with only hidden vars declared', () {
      final policy = parse('- {name: X, value: y}');
      // X declared (non-empty policy) but PATH/HOME/TMPDIR untouched.
      final result = policy.apply(hostEnv);
      expect(result, {
        'PATH': '/usr/bin',
        'HOME': '/home/dev',
        'TMPDIR': '/tmp',
        'X': 'y',
      });
    });

    test('hidden wins over the trio for the same name', () {
      final policy = parse('- {name: TMPDIR, hidden: true}');
      expect(policy.apply(hostEnv).containsKey('TMPDIR'), isFalse);
    });
  });
}
