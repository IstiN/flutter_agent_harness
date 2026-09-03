/// Tests for the fa1.dev cube registry client: catalog fetch, manifest
/// download with sha256 verification, and clean `ConfigException`s for
/// HTTP/shape/hash failures — all over a mock `package:http` client (no
/// real network in unit tests).
library;

import 'dart:convert';

import 'package:flutter_agent_harness/src/cube/registry/cube_registry.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:crypto/crypto.dart';

const _catalog = '''
{
  "templates": [
    {
      "id": "web-scraper",
      "name": "Web scraper",
      "description": "egress for curl to example.com",
      "file": "web-scraper.yaml",
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  ]
}
''';

http.Client _client(String Function(http.Request) respond) =>
    MockClient((request) async {
      final body = respond(request);
      return http.Response(body, 200);
    });

void main() {
  group('CubeRegistryClient.templates', () {
    test('fetches and parses the catalog', () async {
      final client = CubeRegistryClient(
        baseUrl: 'https://fa1.dev',
        client: _client(
          (request) =>
              request.url.toString() == 'https://fa1.dev/cubes/templates.json'
              ? _catalog
              : fail('unexpected url ${request.url}'),
        ),
      );
      final templates = await client.templates();
      expect(templates, hasLength(1));
      expect(templates.first.id, 'web-scraper');
      expect(templates.first.name, 'Web scraper');
      expect(templates.first.file, 'web-scraper.yaml');
      expect(templates.first.sha256, 'a' * 64);
    });

    test('non-200 is a clean ConfigException', () async {
      final client = CubeRegistryClient(
        baseUrl: 'https://fa1.dev',
        client: MockClient((request) async => http.Response('nope', 404)),
      );
      await expectLater(
        client.templates(),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('cube registry: HTTP 404'),
          ),
        ),
      );
    });

    test(
      'malformed json or a wrong shape is a clean ConfigException',
      () async {
        for (final body in ['not json', '{"templates": "many"}', '{}']) {
          final client = CubeRegistryClient(
            baseUrl: 'https://fa1.dev',
            client: _client((_) => body),
          );
          await expectLater(
            client.templates(),
            throwsA(isA<ConfigException>()),
            reason: 'body: $body',
          );
        }
      },
    );
  });

  group('CubeRegistryClient.download', () {
    final manifest = 'apiVersion: fa/v1\nkind: Cube\n';
    final manifestSha = sha256.convert(utf8.encode(manifest)).toString();

    test('downloads the manifest and verifies the sha256', () async {
      final client = CubeRegistryClient(
        baseUrl: 'https://fa1.dev',
        client: _client(
          (request) =>
              request.url.toString() == 'https://fa1.dev/cubes/web-scraper.yaml'
              ? manifest
              : fail('unexpected url ${request.url}'),
        ),
      );
      final template = CubeRegistryTemplate(
        id: 'web-scraper',
        name: 'Web scraper',
        description: 'd',
        file: 'web-scraper.yaml',
        sha256: manifestSha,
      );
      expect(await client.download(template), manifest);
    });

    test('a hash mismatch is refused', () async {
      final client = CubeRegistryClient(
        baseUrl: 'https://fa1.dev',
        client: _client((_) => manifest),
      );
      const template = CubeRegistryTemplate(
        id: 'web-scraper',
        name: 'Web scraper',
        description: 'd',
        file: 'web-scraper.yaml',
        sha256: 'deadbeef',
      );
      await expectLater(
        client.download(template),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('sha256 mismatch for web-scraper'),
          ),
        ),
      );
    });

    test('a non-200 download is a clean ConfigException', () async {
      final client = CubeRegistryClient(
        baseUrl: 'https://fa1.dev',
        client: MockClient((request) async => http.Response('gone', 500)),
      );
      const template = CubeRegistryTemplate(
        id: 'x',
        name: 'X',
        description: 'd',
        file: 'x.yaml',
        sha256: 'deadbeef',
      );
      await expectLater(
        client.download(template),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('CubeRegistryTemplate.fromTemplateJson', () {
    test('rejects a template missing required fields', () {
      expect(
        () => CubeRegistryTemplate.fromTemplateJson({
          'id': 'x',
          'file': 'x.yaml',
          'sha256': 'abc',
        }, where: 'templates[0]'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('rejects a non-hex sha256', () {
      expect(
        () => CubeRegistryTemplate.fromTemplateJson({
          'id': 'x',
          'name': 'X',
          'description': 'd',
          'file': 'x.yaml',
          'sha256': 'zz',
        }, where: 'templates[0]'),
        throwsA(isA<ConfigException>()),
      );
    });
  });
}
