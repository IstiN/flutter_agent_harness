import 'package:flutter_agent_harness/src/redact/layer_connection.dart';
import 'package:flutter_agent_harness/src/redact/redaction_types.dart';
import 'package:test/test.dart';

const _cfg = RedactionConfig();

void main() {
  group('layerConnection', () {
    test('postgres URL: only the password span matches', () {
      const url = 'postgres://alice:s3cret@db.example.com:5432/app';
      final matches = layerConnection(url, _cfg);
      expect(matches, hasLength(1));
      final m = matches.single;
      expect(url.substring(m.start, m.end), 's3cret');
      expect(m.layer, RedactionLayer.connection);
      expect(m.kindLabel, connectionPasswordLabel);
    });

    test('E6: special chars in password up to the last @ before host', () {
      const url = 'mysql://user:p@ss:w/rd@host/db';
      final matches = layerConnection(url, _cfg);
      final m = matches.single;
      expect(url.substring(m.start, m.end), 'p@ss:w/rd');
    });

    test('postgresql scheme', () {
      const url = 'postgresql://u:pw@h.example/x';
      final matches = layerConnection(url, _cfg);
      expect(url.substring(matches.single.start, matches.single.end), 'pw');
    });

    test('mongodb+srv scheme', () {
      const url = 'mongodb+srv://svc:hunter2@cluster.example.net/';
      final matches = layerConnection(url, _cfg);
      expect(
        url.substring(matches.single.start, matches.single.end),
        'hunter2',
      );
    });

    test('redis and rediss schemes', () {
      for (final scheme in ['redis', 'rediss']) {
        final url = '$scheme://bob:pw@127.0.0.1:6379/0';
        final matches = layerConnection(url, _cfg);
        expect(matches, hasLength(1), reason: url);
        expect(url.substring(matches.single.start, matches.single.end), 'pw');
      }
    });

    test('https URL with basic auth', () {
      const url = 'https://user:token@example.com/api?x=1';
      final matches = layerConnection(url, _cfg);
      expect(url.substring(matches.single.start, matches.single.end), 'token');
    });

    test('multiple URLs in one text', () {
      const text = 'a postgres://u1:p1@h1/db then mysql://u2:p2@h2/d';
      expect(layerConnection(text, _cfg), hasLength(2));
    });

    test('URLs without passwords do not match', () {
      expect(layerConnection('postgres://db.example.com/app', _cfg), isEmpty);
      expect(layerConnection('postgres://bob@db.example.com', _cfg), isEmpty);
      expect(layerConnection('postgres://bob:@db.example.com', _cfg), isEmpty);
    });

    test('plain text without URLs does not match', () {
      expect(layerConnection('no urls in here', _cfg), isEmpty);
      expect(layerConnection('', _cfg), isEmpty);
    });
  });
}
