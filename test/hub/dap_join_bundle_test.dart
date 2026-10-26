// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/src/hub/dap_join_bundle.dart';
import 'package:test/test.dart';

void main() {
  const url = 'wss://hub.fa1.dev/ws?channel=team';
  const secret = 'name-bound-secret-123';

  test('bare invite link still parses, no credential', () {
    final bundle = parseDapJoinBundle(url);
    expect(bundle.invite.channel, 'team');
    expect(bundle.hubUrl, 'wss://hub.fa1.dev/ws?channel=team');
    expect(bundle.clientSecret, isNull);
    expect(bundle.agentName, isNull);
  });

  test('the app one-liner: import && env assignments + trailing fa', () {
    final bundle = parseDapJoinBundle(
      "fa dap import '$url' && DAP_HUB_URL=wss://hub.fa1.dev/ws "
      "DAP_CLIENT_SECRET='$secret' DAP_AGENT_NAME=public-agent fa",
    );
    expect(bundle.invite.channel, 'team');
    expect(bundle.hubUrl, 'wss://hub.fa1.dev/ws');
    expect(bundle.clientSecret, secret);
    expect(bundle.agentName, 'public-agent');
  });

  test('the multi-line DAP tab block (one assignment per line)', () {
    final bundle = parseDapJoinBundle(
      "fa dap import '$url'\n"
      'DAP_HUB_URL=wss://hub.fa1.dev/ws\n'
      'DAP_CLIENT_SECRET=$secret\n'
      'DAP_AGENT_NAME=public-agent\n',
    );
    expect(bundle.invite.channel, 'team');
    expect(bundle.clientSecret, secret);
    expect(bundle.agentName, 'public-agent');
  });

  test('a bare fa dap import command without env works', () {
    final bundle = parseDapJoinBundle("fa dap import '$url'");
    expect(bundle.invite.channel, 'team');
    expect(bundle.clientSecret, isNull);
  });

  test('env assignments without an invite get an actionable error', () {
    expect(
      () => parseDapJoinBundle(
        'DAP_HUB_URL=wss://hub.fa1.dev/ws DAP_CLIENT_SECRET=$secret',
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('fa dap import'),
        ),
      ),
    );
  });

  test('a malformed invite never leaks the secret into the error', () {
    try {
      parseDapJoinBundle(
        "fa dap import 'not-a-uri' && DAP_CLIENT_SECRET='$secret'",
      );
      fail('must throw');
    } on FormatException catch (e) {
      expect(e.message, isNot(contains(secret)));
    }
  });

  test('a private invite keeps its keypair alongside the credential', () {
    const pub = 'mPYg_qOd3TaPxPbOHC-WyELGxnGZvYLK_FCUrzeq4sI';
    const priv = 'yECNq2qELWrZJCKyb1OInyE7TTAQYCN3uEPraw5N-Cc';
    final bundle = parseDapJoinBundle(
      "fa dap import '$url#pub=$pub&priv=$priv' && DAP_CLIENT_SECRET='$secret'",
    );
    expect(bundle.invite.pub, pub);
    expect(bundle.invite.priv, priv);
    expect(bundle.clientSecret, secret);
  });
}
