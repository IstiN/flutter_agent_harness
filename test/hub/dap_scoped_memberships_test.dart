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
  var writes = 0;

  @override
  Future<String?> read(String item) async => items[item];

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

  late Directory tmp;
  late String globalConfig;
  late String globalChannels;
  late String overlay;
  late String projectFile;
  late List<Map<String, Object?>> sessionRecords;
  late _FakeKeychain keychain;

  DapScopedMemberships service({
    Map<String, String>? env,
    DapPassphrasePrompt? prompt,
    String? project,
    bool useKeychain = true,
  }) => DapScopedMemberships(
    globalConfigFile: globalConfig,
    globalChannelsFile: globalChannels,
    overlayChannelsFile: overlay,
    projectFile: project ?? projectFile,
    environment: env ?? const {},
    keychain: useKeychain ? keychain : null,
    passphrasePrompt: prompt,
    appendSessionRecord: (type, data) async {
      sessionRecords.add(Map<String, Object?>.from(data));
    },
    readSessionRecords: (type) async => sessionRecords,
  );

  DapInviteImport invite({String channel = 'team', bool keys = true}) =>
      DapInviteImport(
        hubUrl: hub,
        channel: channel,
        pub: keys ? pub : null,
        priv: keys ? priv : null,
      );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dap-scoped-test');
    globalConfig = '${tmp.path}/.dap/config.json';
    globalChannels = '${tmp.path}/.dap/channels.json';
    overlay = '${tmp.path}/.dap/runtime/overlay.json';
    projectFile = '${tmp.path}/proj/.fah/dap.json';
    sessionRecords = [];
    keychain = _FakeKeychain();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('AC8/AC14: session+project joins store ENCRYPTED priv, runtime '
      'decrypts, no plaintext key bytes in any stored file', () async {
    final env = {'DAP_KEY_PASSPHRASE': pass, 'DAP_HUB_URL': hub};
    final s = service(env: env);
    await s.join(invite(), DapChannelScope.session);
    await s.join(invite(), DapChannelScope.project);

    // Session record carries a dapkey1 envelope, not the plaintext key.
    expect(sessionRecords, hasLength(1));
    final storedPriv = sessionRecords.single['priv']! as String;
    expect(isEncryptedChannelPriv(storedPriv), isTrue);
    expect(storedPriv, isNot(contains(priv)));

    // Project file likewise (committable).
    final projectRaw = await File(projectFile).readAsString();
    expect(projectRaw.contains(priv), isFalse);
    expect(projectRaw.contains('dapkey1.'), isTrue);

    // Union dedups session+project to ONE effective membership.
    final effective = await s.union().then((u) => u.effective());
    expect(effective, hasLength(1));

    // Runtime sees the decrypted key; overlay is the only plaintext file
    // and lives outside the project (0600 runtime artifact).
    final runtime = await s.runtimeEffective();
    expect(runtime.single.priv, priv);
    await s.seedOverlay();
    final overlayRaw = await File(overlay).readAsString();
    expect(jsonDecode(overlayRaw)['team']['priv'], priv);
  });

  test('AC2: project scope is invisible from a sibling folder; session '
      'scope is invisible to a second CLI (different records)', () async {
    final env = {'DAP_KEY_PASSPHRASE': pass};
    await service(env: env).join(invite(), DapChannelScope.project);
    await service(
      env: env,
    ).join(invite(channel: 'mine'), DapChannelScope.session);

    final sibling = service(
      env: env,
      project: '${tmp.path}/other/.fah/dap.json',
    );
    final siblingChannels = await sibling.union().then((u) => u.effective());
    // Same session records, different folder: the project channel must
    // NOT leak; only the session membership is visible.
    expect(siblingChannels.map((m) => m.channelId), ['mine']);

    // A second CLI in the same folder sees the project channel but not
    // the session one (its session records differ).
    final otherRecords = <Map<String, Object?>>[];
    final second = DapScopedMemberships(
      globalConfigFile: globalConfig,
      globalChannelsFile: globalChannels,
      overlayChannelsFile: overlay,
      projectFile: projectFile,
      environment: env,
      readSessionRecords: (type) async => otherRecords,
    );
    final channels = await second.union().then((u) => u.effective());
    expect(channels.map((m) => m.channelId), ['team']);
  });

  test('AC4/E1: leave(session) keeps project; leaving the last scope '
      'stops delivery (acceptsChannel=false)', () async {
    final env = {'DAP_KEY_PASSPHRASE': pass};
    final s = service(env: env);
    await s.join(invite(), DapChannelScope.session);
    await s.join(invite(), DapChannelScope.project);
    expect(await s.acceptsChannel(hub, 'team'), isTrue);

    await s.leave(hub, 'team', DapChannelScope.session);
    expect((await s.union()).effective().single.scope, DapChannelScope.project);
    expect(await s.acceptsChannel(hub, 'team'), isTrue);

    await s.leave(hub, 'team', DapChannelScope.project);
    expect(await s.acceptsChannel(hub, 'team'), isFalse);
    expect((await s.union()).effective(), isEmpty);
  });

  test('AC3: session resume folds join/leave tombstones in order', () async {
    final env = {'DAP_KEY_PASSPHRASE': pass};
    final s = service(env: env);
    await s.join(invite(), DapChannelScope.session);
    await s.leave(hub, 'team', DapChannelScope.session);
    await s.join(invite(), DapChannelScope.session);

    // A fresh service over the SAME records (the resume) sees exactly
    // the final state.
    final resumed = service(env: env);
    final effective = await resumed.union().then((u) => u.effective());
    expect(effective.map((m) => m.channelId), ['team']);
  });

  test('global join uses the legacy ~/.dap files (REG: fa dap import '
      'semantics) and global leave stops legacy auto-join', () async {
    final s = service();
    await s.join(invite(), DapChannelScope.global);
    final keys = jsonDecode(await File(globalChannels).readAsString());
    expect(keys['team']['priv'], priv);
    final config = jsonDecode(await File(globalConfig).readAsString());
    expect(config['channels'], contains('team'));
    expect(config['url'], hub);

    // The hub url is never clobbered by a later different-hub join (E3).
    await s.join(
      DapInviteImport(hubUrl: 'wss://other/ws', channel: 'x'),
      DapChannelScope.global,
    );
    final config2 = jsonDecode(await File(globalConfig).readAsString());
    expect(config2['url'], hub);

    await s.leave(hub, 'team', DapChannelScope.global);
    final keysAfter = jsonDecode(await File(globalChannels).readAsString());
    expect(keysAfter.containsKey('team'), isFalse);
    final configAfter = jsonDecode(await File(globalConfig).readAsString());
    expect(configAfter['channels'], isNot(contains('team')));
  });

  test('AC13: prompt once with save → later service reads Keychain, no '
      'second prompt; item is per-channel unique', () async {
    var prompts = 0;
    Future<({String passphrase, bool save})?> prompt(
      String hubUrl,
      String channelId,
    ) async {
      prompts++;
      return (passphrase: pass, save: true);
    }

    // Seed the envelope with the env path. Resolving an EXISTING envelope
    // may prompt and save, but must never auto-provision a new passphrase.
    await service(
      env: {'DAP_KEY_PASSPHRASE': pass},
    ).join(invite(), DapChannelScope.session);
    expect(prompts, 0);
    expect(keychain.writes, 0);

    final second = service(prompt: prompt);
    final runtime = await second.runtimeEffective();
    expect(runtime.single.priv, priv);
    expect(prompts, 1);
    expect(keychain.writes, 1);
    expect(keychain.items.keys.single, 'fa.dap.channel-key.hub.fa1.dev.team');

    final third = service(prompt: prompt);
    final resumed = await third.runtimeEffective();
    expect(resumed.single.priv, priv);
    expect(prompts, 1, reason: 'Keychain hit must skip the prompt');
  });

  test(
    'AC15: wrong passphrase → loud warning, keyless join, no throw',
    () async {
      final s = service(env: {'DAP_KEY_PASSPHRASE': pass});
      await s.join(invite(), DapChannelScope.project);
      final wrong = service(env: {'DAP_KEY_PASSPHRASE': 'wrong'});
      final runtime = await wrong.runtimeEffective();
      expect(runtime.single.priv, isNull);
      expect(wrong.loadWarnings.join('\n'), contains('wrong passphrase'));
    },
  );

  test('headless join without any passphrase keeps the key in memory '
      'only — nothing plaintext at rest', () async {
    final s = service(useKeychain: false); // no env, prompt, or Keychain
    final outcome = await s.join(invite(), DapChannelScope.session);
    expect(outcome.warnings.join('\n'), contains('memory only'));
    expect(sessionRecords.single.containsKey('priv'), isFalse);
    expect(jsonEncode(sessionRecords), isNot(contains(priv)));
    final runtime = await s.runtimeEffective();
    expect(runtime.single.priv, priv, reason: 'this run still works');
  });

  test('AC10/AC15: env channels join at boot with plaintext + encrypted '
      'mixed set and no stores touched', () async {
    final env = {
      'DAP_HUB_URL': hub,
      'DAP_KEY_PASSPHRASE': pass,
      'DAP_CHANNELS_JSON':
          '[{"channel":"ci","pub":"$pub","priv":"$priv"},{"channel":"open"}]',
    };
    final s = service(env: env);
    final effective = await s.union().then((u) => u.effective());
    expect(effective.map((m) => m.channelId), containsAll(['ci', 'open']));
    expect(await File(globalConfig).exists(), isFalse);
    final runtime = await s.runtimeEffective();
    expect(runtime.firstWhere((m) => m.channelId == 'ci').priv, priv);
  });

  test('E6: copyInvite round-trips through the parser (private) and '
      'produces the keyless form for public channels', () async {
    final env = {'DAP_KEY_PASSPHRASE': pass};
    final s = service(env: env);
    await s.join(invite(), DapChannelScope.session);
    final copied = await s.copyInvite((await s.union()).effective().single);
    final parsed = parseDapInviteFlexible(copied);
    expect(parsed.channel, 'team');
    expect(parsed.priv, priv);
    expect(parsed.pub, pub);

    await s.join(invite(channel: 'open', keys: false), DapChannelScope.session);
    final publicCopy = await s.copyInvite(
      (await s.union()).effective().firstWhere((m) => m.channelId == 'open'),
    );
    expect(publicCopy.contains('#pub='), isFalse);
    expect(parseDapInviteFlexible(publicCopy).channel, 'open');
  });

  test('dedup: a full-invite join and a bare-id join on the same hub '
      'produce ONE membership (hubUrl channel-query normalization)', () async {
    final env = {'DAP_KEY_PASSPHRASE': pass, 'DAP_HUB_URL': hub};
    final s = service(env: env);
    await s.join(invite(), DapChannelScope.session);
    await s.join(
      parseDapInviteFlexible('team', defaultHubUrl: hub),
      DapChannelScope.session,
    );
    final effective = await s.union().then((u) => u.effective());
    expect(effective, hasLength(1));
    expect(await s.acceptsChannel(hub, 'team'), isTrue);
    await s.leave(hub, 'team', DapChannelScope.session);
    expect(await s.acceptsChannel(hub, 'team'), isFalse);
  });

  test('join with an enrolled hub credential: session store encrypts the '
      'secret, runtime decrypts it, boot membership carries it', () async {
    final s = service(env: {'DAP_KEY_PASSPHRASE': pass});
    await s.join(
      invite(),
      DapChannelScope.session,
      agentName: 'public-agent',
      hubClientSecret: 'hub-secret-1',
    );
    expect(sessionRecords.last['hubClientSecret'], isNot('hub-secret-1'));
    expect(sessionRecords.last['hubClientSecret'], startsWith('dapkey1.'));
    expect(sessionRecords.last['agentName'], 'public-agent');

    final effective = await s.runtimeEffective();
    expect(effective.single.hubClientSecret, 'hub-secret-1');
    expect(effective.single.agentName, 'public-agent');

    final boot = await s.preferredBootMembership();
    expect(boot!.hubUrl, hub);
    expect(boot.hubClientSecret, 'hub-secret-1');
    expect(boot.agentName, 'public-agent');
  });

  test('global scope keeps the hub credential in memory only (legacy '
      'files have no per-hub credential field), with a warning', () async {
    final s = service(env: {'DAP_KEY_PASSPHRASE': pass});
    final outcome = await s.join(
      invite(),
      DapChannelScope.global,
      agentName: 'public-agent',
      hubClientSecret: 'hub-secret-1',
    );
    expect(outcome.warnings.join(' '), contains('memory'));
    expect(
      (await File(globalConfig).readAsString()).contains('hub-secret-1'),
      isFalse,
    );
    expect(
      (await File(globalChannels).readAsString()).contains('hub-secret-1'),
      isFalse,
    );
    final effective = await s.runtimeEffective();
    expect(effective.single.hubClientSecret, 'hub-secret-1');
  });

  test('headless without a passphrase: the credential stays in memory, '
      'never plaintext in the session record', () async {
    final s = service(env: {}, useKeychain: false);
    final outcome = await s.join(
      invite(),
      DapChannelScope.session,
      agentName: 'public-agent',
      hubClientSecret: 'hub-secret-1',
    );
    expect(outcome.warnings.join(' '), contains('memory'));
    expect(sessionRecords.last.containsKey('hubClientSecret'), isFalse);
    expect(sessionRecords.last['agentName'], 'public-agent');
    final effective = await s.runtimeEffective();
    expect(effective.single.hubClientSecret, 'hub-secret-1');
  });

  test('preferredBootHub: a remote membership wins over the zero-config '
      'local default, but never over an explicitly configured hub', () async {
    final env = {'DAP_KEY_PASSPHRASE': pass};
    final s = service(env: env);
    await s.join(invite(), DapChannelScope.session);
    // No configured hub at all → the zero-config default → remote wins.
    expect(await s.preferredBootHub(), hub);

    // An explicitly configured hub is respected.
    final explicit = service(env: {...env, 'DAP_HUB_URL': 'wss://corp/ws'});
    expect(await explicit.preferredBootHub(), isNull);
  });
}
