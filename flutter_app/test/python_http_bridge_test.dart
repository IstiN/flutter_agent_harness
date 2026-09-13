// Unit tests for the host side of the python HTTP bridge (issue #337 AC1).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fa/sandbox/python_http_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String _marker(String rid, String authority, String rawRequest) {
  return '\x01FAHTTP1 $rid $authority '
      '${base64.encode(utf8.encode(rawRequest))}\n';
}

void main() {
  late Directory root;
  late FaHttpBridge bridge;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fah_bridge');
    addTearDown(() => root.deleteSync(recursive: true));
  });

  FaHttpBridge makeBridge(http.Client client) =>
      bridge = FaHttpBridge(sandboxRoot: root.path, httpClient: client);

  test('complete control line is stripped and the request is served', () async {
    http.Request? captured;
    final b = makeBridge(
      MockClient((request) async {
        captured = request;
        return http.Response('{"ok":true}', 201);
      }),
    );
    final marker = _marker(
      'abc123',
      'https://api.github.com:443',
      'POST /repos/o/r/issues HTTP/1.1\r\n'
          'Host: api.github.com\r\n'
          'Content-Type: application/json\r\n'
          '\r\n'
          '{"title":"t"}',
    );

    final out = b.filter(utf8.encode('before${marker}after\n'));
    expect(utf8.decode(out), 'beforeafter\n');

    // Allow the background request to complete.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final request = captured!;
    expect(request.method, 'POST');
    expect(
      request.url.toString(),
      'https://api.github.com/repos/o/r/issues',
    );
    expect(request.headers['content-type'], 'application/json');
    expect(utf8.decode(request.bodyBytes), '{"title":"t"}');

    final responseFile = File('${root.path}/dev/.fahttp/abc123');
    expect(responseFile.existsSync(), isTrue);
    final bytes = responseFile.readAsBytesSync();
    final text = utf8.decode(bytes);
    expect(text, startsWith('HTTP/1.1 201'));
    expect(text, contains('content-length:'));
    expect(text, endsWith('{"ok":true}'));
    // No temp file left behind.
    expect(
      Directory('${root.path}/dev/.fahttp').listSync().length,
      1,
    );
    expect(b.flush(), isEmpty);
  });

  test('split control lines across chunks are reassembled', () async {
    final b = makeBridge(
      MockClient((request) async => http.Response('{}', 200)),
    );
    final marker = _marker(
      'deadbeef',
      'https://example.com:443',
      'GET /x HTTP/1.1\r\nHost: example.com\r\n\r\n',
    );
    final bytes = utf8.encode('plain\n$marker');
    final cut = 'plain\n\x01FAHTTP1 deadbeef example.com:443 '.length;

    final first = b.filter(bytes.sublist(0, cut));
    expect(utf8.decode(first), 'plain\n');
    final second = b.filter(bytes.sublist(cut));
    expect(second, isEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      File('${root.path}/dev/.fahttp/deadbeef').existsSync(),
      isTrue,
    );
  });

  test('flush returns a trailing fragment verbatim', () {
    final b = makeBridge(
      MockClient((request) async => http.Response('{}', 200)),
    );
    final out = b.filter(utf8.encode('data\x01FAHTTP1 partial'));
    expect(utf8.decode(out), 'data');
    expect(utf8.decode(b.flush()), '\x01FAHTTP1 partial');
  });

  test('binary stdout without markers passes through untouched', () {
    final b = makeBridge(
      MockClient((request) async => http.Response('{}', 200)),
    );
    final bytes = <int>[0x00, 0x01, 0xff, 0xfe, 0x80, 0x0d, 0x0a, 0x00];
    expect(b.filter(bytes), bytes);
    expect(b.filter(bytes), bytes);
    expect(b.flush(), isEmpty);
  });

  test('transport failures write a !error file', () async {
    final b = makeBridge(
      MockClient((request) async => throw Exception('boom')),
    );
    b.filter(
      utf8.encode(
        _marker(
          'abc0e1',
          'https://example.com:443',
          'GET / HTTP/1.1\r\nHost: example.com\r\n\r\n',
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final text = File('${root.path}/dev/.fahttp/abc0e1').readAsStringSync();
    expect(text, startsWith('!'));
  });

  test('gzip responses are decoded for the socket-less client', () async {
    final b = makeBridge(
      MockClient((request) async => http.Response('{}', 200)),
    );
    // A tiny valid gzip payload of `hi` built via dart:io gzip encoder.
    final gz = gzip.encode(utf8.encode('hi'));
    final response = http.Response.bytes(
      Uint8List.fromList(gz),
      200,
      headers: {'content-encoding': 'gzip'},
    );
    late http.Request captured;
    final b2 = FaHttpBridge(
      sandboxRoot: root.path,
      httpClient: MockClient((request) async {
        captured = request;
        return response;
      }),
    );
    b2.filter(
      utf8.encode(
        _marker(
          'c0ffee',
          'example.com:80',
          'GET / HTTP/1.1\r\nHost: example.com\r\n\r\n',
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(captured.url.scheme, 'http');
    final text = File(
      '${root.path}/dev/.fahttp/c0ffee',
    ).readAsStringSync();
    expect(text, contains('content-length: 2'));
    expect(text, isNot(contains('content-encoding')));
    expect(text, endsWith('hi'));
  });

  test('a 1 MiB JSON body survives the bridge', () async {
    final bigBody = '{"body":"${'x' * (1024 * 1024)}"}';
    late http.Request captured;
    final b = FaHttpBridge(
      sandboxRoot: root.path,
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response('{"n":1}', 200);
      }),
    );
    final marker = _marker(
      'b16f001',
      'api.example.com:443',
      'POST /i HTTP/1.1\r\nHost: api.example.com\r\n\r\n$bigBody',
    );
    // Stream the marker through in small chunks like a real pipe would.
    final bytes = utf8.encode(marker);
    var clean = <int>[];
    for (var i = 0; i < bytes.length; i += 4096) {
      final end = i + 4096 > bytes.length ? bytes.length : i + 4096;
      clean = b.filter(bytes.sublist(i, end));
    }
    expect(clean, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(utf8.decode(captured.bodyBytes), bigBody);
    expect(
      utf8.decode(
        File('${root.path}/dev/.fahttp/b16f001').readAsBytesSync(),
      ),
      contains('{"n":1}'),
    );
  });
}
