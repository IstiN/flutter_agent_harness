// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/network/invite_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final pub = base64UrlEncode(List.filled(32, 1));
  final priv = base64UrlEncode(List.filled(32, 2));

  group('agent invite', () {
    test('build→parse roundtrip', () {
      final invite = buildAgentInvite(
        hubUri: Uri.parse('wss://hub.fa1.dev/hub'),
        channel: 'general',
        pub: pub,
        priv: priv,
      );
      final parsed = parseAgentInvite(invite);
      expect(parsed.hubUri, Uri.parse('wss://hub.fa1.dev/hub'));
      expect(parsed.channel, 'general');
      expect(
        base64Url.encode(base64Url.decode(parsed.pub)),
        base64Url.encode(base64Url.decode(pub)),
      );
      expect(
        base64Url.encode(base64Url.decode(parsed.priv)),
        base64Url.encode(base64Url.decode(priv)),
      );
    });

    test('extra path segments and query params are preserved in hubUri', () {
      final parsed = parseAgentInvite(
        'wss://hub.fa1.dev:8443/a/b/hub?x=1&channel=ops#pub=$pub&priv=$priv',
      );
      expect(parsed.hubUri, Uri.parse('wss://hub.fa1.dev:8443/a/b/hub?x=1'));
      expect(parsed.channel, 'ops');
    });

    test('http:// scheme rejected with a human-readable reason', () {
      expect(
        () => parseAgentInvite(
          'http://hub.fa1.dev/hub?channel=c#pub=$pub&priv=$priv',
        ),
        throwsA(
          isA<AgentInviteFormatException>().having(
            (e) => e.message,
            'message',
            contains('wss'),
          ),
        ),
      );
    });

    test('ws:// (insecure) scheme rejected', () {
      expect(
        () => parseAgentInvite(
          'ws://hub.fa1.dev/hub?channel=c#pub=$pub&priv=$priv',
        ),
        throwsA(isA<AgentInviteFormatException>()),
      );
    });

    test('missing fragment rejected', () {
      expect(
        () => parseAgentInvite('wss://hub.fa1.dev/hub?channel=c'),
        throwsA(
          isA<AgentInviteFormatException>().having(
            (e) => e.message,
            'message',
            contains('fragment'),
          ),
        ),
      );
    });

    test('pub not 32 bytes rejected', () {
      final short = base64UrlEncode(List.filled(16, 1));
      expect(
        () => parseAgentInvite(
          'wss://hub.fa1.dev/hub?channel=c#pub=$short&priv=$priv',
        ),
        throwsA(
          isA<AgentInviteFormatException>().having(
            (e) => e.message,
            'message',
            contains('32'),
          ),
        ),
      );
    });

    test('garbage base64 rejected', () {
      expect(
        () => parseAgentInvite(
          'wss://hub.fa1.dev/hub?channel=c#pub=***&priv=$priv',
        ),
        throwsA(isA<AgentInviteFormatException>()),
      );
    });

    test('missing channel query parameter rejected', () {
      expect(
        () => parseAgentInvite('wss://hub.fa1.dev/hub#pub=$pub&priv=$priv'),
        throwsA(
          isA<AgentInviteFormatException>().having(
            (e) => e.message,
            'message',
            contains('channel'),
          ),
        ),
      );
    });

    test('empty string rejected', () {
      expect(
        () => parseAgentInvite(''),
        throwsA(isA<AgentInviteFormatException>()),
      );
    });

    test('javascript: URI rejected', () {
      expect(
        () => parseAgentInvite('javascript:alert(1)'),
        throwsA(
          isA<AgentInviteFormatException>().having(
            (e) => e.message,
            'message',
            contains('wss'),
          ),
        ),
      );
    });

    test('buildAgentInvite rejects malformed keys', () {
      expect(
        () => buildAgentInvite(
          hubUri: Uri.parse('wss://hub.fa1.dev/hub'),
          channel: 'general',
          pub: 'not-base64',
          priv: priv,
        ),
        throwsA(isA<AgentInviteFormatException>()),
      );
      expect(
        () => buildAgentInvite(
          hubUri: Uri.parse('https://hub.fa1.dev/hub'),
          channel: 'general',
          pub: pub,
          priv: priv,
        ),
        throwsA(isA<AgentInviteFormatException>()),
      );
    });

    test('REG-NOLEAK: priv lives only in the fragment; the hub URI (what '
        'HTTP/WS requests are built from) never carries it', () {
      final invite = buildAgentInvite(
        hubUri: Uri.parse('wss://hub.fa1.dev/hub'),
        channel: 'general',
        pub: pub,
        priv: priv,
      );
      // The fragment holds the priv (sanity check of the format).
      expect(Uri.parse(invite).fragment, contains('priv='));
      // The query never carries the priv.
      expect(Uri.parse(invite).query, isNot(contains('priv=')));
      // Parsing strips keys from the connect URI entirely.
      final parsed = parseAgentInvite(invite);
      expect(parsed.hubUri.fragment, isEmpty);
      expect(parsed.hubUri.toString(), isNot(contains(priv)));
      expect(parsed.hubUri.toString(), isNot(contains(pub)));
      // RFC 3986: fragments are client-side only and are never sent on the
      // wire; a request Uri built from hubUri therefore cannot leak them.
      final request = Uri.parse(parsed.hubUri.toString());
      expect(request.fragment, isEmpty);
    });
  });

  group('network join link', () {
    test('build→parse roundtrip with password', () {
      final link = buildNetworkJoinLink(
        host: Uri.parse('https://network.fa1.dev'),
        networkId: 'net-123',
        password: 's3cret pw!',
      );
      final parsed = parseNetworkJoinLink(link);
      expect(parsed.host.host, 'network.fa1.dev');
      expect(parsed.host.scheme, 'https');
      expect(parsed.networkId, 'net-123');
      expect(parsed.password, 's3cret pw!');
    });

    test('missing fragment tolerated (password entered manually)', () {
      final parsed = parseNetworkJoinLink(
        'https://network.fa1.dev/join?network=net-123',
      );
      expect(parsed.networkId, 'net-123');
      expect(parsed.password, isNull);
      expect(parsed.host.host, 'network.fa1.dev');
    });

    test('http:// scheme rejected', () {
      expect(
        () => parseNetworkJoinLink('http://network.fa1.dev/join?network=n'),
        throwsA(isA<NetworkJoinLinkFormatException>()),
      );
    });

    test('missing network query parameter rejected', () {
      expect(
        () => parseNetworkJoinLink('https://network.fa1.dev/join'),
        throwsA(isA<NetworkJoinLinkFormatException>()),
      );
    });

    test('garbage rejected', () {
      expect(
        () => parseNetworkJoinLink(''),
        throwsA(isA<NetworkJoinLinkFormatException>()),
      );
      expect(
        () => parseNetworkJoinLink('javascript:alert(1)'),
        throwsA(isA<NetworkJoinLinkFormatException>()),
      );
    });
  });
}
