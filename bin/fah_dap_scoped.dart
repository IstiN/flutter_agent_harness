/// Scoped DAP channel membership service (issue #1825): the union of
/// session / project / global / env stores, per-scope join & leave, the
/// passphrase→Keychain resolution chain, and the runtime overlay that
/// feeds the vendored hub client without touching its package.
///
/// Lives in `bin/` (dart:io): file stores and the macOS `security` CLI.
/// The pure algebra (records, union, parser, envelope) is in
/// `lib/src/hub/`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fa_hub_client/fa_hub_client.dart' as client;
import 'package:flutter_agent_harness/src/hub/dap_env_channels.dart';
import 'package:flutter_agent_harness/src/hub/dap_invite_import.dart';
import 'package:flutter_agent_harness/src/hub/dap_key_envelope.dart';
import 'package:flutter_agent_harness/src/hub/dap_membership.dart';
import 'package:flutter_agent_harness/src/plugins/plugin.dart'
    show PluginAppendSessionRecord, PluginReadSessionRecords;

/// The session custom-record type for session-scoped membership. Join
/// records carry the membership payload; leave records add `op: leave`
/// (the session tree is append-only — a leave is a tombstone).
const dapMembershipRecordType = 'dap_channel_membership';

/// The OS-secret-store seam for channel passphrases. Items are unique
/// per channel: `fa.dap.channel-key.<hubHost>.<channelId>` (AC13).
abstract interface class DapChannelKeychain {
  /// Reads the passphrase for [item], or null when absent/unavailable.
  Future<String?> read(String item);

  /// Saves [passphrase] under [item] (best-effort; failures are warnings,
  /// never a join blocker).
  Future<void> write(String item, String passphrase);
}

/// The per-channel Keychain item name (hub host included so the same
/// channel id on two hubs never collides).
String dapChannelKeychainItem(String hubUrl, String channelId) {
  final host = Uri.tryParse(hubUrl)?.host ?? hubUrl;
  return 'fa.dap.channel-key.$host.$channelId';
}

/// macOS Keychain via the `security` CLI (first-class backend of the
/// card; Linux CI uses the env path instead — no Keychain dependency).
final class MacOsDapChannelKeychain implements DapChannelKeychain {
  const MacOsDapChannelKeychain();

  @override
  Future<String?> read(String item) async {
    try {
      final result = await Process.run('security', [
        'find-generic-password',
        '-s',
        item,
        '-w',
      ]);
      if (result.exitCode != 0) return null;
      final value = (result.stdout as String).trim();
      return value.isEmpty ? null : value;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String item, String passphrase) async {
    await Process.run('security', [
      'add-generic-password',
      '-U',
      '-s',
      item,
      '-a',
      'fa',
      '-w',
      passphrase,
    ]);
  }
}

/// Interactive passphrase prompt: returns the passphrase, or null on
/// cancel. [offerSave] mirrors the "save to Keychain (default)" choice —
/// returning null save means "do not save".
typedef DapPassphrasePrompt =
    Future<({String passphrase, bool save})?> Function(
      String hubUrl,
      String channelId,
    );

/// One join/leave operation's human-facing outcome.
final class DapScopedOutcome {
  const DapScopedOutcome(this.membership, this.warnings);

  /// The effective membership after the operation (null for a leave).
  final DapChannelMembership? membership;

  /// Loud one-line warnings (passphrase fallback, hub-down, keychain
  /// write failure) — never silent.
  final List<String> warnings;
}

/// The scoped membership store + runtime overlay manager.
final class DapScopedMemberships {
  DapScopedMemberships({
    required this.globalConfigFile,
    required this.globalChannelsFile,
    required this.overlayChannelsFile,
    this.projectFile,
    Map<String, String>? environment,
    this.appendSessionRecord,
    this.readSessionRecords,
    this.passphrasePrompt,
    this.keychain,
    DateTime Function()? now,
  }) : environment = environment ?? Platform.environment,
       _now = now ?? (() => DateTime.now().toUtc());

  /// `~/.dap/config.json` (legacy global room list + hub url).
  final String globalConfigFile;

  /// `~/.dap/channels.json` (legacy global channel key registry).
  final String globalChannelsFile;

  /// The RUNTIME channel-key file the vendored hub client is pointed at
  /// (via `DAP_CHANNELS_FILE`): seeded with the decrypted union at boot,
  /// it absorbs the client's own key writes so scoped joins never leak
  /// into the legacy global file. 0600, outside the repo.
  final String overlayChannelsFile;

  /// `<project>/.fah/dap.json` — MAY be committed (encrypted keys only).
  final String? projectFile;

  final Map<String, String> environment;
  final PluginAppendSessionRecord? appendSessionRecord;
  final PluginReadSessionRecords? readSessionRecords;

  /// Interactive prompt (null on headless — then NO prompts ever).
  final DapPassphrasePrompt? passphrasePrompt;

  /// OS secret store (macOS Keychain); null disables that chain step.
  final DapChannelKeychain? keychain;

  final DateTime Function() _now;

  /// Lazily loaded union (invalidated on every mutation).
  DapMembershipUnion? _union;

  /// Plaintext keys that could not be persisted (no passphrase anywhere
  /// in the chain): kept ONLY in memory for this run — never on disk.
  final Map<String, String> _memoryOnlyKeys = {};

  /// Hub client secrets that could not be encrypted at rest (no
  /// passphrase) or belong to the legacy GLOBAL scope (whose files have
  /// no per-hub credential field) — memory only, with a loud warning.
  final Map<String, String> _memoryOnlySecrets = {};

  /// Loud warnings from the last load (bad passphrase, malformed store).
  final List<String> loadWarnings = [];

  /// The membership identity url: the strict invite parser keeps the
  /// `?channel=` query in hubUrl, but a bare-id join on the same hub
  /// must dedup/leave against the SAME key — strip it everywhere.
  static String normalizeHubUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final params = Map<String, String>.from(uri.queryParameters)
      ..remove('channel');
    return uri
        .replace(queryParameters: params.isEmpty ? null : params)
        .toString();
  }

  String? get _envPassphrase {
    final value = environment['DAP_KEY_PASSPHRASE'];
    return value == null || value.isEmpty ? null : value;
  }

  String get _configuredHubUrl {
    final config = client.readDapConfig(globalConfigFile);
    final url = config['url'];
    if (url is String && url.isNotEmpty) return normalizeHubUrl(url);
    final envUrl = environment['DAP_HUB_URL'];
    if (envUrl != null && envUrl.isNotEmpty) return normalizeHubUrl(envUrl);
    return client.defaultDapUrl;
  }

  /// The hub a bare channel id joins on (the `/network` parser input).
  String get defaultHubUrl => _configuredHubUrl;

  /// The hub the LIVE connection should dial for the effective
  /// memberships: when the configured hub is just the zero-config local
  /// default and memberships point elsewhere (the usual invite flow),
  /// the most recently joined membership's hub wins. An EXPLICITLY
  /// configured hub is always respected (null = keep it).
  Future<String?> preferredBootHub() async {
    final effective = await union().then((u) => u.effective());
    if (effective.isEmpty) return null;
    if (_configuredHubUrl != client.defaultDapUrl) return null;
    var latest = effective.first;
    for (final m in effective.skip(1)) {
      if (m.joinedAt.isAfter(latest.joinedAt)) latest = m;
    }
    return latest.hubUrl;
  }

  // ---- loading ----

  /// Loads (or returns the cached) union of every scope + the env layer.
  Future<DapMembershipUnion> union() async {
    final cached = _union;
    if (cached != null) return cached;
    loadWarnings.clear();
    final all = <DapChannelMembership>[
      ...await _loadGlobal(),
      ...await _loadProject(),
      ...await _loadSession(),
      ..._loadEnv(),
    ];
    return _union = DapMembershipUnion(all);
  }

  Future<List<DapChannelMembership>> _loadGlobal() async {
    final config = client.readDapConfig(globalConfigFile);
    final rooms = [
      for (final c in (config['channels'] as List? ?? const []))
        if (c is String && c.isNotEmpty) c,
    ];
    return _loadLegacyKeys(globalChannelsFile, rooms, _configuredHubUrl);
  }

  /// The legacy global shape: room names from config + the key registry
  /// (both are auto-joined by the vendored client today).
  Future<List<DapChannelMembership>> _loadLegacyKeys(
    String file,
    List<String> rooms,
    String hubUrl,
  ) async {
    final keys = await client.loadChannelKeys(file);
    final names = {...rooms, ...keys.keys};
    return [
      for (final name in names)
        DapChannelMembership(
          hubUrl: hubUrl,
          channelId: name,
          scope: DapChannelScope.global,
          joinedAt: _now(),
          pub: keys[name]?.pub,
          priv: keys[name]?.priv,
        ),
    ];
  }

  Future<List<DapChannelMembership>> _loadProject() async {
    final file = projectFile;
    if (file == null) return const [];
    try {
      final raw = await File(file).readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const [];
      final list = decoded['channels'];
      if (list is! List) return const [];
      return [
        for (final entry in list)
          if (entry is Map)
            DapChannelMembership.fromJson(
              entry.cast<String, Object?>(),
            ).withScope(DapChannelScope.project),
      ];
    } on Object {
      return const [];
    }
  }

  /// Session records fold in order: join adds, `op: leave` tombstones
  /// remove (E1/E5 — branch-scoped, append-only).
  Future<List<DapChannelMembership>> _loadSession() async {
    final read = readSessionRecords;
    if (read == null) return const [];
    final records = await read(dapMembershipRecordType);
    final byKey = <String, DapChannelMembership>{};
    for (final data in records) {
      try {
        if (data['op'] == 'leave') {
          byKey.remove('${data['hubUrl']}\n${data['channelId']}');
          continue;
        }
        final membership = DapChannelMembership.fromJson(
          data,
        ).withScope(DapChannelScope.session);
        byKey[membership.key] = membership;
      } on Object {
        loadWarnings.add('dap: skipped a malformed session membership');
      }
    }
    return byKey.values.toList();
  }

  List<DapChannelMembership> _loadEnv() {
    final result = parseDapEnvChannels(
      environment['DAP_CHANNELS_JSON'],
      defaultHubUrl: environment['DAP_HUB_URL'],
      joinedAt: _now(),
    );
    loadWarnings.addAll(result.warnings);
    return result.memberships;
  }

  // ---- passphrases ----

  /// The resolution chain (AC13/AC14): env → per-channel Keychain → ONE
  /// interactive prompt (save-to-Keychain default). Headless without env
  /// and Keychain returns null — the caller proceeds with a loud warning
  /// and never prompts.
  Future<String?> _resolvePassphrase(String hubUrl, String channelId) async {
    final env = _envPassphrase;
    if (env != null) return env;
    final item = dapChannelKeychainItem(hubUrl, channelId);
    final stored = await keychain?.read(item);
    if (stored != null && stored.isNotEmpty) return stored;
    final prompt = passphrasePrompt;
    if (prompt == null) return null;
    final answer = await prompt(hubUrl, channelId);
    if (answer == null || answer.passphrase.isEmpty) return null;
    if (answer.save && keychain != null) {
      try {
        await keychain!.write(item, answer.passphrase);
      } on Object {
        loadWarnings.add('dap: could not save the passphrase to Keychain');
      }
    }
    return answer.passphrase;
  }

  /// Decrypts a stored priv for the runtime union. Plaintext passes
  /// through (pure-env path); an undecryptable envelope warns and drops
  /// the key material (membership stays — rejoin can fix it).
  Future<String?> _runtimePriv(DapChannelMembership m) =>
      _runtimeSecret(m, m.priv);

  Future<String?> _runtimeSecret(DapChannelMembership m, String? stored) async {
    final priv = stored;
    if (priv == null) return null;
    if (!isEncryptedChannelPriv(priv)) return priv;
    final passphrase = await _resolvePassphrase(m.hubUrl, m.channelId);
    if (passphrase == null) {
      loadWarnings.add(
        'dap: #${m.channelId} key is encrypted but no passphrase is '
        'available (DAP_KEY_PASSPHRASE / Keychain) — joined without keys',
      );
      return null;
    }
    try {
      return await decryptChannelPriv(priv, passphrase);
    } on FormatException catch (e) {
      loadWarnings.add('dap: #${m.channelId}: ${e.message}');
      return null;
    }
  }

  // ---- runtime overlay ----

  /// Rewrites the runtime overlay with the union's decrypted keys and
  /// returns the effective memberships (for the live join loop).
  Future<List<DapChannelMembership>> seedOverlay() async {
    final effective = await union().then((u) => u.effective());
    final keys = <String, Map<String, String>>{};
    for (final m in effective) {
      final priv = await _runtimePriv(m);
      final pub = m.pub;
      if (priv != null && pub != null) {
        keys[m.channelId] = {'pub': pub, 'priv': priv};
      }
    }
    await _writeJsonAtomic(overlayChannelsFile, keys, mode0600: true);
    return effective;
  }

  /// Drops the cached union (session records arrive AFTER the boot
  /// overlay seed — the first drain must re-read them, AC3).
  void invalidateCache() => _union = null;

  /// The effective union with DECRYPTED key material, for the live
  /// client join loop (plaintext exists only in memory / the runtime
  /// overlay). Undecryptable channels stay joined keyless with a loud
  /// warning (primary job proceeds).
  Future<List<DapChannelMembership>> runtimeEffective() async {
    final effective = await union().then((u) => u.effective());
    return [
      for (final m in effective)
        DapChannelMembership(
          hubUrl: m.hubUrl,
          channelId: m.channelId,
          scope: m.scope,
          joinedAt: m.joinedAt,
          pub: m.pub,
          priv: m.priv != null ? await _runtimePriv(m) : _memoryOnlyKeys[m.key],
          agentName: m.agentName,
          hubClientSecret: m.hubClientSecret != null
              ? await _runtimeSecret(m, m.hubClientSecret)
              : _memoryOnlySecrets[m.key],
        ),
    ];
  }

  /// The membership the LIVE boot connection should dial, decrypted
  /// credentials included: same rule as [preferredBootHub] (only when
  /// the configured hub is the zero-config local default), but carries
  /// the enrolled agent name + hub client secret so a name-bound
  /// credential actually authenticates after a restart.
  Future<DapChannelMembership?> preferredBootMembership() async {
    final effective = await runtimeEffective();
    if (effective.isEmpty) return null;
    if (_configuredHubUrl != client.defaultDapUrl) return null;
    var latest = effective.first;
    for (final m in effective.skip(1)) {
      if (m.joinedAt.isAfter(latest.joinedAt)) latest = m;
    }
    return latest;
  }

  /// Whether inbound frames for `(hubUrl, channelId)` should still reach
  /// the agent — the live LEAVE filter (AC4): leaving the last scope
  /// stops delivery immediately, before the next boot's re-seed.
  Future<bool> acceptsChannel(String hubUrl, String channelId) async {
    final effective = await union().then((u) => u.effective());
    return effective.any((m) => m.hubUrl == hubUrl && m.channelId == channelId);
  }

  // ---- join / leave ----

  /// Joins [invite] at [scope] and persists per the scope's rules:
  /// session → custom record (encrypted priv), project → `.fah/dap.json`
  /// (encrypted priv, committable), global → the legacy `~/.dap` files
  /// (unchanged mechanism, `fa dap import` semantics).
  Future<DapScopedOutcome> join(
    DapInviteImport invite,
    DapChannelScope scope, {
    String? agentName,
    String? hubClientSecret,
  }) async {
    final warnings = <String>[];
    var membership = DapChannelMembership(
      hubUrl: normalizeHubUrl(invite.hubUrl),
      channelId: invite.channel,
      scope: scope,
      joinedAt: _now(),
      pub: invite.pub,
      priv: invite.priv,
      agentName: agentName,
      hubClientSecret: hubClientSecret,
    );

    if (scope == DapChannelScope.global) {
      // The legacy global import path (byte-equivalent effective
      // membership with `fa dap import`, REG-*).
      final priv = invite.priv;
      if (invite.pub != null && priv != null) {
        await client.persistChannelKeys(
          globalChannelsFile,
          invite.channel,
          client.ChannelKeys(pub: invite.pub!, priv: priv),
        );
      }
      await client.persistDapConfig(
        channels: [invite.channel],
        file: globalConfigFile,
      );
      final config = client.readDapConfig(globalConfigFile);
      if (config['url'] is! String || (config['url'] as String).isEmpty) {
        await client.persistDapConfig(
          url: invite.hubUrl,
          file: globalConfigFile,
        );
      }
      if (hubClientSecret != null) {
        // The legacy global files carry ONE clientSecret for the default
        // hub — writing a foreign hub's name-bound credential there
        // would break the default connection. Memory only, honestly.
        _memoryOnlySecrets[membership.key] = hubClientSecret;
        warnings.add(
          'dap: hub credential for #${invite.channel} is kept in memory '
          'only at global scope — after a restart re-paste the DAP block '
          'or export DAP_CLIENT_SECRET / DAP_AGENT_NAME',
        );
      }
    } else {
      // Encrypted-at-rest for session/project (v3): no passphrase → the
      // key stays in MEMORY for this run, never plaintext on disk.
      var storedPriv = invite.priv;
      var storedSecret = hubClientSecret;
      if (storedPriv != null || storedSecret != null) {
        final passphrase = await _resolvePassphrase(
          invite.hubUrl,
          invite.channel,
        );
        if (passphrase == null) {
          if (storedPriv != null) {
            warnings.add(
              'dap: no passphrase (DAP_KEY_PASSPHRASE / Keychain / prompt) — '
              '#${invite.channel} key is kept in memory only this run',
            );
            _memoryOnlyKeys[membership.key] = invite.priv!;
            storedPriv = null;
          }
          if (storedSecret != null) {
            warnings.add(
              'dap: no passphrase — the hub credential for '
              '#${invite.channel} is kept in memory only this run',
            );
            _memoryOnlySecrets[membership.key] = storedSecret;
            storedSecret = null;
          }
        } else {
          if (storedPriv != null) {
            storedPriv = await encryptChannelPriv(storedPriv, passphrase);
          }
          if (storedSecret != null) {
            storedSecret = await encryptChannelPriv(storedSecret, passphrase);
          }
        }
      }
      final stored = DapChannelMembership(
        hubUrl: membership.hubUrl,
        channelId: membership.channelId,
        scope: scope,
        joinedAt: membership.joinedAt,
        pub: membership.pub,
        priv: storedPriv,
        agentName: agentName,
        hubClientSecret: storedSecret,
      );
      if (scope == DapChannelScope.session) {
        final append = appendSessionRecord;
        if (append != null) {
          await append(dapMembershipRecordType, stored.toJson());
        }
      } else {
        await _projectJoin(stored);
      }
      membership = stored;
    }
    _union = null;
    return DapScopedOutcome(membership, warnings);
  }

  Future<void> _projectJoin(DapChannelMembership membership) async {
    final file = projectFile;
    if (file == null) return;
    final existing = await _loadProject();
    final byKey = {for (final m in existing) m.key: m};
    byKey[membership.key] = membership;
    await _writeJsonAtomic(file, {
      'channels': [for (final m in byKey.values) m.toJson()],
    });
  }

  /// Leaves `(hubUrl, channelId)` at [scope]; other scopes keep the
  /// channel alive (E1). Session leaves are tombstone records.
  Future<void> leave(
    String hubUrl,
    String channelId,
    DapChannelScope scope,
  ) async {
    switch (scope) {
      case DapChannelScope.session:
        final append = appendSessionRecord;
        if (append != null) {
          await append(dapMembershipRecordType, {
            'op': 'leave',
            'hubUrl': hubUrl,
            'channelId': channelId,
          });
        }
      case DapChannelScope.project:
        final file = projectFile;
        if (file != null) {
          final existing = await _loadProject();
          await _writeJsonAtomic(file, {
            'channels': [
              for (final m in existing)
                if (!(m.hubUrl == hubUrl && m.channelId == channelId))
                  m.toJson(),
            ],
          });
        }
      case DapChannelScope.global:
        await _globalLeave(hubUrl, channelId);
    }
    _union = null;
  }

  Future<void> _globalLeave(String hubUrl, String channelId) async {
    // Config room list: read-modify-write (the persist helper only adds).
    final config = client.readDapConfig(globalConfigFile);
    final rooms = [
      for (final c in (config['channels'] as List? ?? const []))
        if (c is String && c != channelId) c,
    ];
    config['channels'] = rooms;
    await _writeJsonAtomic(globalConfigFile, config, mode0600: true);
    // Key registry: dropping the key stops the legacy auto-join too.
    final keys = await client.loadChannelKeys(globalChannelsFile);
    keys.remove(channelId);
    await _writeJsonAtomic(globalChannelsFile, {
      for (final entry in keys.entries)
        entry.key: {'pub': entry.value.pub, 'priv': entry.value.priv},
    }, mode0600: true);
  }

  /// The invite string for `copy invite` (E6): private channels with a
  /// keypair reproduce the app form; keyless/public produces the bare
  /// URL. Encrypted stored privs are decrypted for the copy (the user
  /// explicitly exports the secret) — or the copy fails loudly.
  Future<String> copyInvite(DapChannelMembership membership) async {
    final base = membership.hubUrl.contains('channel=')
        ? membership.hubUrl
        : '${membership.hubUrl}${membership.hubUrl.contains('?') ? '&' : '?'}channel=${membership.channelId}';
    final priv = await _runtimePriv(membership);
    final pub = membership.pub;
    if (priv != null && pub != null) {
      return '$base#pub=$pub&priv=$priv';
    }
    return base;
  }

  // ---- io helpers ----

  static Future<void> _writeJsonAtomic(
    String file,
    Object? value, {
    bool mode0600 = false,
  }) async {
    final target = File(file);
    final parent = target.parent;
    if (!await parent.exists()) await parent.create(recursive: true);
    final tmp = File('$file.tmp');
    await tmp.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(value)}\n',
      flush: true,
    );
    await tmp.rename(file);
    if (mode0600) {
      try {
        await Process.run('chmod', ['600', file]);
      } on Object {
        // No chmod here: keep the content, keep the umask mode.
      }
    }
  }
}
