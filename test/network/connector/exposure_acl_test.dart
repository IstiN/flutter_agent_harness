// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter_agent_harness/src/network/connector/exposure_acl.dart';
import 'package:test/test.dart';

/// AC6 local half: remote writers are viewers — the connector rejects
/// slash-commands, approval/config, tool grants and takeover payloads, and
/// reduces clean structured payloads to plain user text (contract §6,
/// amendment v1.1: connector-only content sanitization).
void main() {
  AclAllow allowOf(String raw) {
    final decision = sanitizeRemoteWrite(raw);
    expect(decision, isA<AclAllow>(), reason: raw);
    return decision as AclAllow;
  }

  String rejectOf(String raw) {
    final decision = sanitizeRemoteWrite(raw);
    expect(decision, isA<AclReject>(), reason: raw);
    return (decision as AclReject).reason;
  }

  group('plain user text passes', () {
    test('ordinary sentences pass as trimmed plain text', () {
      expect(
        allowOf('please fix the flaky test').text,
        'please fix the flaky test',
      );
      expect(allowOf('  add a newline at EOF\n').text, 'add a newline at EOF');
    });

    test('text CONTAINING slashes mid-sentence is not a command', () {
      expect(
        allowOf('use path /usr/local/bin here').text,
        'use path /usr/local/bin here',
      );
    });

    test('a brace fragment that is not JSON object parses as text', () {
      expect(allowOf('{hello world').text, '{hello world');
    });
  });

  group('slash-commands are rejected (AC6)', () {
    test('leading slash-command shapes', () {
      for (final raw in [
        '/approval',
        '/approve all',
        '/config set model x',
        '/allow',
        '/tools',
        '   /takeover now',
      ]) {
        expect(sanitizeRemoteWrite(raw), isA<AclReject>(), reason: raw);
      }
    });

    test('reason names the command', () {
      expect(rejectOf('/config set model x'), contains('/config'));
    });

    test('a lone "/" is not treated as a command', () {
      expect(allowOf('/'), isA<AclAllow>());
    });
  });

  group('structured payloads (AC6)', () {
    test('approval/config/tool-grant/takeover keys are rejected at depth', () {
      expect(
        rejectOf(
          jsonEncode({
            'text': 'hello',
            'approval': {'id': 'a-1'},
          }),
        ),
        contains('approval'),
      );
      expect(
        rejectOf(
          jsonEncode({
            'config': {'model': 'x'},
          }),
        ),
        contains('config'),
      );
      expect(
        rejectOf(
          jsonEncode({
            'text': 'hi',
            'meta': {
              'tool_grant': ['bash'],
            },
          }),
        ),
        contains('tool_grant'),
      );
      expect(rejectOf(jsonEncode({'takeover': true})), contains('takeover'));
      expect(
        rejectOf(
          jsonEncode({
            'nested': [
              {'Admin': 1},
            ],
          }),
        ),
        contains('admin'),
        reason: 'key match is case-insensitive at any depth',
      );
    });

    test('toolGrant camelCase variant is rejected', () {
      expect(rejectOf(jsonEncode({'toolGrant': 'bash'})), isA<String>());
    });

    test('clean {text: ...} payload reduces to plain user text', () {
      final allow = allowOf(
        jsonEncode({
          'text': 'ship it  ',
          'from': 'viewer',
          'meta': {'harmless': 1},
        }),
      );
      expect(allow.text, 'ship it', reason: 'reduced and re-sanitized');
    });

    test(
      'text-carrying payload whose text is itself a command is rejected',
      () {
        expect(
          sanitizeRemoteWrite(jsonEncode({'text': '/approval yes'})),
          isA<AclReject>(),
        );
      },
    );

    test('structured payload without text is rejected', () {
      expect(
        rejectOf(jsonEncode({'note': 'structured but no text'})),
        contains('plain user text'),
      );
    });
  });

  test('empty write is rejected', () {
    expect(rejectOf('   '), contains('empty'));
  });
}
