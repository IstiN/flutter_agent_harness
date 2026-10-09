// gh-1444 AC3/AC6/E2: sandbox network paths fail LOUDLY — every transport
// failure renders a `[bridge]` stderr line (host + error class + request
// id) AND reaches the app.log sink; non-idempotent verbs are never
// auto-retried; a body broken mid-transfer delivers the partial bytes with
// a truncation line (never a clean empty); codeload-shaped redirects
// follow with `-L`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fa/sandbox/bridge_errors.dart';
import 'package:fa/sandbox/python_http_bridge.dart';
import 'package:fa/sandbox/sandbox_builtins.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

SandboxBuiltins _builtins(http.Client client, {List<String>? failures}) =>
    SandboxBuiltins(
      readTextFile: (_) async => null,
      writeBinaryFile: (_, __) async {},
      httpClient: client,
      logFailure: failures?.add,
    );

void main() {
  group('curl builtin transport failures (AC3)', () {
    test('a connection reset renders a [bridge] line in the result', () async {
      final failures = <String>[];
      final builtins = _builtins(
        MockClient(
          (_) async => throw const SocketException('Connection reset by peer'),
        ),
        failures: failures,
      );

      final result = await builtins.curl([
        '-s',
        'https://api.github.com/repos/o/r',
      ]);

      expect(result.exitCode, 7);
      final stderr = utf8.decode(result.stderr);
      expect(stderr, contains('[bridge] GET api.github.com:'));
      expect(stderr, contains('connection reset'));
      expect(stderr, contains('(rid '));
      // The log sink saw the same structured line.
      expect(failures, hasLength(1));
      expect(failures.single, contains('[bridge] GET api.github.com:'));
      expect(failures.single, contains('connection reset'));
      // Headers/bodies never leak into the failure line.
      expect(stderr, isNot(contains('repos/o/r')));
    });

    test('a POST is never auto-retried (one attempt, exactly)', () async {
      var sends = 0;
      final builtins = _builtins(
        MockClient((_) async {
          sends++;
          throw const SocketException('Connection reset by peer');
        }),
      );

      final result = await builtins.curl([
        '-s',
        '-X',
        'POST',
        '-d',
        '{"title":"t"}',
        'https://api.github.com/repos/o/r/issues',
      ]);

      expect(result.exitCode, 7);
      expect(sends, 1, reason: 'non-idempotent verbs must not be retried');
    });

    test('a timeout keeps exit 28 and adds the [bridge] line', () async {
      final builtins = _builtins(
        MockClient((_) async => throw TimeoutException('hung')),
      );

      final result = await builtins.curl(['-s', 'https://slow.example.com']);

      expect(result.exitCode, 28);
      final stderr = utf8.decode(result.stderr);
      expect(stderr, contains('curl: (28) Operation timed out'));
      expect(stderr, contains('[bridge] GET slow.example.com: timeout'));
    });
  });

  group('codeload-shaped redirects (AC6)', () {
    const tarball = [0x1f, 0x8b, 0x08, 0x00, 0x62, 0x61, 0x6c, 0x6c];

    test('curl -L follows the codeload redirect to the tarball', () async {
      // A client that implements redirect following like the real
      // IOClient/CupertinoClient the shells use (MockClient does not).
      final builtins = _builtins(
        _RedirectingClient((request) async {
          if (request.url.host == 'codeload.github.com') {
            return http.Response(
              '',
              302,
              headers: {
                'location':
                    'https://objects.githubusercontent.com/x/tar.gz/main',
              },
            );
          }
          return http.Response.bytes(tarball, 200);
        }),
      );

      final result = await builtins.curl([
        '-s',
        '-L',
        'https://codeload.github.com/o/r/tar.gz/refs/heads/main',
      ]);

      expect(result.exitCode, 0);
      expect(result.stdout, tarball);
      expect(result.stdout, isNotEmpty);
    });

    test(
      'without -L the 302 body is empty (documented curl semantics)',
      () async {
        final builtins = _builtins(
          MockClient(
            (_) async => http.Response(
              '',
              302,
              headers: {'location': 'https://objects.githubusercontent.com/x'},
            ),
          ),
        );

        final result = await builtins.curl([
          '-s',
          'https://codeload.github.com/o/r/tar.gz/refs/heads/main',
        ]);

        expect(result.exitCode, 0);
        expect(result.stdout, isEmpty);
      },
    );
  });

  group('mid-body reset delivers the partial payload (E2)', () {
    test('partial bytes plus a [bridge] truncation line, exit 18', () async {
      final failures = <String>[];
      final chunk = Uint8List.fromList(utf8.encode('partial-data'));
      final controller = StreamController<Uint8List>();
      final builtins = _builtins(
        MockClient.streaming((request, bodyStream) async {
          unawaited(() async {
            await Future<void>.delayed(Duration.zero);
            controller.add(chunk);
            await Future<void>.delayed(Duration.zero);
            controller.addError(
              const SocketException('Connection reset by peer'),
            );
            await controller.close();
          }());
          return http.StreamedResponse(
            controller.stream,
            200,
            headers: {'content-type': 'application/octet-stream'},
          );
        }),
        failures: failures,
      );

      // A stream that yields the chunk, then dies mid-body.
      final result = await builtins.curl([
        '-s',
        'https://codeload.github.com/o/r/tar.gz/refs/heads/main',
      ]);

      expect(result.exitCode, 18);
      expect(utf8.decode(result.stdout), 'partial-data');
      final stderr = utf8.decode(result.stderr);
      expect(stderr, contains('after 12 bytes (truncated)'));
      expect(stderr, contains('[bridge] GET codeload.github.com:'));
      expect(failures.single, contains('codeload.github.com'));
    });
  });

  group('oversized response quota (E7)', () {
    test(
      'the stream aborts at the cap with both byte numbers, exit 63',
      () async {
        // Shrink the cap via a subclass seam? The cap is a const; instead
        // push a body just over it — 256 MiB is too big for a test, so this
        // test exercises the abort loop with a fake oversized stream via
        // curl's cap check on the FIRST chunk over the limit... The cap is
        // static: verify the abort logic through a manual drain of a stream
        // that emits more than maxCurlResponseBytes in one chunk.
        final big = Uint8List(SandboxBuiltins.maxCurlResponseBytes + 1);
        final controller = StreamController<Uint8List>();
        final builtins = _builtins(
          MockClient.streaming((request, bodyStream) async {
            unawaited(() async {
              await Future<void>.delayed(Duration.zero);
              controller.add(big);
              await controller.close();
            }());
            return http.StreamedResponse(controller.stream, 200);
          }),
        );

        final result = await builtins.curl(['-s', 'https://big.example.com']);

        expect(result.exitCode, 63);
        final stderr = utf8.decode(result.stderr);
        expect(stderr, contains('${big.length} bytes'));
        expect(stderr, contains('${SandboxBuiltins.maxCurlResponseBytes}'));
        expect(utf8.decode(result.stdout), isEmpty);
      },
    );
  });

  group('python HTTP bridge failures (AC3)', () {
    late Directory root;
    late List<String> failures;

    setUp(() {
      root = Directory.systemTemp.createTempSync('fah_bridge_loud');
      failures = <String>[];
      addTearDown(() => root.deleteSync(recursive: true));
    });

    FaHttpBridge makeBridge(http.Client client) => FaHttpBridge(
      sandboxRoot: root.path,
      httpClient: client,
      logFailure: failures.add,
    );

    test(
      'a failed exchange writes the [bridge] line back and logs it',
      () async {
        final bridge = makeBridge(
          MockClient(
            (_) async =>
                throw const SocketException('Connection reset by peer'),
          ),
        );
        final rid = 'abc123';
        final marker =
            '\x01FAHTTP1 $rid https://api.github.com:443 '
            '${base64.encode(utf8.encode('GET /repos/o/r HTTP/1.1\r\n'
            'Host: api.github.com\r\n\r\n'))}\n';
        bridge.filter(utf8.encode(marker));

        await Future<void>.delayed(const Duration(milliseconds: 200));

        final file = File('${root.path}/dev/.fahttp/$rid');
        expect(file.existsSync(), isTrue);
        final payload = utf8.decode(file.readAsBytesSync());
        expect(payload, startsWith('![bridge] GET api.github.com:'));
        expect(payload, contains('connection reset'));
        expect(payload, contains('(rid $rid)'));
        expect(failures.single, contains('[bridge] GET api.github.com:'));
      },
    );
  });

  group('bridge error classification (pure)', () {
    test('maps the common transport shapes', () {
      expect(bridgeErrorClass(TimeoutException('x')), 'timeout');
      expect(
        bridgeErrorClass(const SocketException('Connection refused')),
        'connection refused',
      );
      expect(
        bridgeErrorClass(const SocketException('Connection reset by peer')),
        'connection reset',
      );
      expect(
        bridgeErrorClass(
          const SocketException("Failed host lookup: 'api.github.com'"),
        ),
        'dns',
      );
      expect(
        bridgeErrorClass(Exception('HandshakeException: TLS failure')),
        'tls',
      );
      expect(bridgeErrorClass(StateError('weird')), 'error');
    });

    test('failure line never carries headers or paths', () {
      final line = bridgeFailureLine(
        method: 'POST',
        host: bridgeHostOfAuthority('https://api.github.com:443'),
        error: const SocketException('Connection reset by peer'),
        rid: 'r1',
      );
      expect(line, '[bridge] POST api.github.com: connection reset (rid r1)');
    });

    test(
      'IPv6 authorities render the unbracketed host (review suggestion)',
      () {
        expect(bridgeHostOfAuthority('http://[::1]:8080/x'), '::1');
        expect(bridgeHostOfAuthority('[::1]:443'), '::1');
        expect(
          bridgeHostOfAuthority('https://[2001:db8::1]:443'),
          '2001:db8::1',
        );
      },
    );

    test('scheme/host/port authorities keep the exact host', () {
      expect(
        bridgeHostOfAuthority('https://api.github.com:443'),
        'api.github.com',
      );
      expect(bridgeHostOfAuthority('api.github.com:443'), 'api.github.com');
      expect(
        bridgeHostOfAuthority('https://slow.example.com'),
        'slow.example.com',
      );
    });

    test('a corrupt authority still renders (fail loudly, never silently)', () {
      // Uri.parse throws on this shape; the failure line must still carry
      // something host-shaped rather than crashing the failure path.
      expect(bridgeHostOfAuthority('http://[::1:8080/x'), isNotEmpty);
    });

    test('partial-body line carries the byte count and truncation', () {
      final line = bridgeFailureLine(
        method: 'GET',
        host: 'codeload.github.com',
        error: const SocketException('Connection reset by peer'),
        rid: 'r2',
        partialBytes: 4096,
      );
      expect(
        line,
        '[bridge] GET codeload.github.com: connection reset '
        '(rid r2) after 4096 bytes (truncated)',
      );
    });
  });
}

/// An http.Client whose `send` follows 3xx redirects (up to 5) like the
/// real IOClient/CupertinoClient the sandbox shells run on — MockClient
/// returns the first response verbatim.
final class _RedirectingClient extends http.BaseClient {
  _RedirectingClient(this._handler);

  final Future<http.Response> Function(http.Request request) _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    var current = request;
    for (var hop = 0; hop < 5; hop++) {
      final response = await _handler(_asRequest(current));
      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers['location'];
        if (location != null && current is http.Request) {
          current = http.Request(current.method, Uri.parse(location))
            ..followRedirects = current.followRedirects;
          continue;
        }
      }
      return http.StreamedResponse(
        Stream.value(Uint8List.fromList(response.bodyBytes)),
        response.statusCode,
        headers: response.headers,
      );
    }
    throw StateError('too many redirects');
  }

  http.Request _asRequest(http.BaseRequest request) {
    final r = request is http.Request
        ? request
        : http.Request(request.method, request.url);
    r.headers.addAll(request.headers);
    return r;
  }
}
