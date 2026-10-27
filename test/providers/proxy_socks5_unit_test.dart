/// Bridge-free unit coverage for the SOCKS5/relay parse paths (issue
/// #1921 CRAP gate): reply-code table, CONNECT-target parsing, greeting /
/// auth / connect-request byte builders, and the reply consumer — all
/// driven by scripted byte streams, no sockets.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_agent_harness/src/providers/proxy_connector_io.dart';

import 'package:test/test.dart';

/// A scripted handshake: reads consume [chunks] in order; writes are
/// recorded into [written] (inspect via [rec.written]).
final class _Rec {
  final written = <List<int>>[];

  Socks5HandshakeReader readerFor(List<List<int>> chunks) =>
      Socks5HandshakeReader.scripted(
        Stream<List<int>>.fromIterable(chunks).map(Uint8List.fromList),
        (bytes) => written.add(List<int>.of(bytes)),
      );
}

void main() {
  group('socks5ReplyText (RFC1928 table)', () {
    test('every defined code maps to its RFC text', () {
      expect(socks5ReplyText(0x01), 'general SOCKS server failure');
      expect(socks5ReplyText(0x02), 'connection not allowed by ruleset');
      expect(socks5ReplyText(0x03), 'network unreachable (through proxy)');
      expect(socks5ReplyText(0x04), 'host unreachable (through proxy)');
      expect(socks5ReplyText(0x05), 'connection refused (through proxy)');
      expect(socks5ReplyText(0x06), 'TTL expired (through proxy)');
      expect(socks5ReplyText(0x07), 'command not supported');
      expect(socks5ReplyText(0x08), 'address type not supported');
    });

    test('unknown codes render as hex', () {
      expect(socks5ReplyText(0x5A), 'reply code 0x5a');
    });
  });

  group('relayTargetOf', () {
    test('CONNECT authority host:port', () {
      expect(relayTargetOf('CONNECT api.example.test:443 HTTP/1.1', ''), (
        'api.example.test',
        443,
      ));
    });

    test('CONNECT authority with empty port defaults to 443', () {
      expect(relayTargetOf('CONNECT api.example.test: HTTP/1.1', ''), (
        'api.example.test',
        443,
      ));
    });

    test('CONNECT IPv6 authority keeps the bare address', () {
      expect(relayTargetOf('CONNECT [2001:db8::1]:8443 HTTP/1.1', ''), (
        '2001:db8::1',
        8443,
      ));
    });

    test('CONNECT without a target token throws', () {
      expect(
        () => relayTargetOf('CONNECT HTTP/1.1', ''),
        throwsA(
          isA<SocketException>().having(
            (e) => e.message,
            'message',
            contains('relay inbound named no target'),
          ),
        ),
      );
    });

    test('plain absolute-form target', () {
      expect(
        relayTargetOf(
          'POST http://fah-target.test:8080/v1/chat/completions HTTP/1.1',
          'POST /v1/chat/completions HTTP/1.1\r\nHost: fah-target.test:8080',
        ),
        ('fah-target.test', 8080),
      );
    });

    test('plain absolute-form without port defaults to 80', () {
      expect(
        relayTargetOf(
          'POST http://fah-target.test/v1 HTTP/1.1',
          'POST /v1 HTTP/1.1\r\nHost: fah-target.test',
        ),
        ('fah-target.test', 80),
      );
    });

    test('origin-form falls back to the Host header', () {
      expect(
        relayTargetOf(
          'POST /v1/chat/completions HTTP/1.1',
          'POST /v1/chat/completions HTTP/1.1\r\n'
              'Content-Type: application/json\r\n'
              'Host: fah-target.test:9090',
        ),
        ('fah-target.test', 9090),
      );
    });

    test('Host header authority without a colon throws', () {
      expect(
        () => relayTargetOf(
          'POST /v1 HTTP/1.1',
          'POST /v1 HTTP/1.1\r\nHost: fah-target.test',
        ),
        throwsA(
          isA<SocketException>().having(
            (e) => e.message,
            'message',
            contains('relay inbound named no target'),
          ),
        ),
      );
    });

    test('a non-numeric port throws', () {
      expect(
        () => relayTargetOf('CONNECT api.example.test:notaport HTTP/1.1', ''),
        throwsA(
          isA<SocketException>().having(
            (e) => e.message,
            'message',
            contains('relay inbound named a bad port'),
          ),
        ),
      );
    });
  });

  group('socks5GreetingBytes', () {
    test('no-auth only when uncredentialed', () {
      expect(socks5GreetingBytes(useAuth: false), [0x05, 1, 0x00]);
    });

    test('no-auth + user/pass when credentialed', () {
      expect(socks5GreetingBytes(useAuth: true), [0x05, 2, 0x00, 0x02]);
    });
  });

  group('socks5ConnectRequestBytes', () {
    test('hostname rides unresolved (ATYP 0x03, remote DNS)', () {
      final bytes = socks5ConnectRequestBytes('api.example.test', 443);
      expect(bytes[0], 0x05);
      expect(bytes[1], 0x01); // CONNECT
      expect(bytes[2], 0x00);
      expect(bytes[3], 0x03); // ATYP domain
      expect(bytes[4], 'api.example.test'.length);
      expect(
        bytes.sublist(5, 5 + 'api.example.test'.length),
        'api.example.test'.codeUnits,
      );
      // Big-endian port tail.
      expect(bytes.sublist(bytes.length - 2), [443 >> 8, 443 & 0xFF]);
    });

    test('IPv4 literal rides as ATYP 0x01 raw address', () {
      final bytes = socks5ConnectRequestBytes('127.0.0.1', 80);
      expect(bytes[3], 0x01);
      expect(bytes.sublist(4, 8), [127, 0, 0, 1]);
    });

    test('IPv6 literal rides as ATYP 0x04 raw address', () {
      final bytes = socks5ConnectRequestBytes('2001:db8::1', 80);
      expect(bytes[3], 0x04);
      expect(bytes.sublist(4, 20).length, 16);
    });
  });

  group('socks5NegotiateAuth (scripted)', () {
    test('no-auth picked: single greeting, no subnegotiation', () async {
      final rec = _Rec();
      await socks5NegotiateAuth(
        rec.readerFor([
          [0x05, 0x00],
        ]),
        rec.written.add,
      );
      expect(rec.written, [
        [0x05, 1, 0x00],
      ]);
    });

    test(
      'RFC1929 success: subnegotiation carries ver/ulen/plen framing',
      () async {
        final rec = _Rec();
        await socks5NegotiateAuth(
          rec.readerFor([
            [0x05, 0x02],
            [0x01, 0x00],
          ]),
          rec.written.add,
          username: 'u',
          password: 'p',
        );
        expect(rec.written[0], [0x05, 2, 0x00, 0x02]);
        expect(rec.written[1], [0x01, 1, 0x75, 1, 0x70]);
      },
    );

    test('non-ASCII credential fails named, not with a codec error', () async {
      final rec = _Rec();
      await expectLater(
        socks5NegotiateAuth(
          rec.readerFor([
            [0x05, 0x02],
          ]),
          rec.written.add,
          username: 'usér',
          password: 'p',
        ),
        throwsA(
          isA<SocketException>().having(
            (e) => e.message,
            'message',
            contains('credentials must be ASCII'),
          ),
        ),
      );
    });

    test('RFC1929 failure names proxyUsername / proxyPasswordEnv', () async {
      final rec = _Rec();
      await expectLater(
        socks5NegotiateAuth(
          rec.readerFor([
            [0x05, 0x02],
            [0x01, 0x01], // non-zero status
          ]),
          rec.written.add,
          username: 'u',
          password: 'wrong',
        ),
        throwsA(
          isA<SocketException>().having(
            (e) => e.message,
            'message',
            contains('check proxyUsername / proxyPasswordEnv'),
          ),
        ),
      );
    });

    test('0xFF verdict — no acceptable method', () async {
      final rec = _Rec();
      await expectLater(
        socks5NegotiateAuth(
          rec.readerFor([
            [0x05, 0xFF],
          ]),
          rec.written.add,
        ),
        throwsA(
          isA<SocketException>().having(
            (e) => e.message,
            'message',
            contains('rejected every offered auth method'),
          ),
        ),
      );
    });

    test('unsupported method verdict names the method', () async {
      final rec = _Rec();
      await expectLater(
        socks5NegotiateAuth(
          rec.readerFor([
            [0x05, 0x80],
          ]),
          rec.written.add,
        ),
        throwsA(
          isA<SocketException>().having(
            (e) => e.message,
            'message',
            contains('unsupported auth method 0x80'),
          ),
        ),
      );
    });

    test('non-v5 greeting is malformed', () async {
      final rec = _Rec();
      await expectLater(
        socks5NegotiateAuth(
          rec.readerFor([
            [0x04, 0x00],
          ]),
          rec.written.add,
        ),
        throwsA(
          isA<SocketException>().having(
            (e) => e.message,
            'message',
            contains('non-v5 greeting'),
          ),
        ),
      );
    });
  });

  group('socks5ConsumeReply (scripted)', () {
    Future<void> expectReplyThrows(
      List<List<int>> chunks,
      String messagePart,
    ) async {
      final rec = _Rec();
      await expectLater(
        socks5ConsumeReply(rec.readerFor(chunks)),
        throwsA(
          isA<SocketException>().having(
            (e) => e.message,
            'message',
            contains(messagePart),
          ),
        ),
      );
    }

    test('success with an IPv4 bind address drains 6 tail bytes', () async {
      final rec = _Rec();
      await socks5ConsumeReply(
        rec.readerFor([
          [0x05, 0x00, 0x00, 0x01],
          [10, 0, 0, 1, 0x01, 0xBB],
        ]),
      );
    });

    test('success with a domain bind address reads the length byte', () async {
      final rec = _Rec();
      await socks5ConsumeReply(
        rec.readerFor([
          [0x05, 0x00, 0x00, 0x03],
          [3, 0x61, 0x62, 0x63, 0x00, 0x50],
        ]),
      );
    });

    test('success with an IPv6 bind address drains 18 tail bytes', () async {
      final rec = _Rec();
      await socks5ConsumeReply(
        rec.readerFor([
          [0x05, 0x00, 0x00, 0x04],
          List<int>.filled(16, 0x20) + [0x00, 0x50],
        ]),
      );
    });

    test('failure REP carries the table text', () {
      expectReplyThrows([
        [0x05, 0x05, 0x00, 0x01],
      ], 'connection refused (through proxy)');
    });

    test('unknown ATYP is a named error', () {
      expectReplyThrows([
        [0x05, 0x00, 0x00, 0x09],
      ], 'unknown address type 0x9');
    });

    test('malformed VER is a named error', () {
      expectReplyThrows([
        [0x04, 0x00, 0x00, 0x01],
      ], 'malformed reply');
    });
  });
}
