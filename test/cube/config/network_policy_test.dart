/// Tests for `CubeNetworkPolicy`: wildcard host matching (apex + subdomains,
/// not `notexample.com`), IP literals, ports, deny-wins, and the empty-allow
/// deny-all default.
library;

import 'package:flutter_agent_harness/src/cube/config/network_policy.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  CubeNetworkPolicy parse(String yaml) =>
      CubeNetworkPolicy.fromYaml(loadYaml(yaml));

  group('CubeNetworkPolicy.fromYaml', () {
    test('null section denies all network', () {
      final policy = CubeNetworkPolicy.fromYaml(null);
      expect(policy.allowsAnyNetwork, isFalse);
      expect(policy.permits('example.com', 443), isFalse);
    });

    test('parses map rules with ports and string shorthand', () {
      final policy = parse('''
allow:
  - {host: "*.example.com", ports: [80, 443]}
  - api.github.com
deny:
  - {host: "*", ports: [22, 3389]}
''');
      expect(policy.allow, hasLength(2));
      expect(policy.allow[0].host, '*.example.com');
      expect(policy.allow[0].ports, {80, 443});
      expect(policy.allow[1].host, 'api.github.com');
      expect(policy.allow[1].ports, isNull);
      expect(policy.deny.single.host, '*');
      expect(policy.deny.single.ports, {22, 3389});
    });

    test('rejects unknown keys', () {
      expect(
        () => parse('allowed: [{host: a.com}]'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('cube.spec.network: unknown key "allowed"'),
          ),
        ),
      );
      expect(
        () => parse('allow: [{host: a.com, protocol: tcp}]'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('cube.spec.network.allow[0]: unknown key "protocol"'),
          ),
        ),
      );
    });

    test('rejects non-integer ports and missing host', () {
      expect(
        () => parse('allow: [{host: a.com, ports: [http]}]'),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => parse('allow: [{ports: [80]}]'),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('CubeNetworkPolicy host matching', () {
    final policy = parse('allow: ["*.example.com"]');

    test('matches the apex domain', () {
      expect(policy.permits('example.com', 443), isTrue);
    });

    test('matches single and deep subdomains', () {
      expect(policy.permits('api.example.com', 443), isTrue);
      expect(policy.permits('a.b.example.com', 443), isTrue);
    });

    test('does not match a different domain sharing the suffix', () {
      expect(policy.permits('notexample.com', 443), isFalse);
      expect(policy.permits('example.org', 443), isFalse);
    });

    test('matches host names case-insensitively', () {
      expect(policy.permits('API.Example.COM', 443), isTrue);
    });
  });

  group('CubeNetworkPolicy.semantics', () {
    test('IP literals match exactly only', () {
      final policy = parse('allow: ["192.168.1.1"]');
      expect(policy.permits('192.168.1.1', 80), isTrue);
      expect(policy.permits('192.168.1.2', 80), isFalse);
    });

    test('bare * host matches everything', () {
      final policy = parse('allow: ["*"]');
      expect(policy.permits('anything.net', 1), isTrue);
    });

    test('deny rule wins over allow', () {
      final policy = parse('''
allow: ["*"]
deny: [{host: "*.example.com"}]
''');
      expect(policy.permits('other.com', 80), isTrue);
      expect(policy.permits('a.example.com', 80), isFalse);
      expect(policy.permits('example.com', 80), isFalse);
    });

    test('deny on a specific port only blocks that port', () {
      final policy = parse('''
allow: ["*"]
deny: [{host: "*", ports: [22]}]
''');
      expect(policy.permits('host.com', 22), isFalse);
      expect(policy.permits('host.com', 443), isTrue);
    });

    test('ports restriction on allow blocks other ports', () {
      final policy = parse('allow: [{host: "a.com", ports: [443]}]');
      expect(policy.permits('a.com', 443), isTrue);
      expect(policy.permits('a.com', 80), isFalse);
    });

    test('empty ports set means any port', () {
      final policy = parse('allow: [{host: "a.com", ports: []}]');
      expect(policy.permits('a.com', 1), isTrue);
      expect(policy.permits('a.com', 65535), isTrue);
    });
  });
}
