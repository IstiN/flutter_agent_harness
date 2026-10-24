// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/src/hub/dap_env_channels.dart';
import 'package:flutter_agent_harness/src/hub/dap_membership.dart';
import 'package:test/test.dart';

void main() {
  const hub = 'wss://hub.fa1.dev/ws';

  test('null/empty env → no channels, no warnings', () {
    expect(parseDapEnvChannels(null).isEmpty, isTrue);
    expect(parseDapEnvChannels('  ').warnings, isEmpty);
  });

  test('plaintext priv + keyless public + mixed set joins together (AC15)', () {
    final result = parseDapEnvChannels(
      '[{"channel":"team","pub":"P","priv":"PLAINTEXT"},'
      '{"channel":"open"},'
      '{"channel":"ci","pub":"Q","priv":"dapkey1.envelope"}]',
      defaultHubUrl: hub,
    );
    expect(result.warnings, isEmpty);
    expect(result.memberships, hasLength(3));
    expect(result.memberships[0].priv, 'PLAINTEXT');
    expect(result.memberships[1].pub, isNull);
    expect(result.memberships[2].priv, 'dapkey1.envelope');
    expect(
      result.memberships.every((m) => m.scope == DapChannelScope.global),
      isTrue,
    );
    expect(result.memberships.every((m) => m.hubUrl == hub), isTrue);
  });

  test('per-entry hubUrl wins over the default (E3)', () {
    final result = parseDapEnvChannels(
      '[{"channel":"x","hubUrl":"wss://other/ws"}]',
      defaultHubUrl: hub,
    );
    expect(result.memberships.single.hubUrl, 'wss://other/ws');
  });

  test('malformed entries warn loudly and are skipped, valid ones join', () {
    final result = parseDapEnvChannels(
      '[{"pub":"P"},{"channel":"ok"},42]',
      defaultHubUrl: hub,
    );
    expect(result.memberships.map((m) => m.channelId), ['ok']);
    expect(result.warnings, hasLength(2));
    expect(result.warnings[0], contains('missing "channel"'));
    expect(result.warnings[1], contains('not an object'));
  });

  test('entry without any hub is skipped with a warning, never guessed', () {
    final result = parseDapEnvChannels('[{"channel":"x"}]');
    expect(result.memberships, isEmpty);
    expect(result.warnings.single, contains('no hubUrl'));
  });

  test('garbage JSON and non-list shapes degrade to one loud warning', () {
    expect(parseDapEnvChannels('{oops').warnings, hasLength(1));
    expect(parseDapEnvChannels('{"channel":"x"}').warnings, hasLength(1));
    expect(parseDapEnvChannels('{oops').memberships, isEmpty);
  });
}
