// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/src/hub/dap_invite_import.dart';
import 'package:test/test.dart';

void main() {
  const hub = 'wss://hub.fa1.dev/ws';
  const pub = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';
  const priv = 'AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA';

  group('parseDapInviteFlexible — full URL forms', () {
    test('url without keys (public channel)', () {
      final invite = parseDapInviteFlexible('$hub?channel=team');
      expect(invite.hubUrl, '$hub?channel=team');
      expect(invite.channel, 'team');
      expect(invite.pub, isNull);
      expect(invite.priv, isNull);
    });

    test('url with keypair fragment (private channel)', () {
      final invite = parseDapInviteFlexible(
        '$hub?channel=team#pub=$pub&priv=$priv',
      );
      expect(invite.hubUrl, '$hub?channel=team');
      expect(invite.channel, 'team');
      expect(invite.pub, pub);
      expect(invite.priv, priv);
    });
  });

  group('parseDapInviteFlexible — bare channel id', () {
    test('uses the configured hub', () {
      final invite = parseDapInviteFlexible('team', defaultHubUrl: hub);
      expect(invite.hubUrl, hub);
      expect(invite.channel, 'team');
      expect(invite.pub, isNull);
    });

    test('accepts a leading # and dashes/underscores', () {
      final invite = parseDapInviteFlexible('#dev_ops-2', defaultHubUrl: hub);
      expect(invite.channel, 'dev_ops-2');
    });

    test('bare id without a configured hub is a clear error', () {
      expect(
        () => parseDapInviteFlexible('team'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('hub'),
          ),
        ),
      );
    });

    test('whitespace/garbage rejected, nothing partially accepted', () {
      expect(() => parseDapInviteFlexible(''), throwsFormatException);
      expect(() => parseDapInviteFlexible('   '), throwsFormatException);
      expect(
        () => parseDapInviteFlexible('not a channel'),
        throwsFormatException,
      );
      expect(
        () => parseDapInviteFlexible('https://evil'),
        throwsFormatException,
      );
    });
  });

  group('parseDapInviteFlexible — pasted fa dap import command', () {
    test('single-quoted invite', () {
      final invite = parseDapInviteFlexible(
        "fa dap import '$hub?channel=team#pub=$pub&priv=$priv'",
      );
      expect(invite.channel, 'team');
      expect(invite.priv, priv);
    });

    test('double-quoted invite', () {
      final invite = parseDapInviteFlexible('fa dap import "$hub?channel=x"');
      expect(invite.channel, 'x');
    });

    test('unquoted invite', () {
      final invite = parseDapInviteFlexible('fa dap import $hub?channel=x');
      expect(invite.channel, 'x');
    });

    test('command with garbage args rejected', () {
      expect(
        () => parseDapInviteFlexible('fa dap import a b'),
        throwsFormatException,
      );
      expect(
        () => parseDapInviteFlexible('fa dap import'),
        throwsFormatException,
      );
    });
  });
}
