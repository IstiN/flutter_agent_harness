// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/hub/dap_invite_import.dart';
import 'package:flutter_agent_harness/src/hub/dap_key_envelope.dart';
import 'package:flutter_agent_harness/src/hub/dap_membership.dart';
import 'package:test/test.dart';

import '../../bin/fah_dap_scoped.dart';

final class _FakeKeychain implements DapChannelKeychain {
  final Map<String, String> items = {};
  var reads = 0;
  var writes = 0;

  @override
  Future<String?> read(String item) async {
    reads++;
    return items[item];
  }

  @override
  Future<void> write(String item, String passphrase) async {
    writes++;
    items[item] = passphrase;
  }
}

void main() {
  const hub = 'wss://hub.fa1.dev/ws';
  const pub = 'AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA';
  const priv = 'A0IDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA';
  const pass = 'ci-secret-passphrase';
  const hubSecret = 'hub-client-secret-value';
  const item = 'fa.dap.channel-key.hub.fa1.dev.team';

  late Directory tmp;
  late List<Map<String, Object?>> sessionRecords;
  late _FakeKeychain keychain;

  DapScopedMemberships service({
    Map<String, String>? env,
    DapPassphrasePrompt? prompt,
    bool useKeychain = true,
  }) => DapScopedMemberships(
    globalConfigFile: '${tmp.path}/.dap/config.json',
    globalChannelsFile: '${tmp.path}/.dap/channels.json',
    overlayChannelsFile: '${tmp.path}/.dap/runtime/overlay.json',
    projectFile: '${tmp.path}/proj/.fah/dap.json',
    environment: env ?? const {},
    keychain: useKeychain ? keychain : null,
    passphrasePrompt: prompt,
    appendSessionRecord: (type, data) async {
      sessionRecords.add(Map<String, Object?>.from(data));
    },
    readSessionRecords: (type) async => sessionRecords,
  );

  final invite = DapInviteImport(
    hubUrl: hub,
    channel: 'team',
    pub: pub,
    priv: priv,
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dap-passphrase-test');
    sessionRecords = [];
    keychain = _FakeKeychain();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('import auto-provisions a random Keychain passphrase without a '
      'prompt and encrypts every new secret', () async {
    var prompts = 0;
    final s = service(
      prompt: (hubUrl, channelId) async {
        prompts++;
        return (passphrase: 'must-not-be-used', save: false);
      },
    );

    final outcome = await s.join(
      invite,
      DapChannelScope.session,
      hubClientSecret: hubSecret,
    );

    expect(prompts, 0);
    expect(keychain.writes, 1);
    expect(keychain.items.keys, [item]);
    final generated = keychain.items[item]!;
    expect(base64Url.decode(base64Url.normalize(generated)), hasLength(32));
    expect(generated, isNot(endsWith('=')));
    expect(outcome.warnings, isEmpty);

    final record = sessionRecords.single;
    final storedPriv = record['priv']! as String;
    final storedSecret = record['hubClientSecret']! as String;
    expect(storedPriv, startsWith('dapkey1.'));
    expect(storedSecret, startsWith('dapkey1.'));
    expect(await decryptChannelPriv(storedPriv, generated), priv);
    expect(await decryptChannelPriv(storedSecret, generated), hubSecret);
    expect(jsonEncode(record), isNot(contains(priv)));
    expect(jsonEncode(record), isNot(contains(hubSecret)));
  });

  test('a second run decrypts with the auto-provisioned Keychain item, '
      'without prompting or replacing it', () async {
    await service().join(
      invite,
      DapChannelScope.session,
      hubClientSecret: hubSecret,
    );
    final generated = keychain.items[item]!;
    expect(keychain.writes, 1);

    var prompts = 0;
    final resumed = service(
      prompt: (hubUrl, channelId) async {
        prompts++;
        return null;
      },
    );
    final runtime = await resumed.runtimeEffective();

    expect(runtime.single.priv, priv);
    expect(runtime.single.hubClientSecret, hubSecret);
    expect(prompts, 0);
    expect(keychain.writes, 1);
    expect(keychain.items[item], generated);
    expect(resumed.loadWarnings, isEmpty);
  });

  test('decrypting with a missing Keychain item still prompts and never '
      'auto-creates a replacement passphrase', () async {
    await service(
      env: {'DAP_KEY_PASSPHRASE': pass},
    ).join(invite, DapChannelScope.session);
    expect(keychain.items, isEmpty);

    var prompts = 0;
    final resumed = service(
      prompt: (hubUrl, channelId) async {
        prompts++;
        expect(hubUrl, hub);
        expect(channelId, 'team');
        return (passphrase: pass, save: false);
      },
    );
    final runtime = await resumed.runtimeEffective();

    expect(runtime.single.priv, priv);
    expect(prompts, 1);
    expect(keychain.writes, 0);
    expect(keychain.items, isEmpty);
  });

  test(
    'DAP_KEY_PASSPHRASE wins over Keychain and import auto-provisioning',
    () async {
      keychain.items[item] = 'a-different-keychain-passphrase';
      var prompts = 0;
      final s = service(
        env: {'DAP_KEY_PASSPHRASE': pass},
        prompt: (hubUrl, channelId) async {
          prompts++;
          return null;
        },
      );

      await s.join(invite, DapChannelScope.session);
      final runtime = await s.runtimeEffective();

      expect(runtime.single.priv, priv);
      expect(prompts, 0);
      expect(keychain.reads, 0, reason: 'env is the first resolution step');
      expect(keychain.writes, 0);
      expect(keychain.items[item], 'a-different-keychain-passphrase');
      final storedPriv = sessionRecords.single['priv']! as String;
      expect(await decryptChannelPriv(storedPriv, pass), priv);
    },
  );

  test(
    'without a Keychain, import keeps the interactive prompt fallback',
    () async {
      var prompts = 0;
      final s = service(
        useKeychain: false,
        prompt: (hubUrl, channelId) async {
          prompts++;
          return (passphrase: pass, save: true);
        },
      );

      await s.join(invite, DapChannelScope.session);

      expect(prompts, 1);
      expect(keychain.writes, 0);
      final storedPriv = sessionRecords.single['priv']! as String;
      expect(storedPriv, startsWith('dapkey1.'));
      expect(await decryptChannelPriv(storedPriv, pass), priv);
    },
  );

  test('headless import without Keychain or prompt stays memory-only and '
      'prints recovery without exposing secrets', () async {
    final s = service(useKeychain: false);

    final outcome = await s.join(
      invite,
      DapChannelScope.session,
      hubClientSecret: hubSecret,
    );

    expect(outcome.warnings, hasLength(2));
    for (final warning in outcome.warnings) {
      expect(warning, contains('memory only'));
      expect(
        warning,
        contains('re-paste the original invite / fa dap import block'),
      );
      expect(warning, contains('fresh passphrase'));
      expect(warning, contains('DAP_KEY_PASSPHRASE'));
      expect(warning, isNot(contains(priv)));
      expect(warning, isNot(contains(hubSecret)));
    }
    expect(sessionRecords.single.containsKey('priv'), isFalse);
    expect(sessionRecords.single.containsKey('hubClientSecret'), isFalse);
    final runtime = await s.runtimeEffective();
    expect(runtime.single.priv, priv);
    expect(runtime.single.hubClientSecret, hubSecret);
  });

  test(
    'missing decryption passphrase warns with recovery and no secrets',
    () async {
      await service(
        env: {'DAP_KEY_PASSPHRASE': pass},
      ).join(invite, DapChannelScope.session);

      final resumed = service(useKeychain: false);
      final runtime = await resumed.runtimeEffective();

      expect(runtime.single.priv, isNull);
      final warning = resumed.loadWarnings.single;
      expect(warning, contains('no passphrase'));
      expect(
        warning,
        contains('re-paste the original invite / fa dap import block'),
      );
      expect(warning, contains('fresh passphrase'));
      expect(warning, contains('DAP_KEY_PASSPHRASE'));
      expect(warning, isNot(contains(priv)));
      expect(warning, isNot(contains(pass)));
    },
  );

  test('failed decryption warns with recovery and no secret values', () async {
    const wrongPass = 'incorrect-user-secret';
    await service(
      env: {'DAP_KEY_PASSPHRASE': pass},
    ).join(invite, DapChannelScope.session);

    final resumed = service(env: {'DAP_KEY_PASSPHRASE': wrongPass});
    final runtime = await resumed.runtimeEffective();

    expect(runtime.single.priv, isNull);
    final warning = resumed.loadWarnings.single;
    expect(warning, contains('wrong passphrase'));
    expect(
      warning,
      contains('re-paste the original invite / fa dap import block'),
    );
    expect(warning, contains('fresh passphrase'));
    expect(warning, contains('DAP_KEY_PASSPHRASE'));
    expect(warning, isNot(contains(priv)));
    expect(warning, isNot(contains(pass)));
    expect(warning, isNot(contains(wrongPass)));
  });
}
