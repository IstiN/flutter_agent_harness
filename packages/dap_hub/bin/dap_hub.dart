// The dap_hub executable: config from env/flags, then serve.
//
// Port of the Go main.go flag/env handling:
//   HUB_ADDR (:8080) / -addr
//   HUB_ADMIN_TOKEN / -admin-token
//   HUB_MASTER_SECRET (REQUIRED) / -master-secret
//   HUB_CHANNELS_FILE (channels.json) / -channels-file
//   HUB_SECRETS_FILE (secrets.json) / -secrets-file

import 'dart:io';

import 'package:dap_hub/dap_hub.dart';
import 'package:dap_hub/io.dart';

Future<void> main(List<String> args) async {
  final flags = _parseFlags(args);
  final masterSecret =
      flags['master-secret'] ?? Platform.environment['HUB_MASTER_SECRET'] ?? '';
  if (masterSecret.isEmpty) {
    stderr.writeln(
      'dap_hub: master secret is required: '
      'set -master-secret or HUB_MASTER_SECRET',
    );
    exitCode = 64; // EX_USAGE
    return;
  }
  final addr = flags['addr'] ?? Platform.environment['HUB_ADDR'] ?? ':8080';
  final (host, port) = _splitAddr(addr);

  final hub = DapHub(
    config: DapHubConfig(
      masterSecret: masterSecret,
      adminToken:
          flags['admin-token'] ?? Platform.environment['HUB_ADMIN_TOKEN'] ?? '',
      channelStore: AtomicFileStore(
        flags['channels-file'] ??
            Platform.environment['HUB_CHANNELS_FILE'] ??
            'channels.json',
      ),
      secretStore: AtomicFileStore(
        flags['secrets-file'] ??
            Platform.environment['HUB_SECRETS_FILE'] ??
            'secrets.json',
      ),
    ),
    log: (line) => stderr.writeln('${DateTime.now()} $line'),
  );
  await hub.load();
  final server = await DapHubServer.start(hub, host: host, port: port);
  stdout.writeln('dap_hub listening on ${server.url}');
}

/// Minimal `-flag value` / `-flag=value` parsing (mirrors Go's flag pkg
/// for the five string flags this binary has).
Map<String, String> _parseFlags(List<String> args) {
  final flags = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('-')) continue;
    final name = arg.replaceAll(RegExp('^-+'), '');
    if (name.contains('=')) {
      final split = name.split('=');
      flags[split.first] = split.sublist(1).join('=');
    } else if (i + 1 < args.length) {
      flags[name] = args[++i];
    }
  }
  return flags;
}

/// Splits Go-style listen addresses: `:8080` → (0.0.0.0, 8080) — but we
/// default the bare-port form to loopback, matching the hub's
/// machine-local posture — and `host:port` → (host, port).
(String, int) _splitAddr(String addr) {
  final colon = addr.lastIndexOf(':');
  if (colon < 0) return ('127.0.0.1', int.parse(addr));
  final host = addr.substring(0, colon);
  final port = int.parse(addr.substring(colon + 1));
  return (host.isEmpty ? '127.0.0.1' : host, port);
}
