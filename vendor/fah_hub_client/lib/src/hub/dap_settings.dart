/// Zero-config settings shared by every DAP adapter (same `~/.dap`
/// layout): precedence explicit config (`.fah/packages.yaml` `hub:` section
/// — env wins within that tier, see [HubConfig.fromMap]) > env
/// (`DAP_HUB_URL`/`DAP_KEY_PATH`/`DAP_AGENT_NAME`/`DAP_CHANNELS_FILE`) >
/// `~/.dap/config.json` > defaults.
///
/// Defaults keep onboarding to a single env var: url
/// `ws://127.0.0.1:8787/ws`, identity `~/.dap/keys/fah/<name|hostname>.key`
/// (auto-generated 0600 on first use — a second agent on the machine needs
/// nothing but `DAP_AGENT_NAME`), channels file `~/.dap/channels.json`
/// (machine-shared with the other adapters).
library;

import 'dart:convert';
import 'dart:io';

import 'hub_config.dart';

/// Optional persisted settings: `~/.dap/config.json` (all fields optional).
class DapSettings {
  const DapSettings({
    required this.url,
    required this.keyPath,
    required this.channelsFile,
    this.name,
  });

  final String url;
  final String keyPath;
  final String channelsFile;
  final String? name;
}

/// A pending by-name invite in the machine-shared `~/.dap/config.json`
/// (`invites: [{name, channel}]`): armed by `dap_invite <name>` for a
/// user not yet on the hub, removed once the chankey DM was delivered.
class PendingInvite {
  const PendingInvite({required this.name, required this.channel});

  final String name;
  final String channel;

  /// `null` when the entry is not `{name: String, channel: String}`.
  static PendingInvite? fromJson(Object? raw) => raw is Map &&
          raw['name'] is String &&
          raw['channel'] is String
      ? PendingInvite(
          name: raw['name'] as String, channel: raw['channel'] as String)
      : null;

  Map<String, String> toJson() => {'name': name, 'channel': channel};

  @override
  bool operator ==(Object other) =>
      other is PendingInvite && other.name == name && other.channel == channel;

  @override
  int get hashCode => Object.hash(name, channel);

  @override
  String toString() => '#$channel:$name';
}

const String defaultDapUrl = 'ws://127.0.0.1:8787/ws';

/// dap_connect host normalization: no scheme → `ws://`, no path → `/ws`
/// (`hub.example.com` → `ws://hub.example.com/ws`, `hub:8787` →
/// `ws://hub:8787/ws`, an explicit `ws(s)://…/path` is kept as-is).
String normalizeDapHost(String host) {
  final withScheme =
      host.startsWith(RegExp(r'wss?://')) ? host : 'ws://$host';
  final uri = Uri.parse(withScheme);
  final path = (uri.path.isEmpty || uri.path == '/') ? '/ws' : uri.path;
  return uri.replace(path: path).toString();
}

/// The hub address for paste-ready connect lines: scheme and trailing
/// `/ws` stripped (`ws://h:1/ws` → `h:1`).
String dapHostOf(String url) => url
    .replaceFirst(RegExp(r'^wss?://'), '')
    .replaceFirst(RegExp(r'/ws$'), '');

/// `~/.dap/config.json` path — the single authority every reader/writer
/// of that file goes through ([readDapConfig], [persistDapConfig],
/// [resolveDapSettings]). [home] overrides `~` (test seam).
String defaultDapConfigFile([String? home]) => '${_withTrailingSlash(
      home ?? defaultHome(Platform.environment),
    )}.dap/config.json';

const String envChannelsFile = 'DAP_CHANNELS_FILE';

/// `~` on POSIX and Windows alike (dart:io has no homedir).
String defaultHome([Map<String, String> environment = const {}]) =>
    environment['HOME'] ??
    environment['USERPROFILE'] ??
    Directory.current.path;

String _withTrailingSlash(String path) => path.endsWith('/') ? path : '$path/';

/// Default identity file, derived from the agent name (or hostname):
/// `~/.dap/keys/fah/<sanitized>.key`.
String defaultDapKeyPath(String? name, String home) {
  final who = (name ?? Platform.localHostname)
      .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  return '${_withTrailingSlash(home)}.dap/keys/fah/$who.key';
}

/// Reads `~/.dap/config.json`; a missing or invalid file counts as absent.
Map<String, dynamic> readDapConfig(String file) {
  try {
    final decoded = jsonDecode(File(file).readAsStringSync());
    return decoded is Map<String, dynamic> ? decoded : {};
  } on Object {
    return {};
  }
}

/// The `invites` list from `~/.dap/config.json`; a missing or non-array
/// key counts as empty (back-compat with files written before invites
/// existed), malformed entries are skipped.
List<PendingInvite> readPendingInvites(String file) {
  final raw = readDapConfig(file)['invites'];
  return [
    for (final entry in (raw is List ? raw : const []))
      if (PendingInvite.fromJson(entry) case final invite?) invite,
  ];
}

/// Read-modify-write of `~/.dap/config.json` (dap_connect persistence):
/// merges [url]/[name]/[channels]; the default-room list only grows (a
/// union — rooms are never un-remembered). [invites] is the
/// authoritative pending-invite list — an empty list removes them all
/// (delivered entries are dropped by the caller). [file] is injectable
/// for tests. Auto-join on later launches flows through the shared
/// channels file (the store joins every channel it has keys for).
Future<void> persistDapConfig({
  String? url,
  String? name,
  List<String>? channels,
  List<PendingInvite>? invites,
  String? file,
}) async {
  final path = file ?? defaultDapConfigFile();
  final cur = readDapConfig(path);
  final next = Map<String, dynamic>.of(cur);
  if (url != null) next['url'] = url;
  if (name != null) next['name'] = name;
  if (channels != null && channels.isNotEmpty) {
    next['channels'] = <String>{
      ...(cur['channels'] as List? ?? const []).cast<String>(),
      ...channels,
    }.toList();
  }
  if (invites != null) {
    next['invites'] = [for (final invite in invites) invite.toJson()];
  }
  final target = File(path);
  if (!await target.parent.exists()) {
    await target.parent.create(recursive: true);
  }
  await target.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(next)}\n');
}

/// Resolves the effective settings (see library doc for precedence).
/// [config] is the already env-merged `hub:` section ([HubConfig.fromMap]).
DapSettings resolveDapSettings({
  HubConfig config = const HubConfig(),
  Map<String, String> environment = const {},
  String? home,
}) {
  final root = _withTrailingSlash(home ?? defaultHome(environment));
  final file = readDapConfig(defaultDapConfigFile(root));
  String? optStr(String key) =>
      file[key] is String && (file[key] as String).isNotEmpty
          ? file[key] as String
          : null;
  final name = config.name ?? optStr('name');
  return DapSettings(
    url: config.url ?? optStr('url') ?? defaultDapUrl,
    keyPath:
        config.keyPath ?? optStr('keyPath') ?? defaultDapKeyPath(name, root),
    name: name,
    channelsFile:
        environment[envChannelsFile] ?? optStr('channelsFile') ?? '${root}.dap/channels.json',
  );
}
