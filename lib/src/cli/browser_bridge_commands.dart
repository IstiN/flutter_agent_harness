/// `/browser` slash-command surface (issue #23) — the pure-Dart half of the
/// browser-bridge pairing flow.
///
/// The command talks to a [BrowserBridgeHandle] the host injects (the CLI
/// executable implements it over the WebSocket bridge server in `bin/`;
/// `lib/` stays dart:io-free — DIP). When no handle is present (web hosts,
/// plain tests), every subcommand answers with a clean unavailable note.
///
/// All functions return the lines to print; the caller owns the output
/// channel, so the surface unit-tests without a terminal.
library;

import '../browser/bridge_protocol.dart';

/// One pairing session: where to point the extension and the fresh one-time
/// token it must present in its `hello`. [alreadyRunning] distinguishes a
/// newly started bridge from a reused one.
final class BrowserBridgeSession {
  const BrowserBridgeSession({
    required this.url,
    required this.token,
    required this.alreadyRunning,
  });

  /// The WebSocket endpoint, e.g. `ws://127.0.0.1:8777/ws`.
  final String url;

  /// Fresh pairing token (32-byte hex). Invalidates every earlier token.
  final String token;

  /// True when the bridge was already up and only the token rotated.
  final bool alreadyRunning;
}

/// Live bridge status: connected extensions plus a fabric mailbox listing.
final class BrowserBridgeStatus {
  const BrowserBridgeStatus({
    required this.running,
    required this.url,
    required this.extensions,
    required this.mailboxes,
  });

  /// Whether the bridge server is accepting connections.
  final bool running;

  /// The endpoint when running, null otherwise.
  final String? url;

  /// Mailbox ids of the currently paired extensions.
  final List<String> extensions;

  /// Every fabric mailbox as `(id, cwd?)` records.
  final List<({String id, String? cwd})> mailboxes;
}

/// The host-side bridge seam: start/rotate + status, implemented by the
/// executable over [the bridge server](bin/serve_bridge.dart). Null on
/// hosts without io — `/browser` then reports it cleanly.
abstract interface class BrowserBridgeHandle {
  /// Starts the bridge when it is not running yet (default port
  /// [bridgeDefaultPort]) and mints a FRESH pairing token — any token
  /// handed out earlier stops working.
  ///
  /// Throws when the port cannot be bound; the command surfaces the error.
  Future<BrowserBridgeSession> connect({int port});

  /// Snapshot of connected extensions and the fabric mailbox directory.
  Future<BrowserBridgeStatus> status();
}

const _usage = ['usage: /browser [connect [port]|status]'];

List<String> _unavailableNote() => [
  'bridge: not available on this host — the browser bridge needs an '
      'io-backed fa session',
];

/// Runs the `/browser` command and returns the lines to print.
///
/// `connect` (the bare default) starts the bridge if needed and prints the
/// ws URL plus the fresh one-time token; `status` shows connected
/// extensions and the fabric mailboxes.
Future<List<String>> runBrowserCommand(
  BrowserBridgeHandle? handle,
  String rest,
) async {
  final args = rest.isEmpty ? const <String>[] : rest.split(RegExp(r'\s+'));
  final sub = args.isEmpty ? 'connect' : args.first;
  switch (sub) {
    case 'connect':
    case 'start':
      return _browserConnect(handle, args);
    case 'status':
      return _browserStatus(handle);
    default:
      return ['bridge: unknown subcommand: $sub', ..._usage];
  }
}

/// The `connect` (alias `start`) subcommand: start the bridge if needed and
/// report the ws URL plus the fresh one-time token.
Future<List<String>> _browserConnect(
  BrowserBridgeHandle? handle,
  List<String> args,
) async {
  if (handle == null) return _unavailableNote();
  final portArg = args.length > 1 ? args[1] : null;
  if (portArg != null && int.tryParse(portArg) == null) {
    return ['bridge: not a port: $portArg', ..._usage];
  }
  final BrowserBridgeSession session;
  try {
    session = await handle.connect(
      port: int.parse(portArg ?? '$bridgeDefaultPort'),
    );
  } on Object catch (error) {
    return ['bridge: $error'];
  }
  return [
    'bridge: ${session.alreadyRunning ? 'already running' : 'started'} on ${session.url}',
    'token (one-time — old tokens are invalid): ${session.token}',
    'pair as: browser-ext/<agentId> (the extension picks its agentId)',
  ];
}

/// The `status` subcommand: connected extensions and the fabric mailboxes.
Future<List<String>> _browserStatus(BrowserBridgeHandle? handle) async {
  if (handle == null) return _unavailableNote();
  final status = await handle.status();
  return [
    if (status.running)
      'bridge: running on ${status.url}'
    else
      'bridge: not running — /browser connect starts it',
    'extensions: ${status.extensions.isEmpty ? 'none connected' : status.extensions.join(', ')}',
    'mailboxes:',
    for (final mailbox in status.mailboxes)
      '  ${mailbox.id}${mailbox.cwd == null ? '' : ' — ${mailbox.cwd}'}',
  ];
}
