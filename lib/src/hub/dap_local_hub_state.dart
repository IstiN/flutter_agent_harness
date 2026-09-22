/// The `fa dap` local-hub pid/state file (issue #304): the
/// `<home>/.dap/hub.pid` file records the owning hub process so a second
/// CLI instance sees
/// "running" and attaches instead of double-starting, and `fa dap stop`
/// works from EITHER instance exactly once (E4 — no zombie pid).
///
/// Pure Dart on purpose (the IO around it lives in `bin/`): parse is
/// forgiving — a missing, invalid or incomplete file counts as "no
/// state", never a crash, so a torn write cannot wedge the one-step
/// start.
library;

import 'dart:convert';

/// The parsed state: the hub process id, the port it serves, and when it
/// was started (ISO-8601, informational). [relaySecret] (issue #792) is
/// the `/relay` bearer an ephemeral-secret loopback hub persists for the
/// operator / pairing clients; null on protected hubs and old files.
typedef DapLocalHubState = ({
  int pid,
  int port,
  String startedAt,
  String? relaySecret,
});

/// Where the pid/state file lives under [home] (`<home>/.dap/hub.pid`).
/// The caller applies the `DAP_HUB_PID_FILE` environment override.
String dapHubPidFileFor(String home) =>
    '${home.endsWith('/') ? home : '$home/'}.dap/hub.pid';

/// Renders [state] as the file body (pretty JSON, trailing newline).
/// Built through [JsonEncoder.withIndent] — the fields are escaped
/// properly (a relay secret carrying quotes or backslashes cannot
/// corrupt the file).
String renderDapLocalHubState(DapLocalHubState state) =>
    '${const JsonEncoder.withIndent('  ').convert({
      'pid': state.pid,
      'port': state.port,
      'startedAt': state.startedAt.isEmpty ? null : state.startedAt,
      'relaySecret': state.relaySecret,
    })}\n';

/// Parses a pid/state file body; null when [content] is missing, invalid
/// JSON, or lacks a usable `pid`/`port` (E4: a bad file is no state —
/// the next start treats the hub as unowned and re-probes).
DapLocalHubState? parseDapLocalHubState(String? content) {
  if (content == null || content.trim().isEmpty) return null;
  dynamic decoded;
  try {
    decoded = jsonDecode(content);
  } on Object {
    return null;
  }
  if (decoded is! Map) return null;
  final pid = decoded['pid'];
  final port = decoded['port'];
  if (pid is! int || pid <= 0) return null;
  if (port is! int || port <= 0) return null;
  final startedAt = decoded['startedAt'];
  return (
    pid: pid,
    port: port,
    startedAt: startedAt is String ? startedAt : '',
    relaySecret: decoded['relaySecret'] is String
        ? decoded['relaySecret'] as String
        : null,
  );
}
