/// The dart:io half of ConnTrace (gh-1395 AC2) — the ONLY place the
/// provider forensics touch platform surfaces. The pure contract lives in
/// `conn_trace.dart` (barrel-exported, web-compilable); this file is
/// reachable exclusively through `lib/io.dart` and installs itself into
/// the pure seams at the host boundary:
///
/// - [providerStackEnvLookup] ← `Platform.environment` (the FA_CONN_DEBUG /
///   FA_STALL_SENTINEL / FA_POOL_EVICTION knobs);
/// - [connTraceStderrSink] ← `stderr.writeln` (the live `[conn-trace] `
///   lines);
/// - [connTraceObservedClientFactory] ← the observed dart:io client (the
///   fresh-vs-reused + local-port classification).
library;

import 'dart:async';
import 'dart:io';

import 'package:http/io_client.dart' show IOClient;

import 'conn_trace.dart';
import 'stall_sentinel_io.dart';

/// A dart:io [HttpClient] whose connections funnel through the pure
/// observer (`connObserverNote`). Debug-only: the factory override
/// re-implements the connect leg (`Socket.startConnect`, TLS via
/// `SecureSocket.startConnect`); proxy connections are traced at the proxy
/// endpoint. Only ever installed when the trace is ON.
HttpClient observeHttpClient() {
  final client = HttpClient();
  client.connectionFactory = (uri, proxyHost, proxyPort) async {
    final host = proxyHost ?? uri.host;
    final fallbackPort = uri.scheme == 'https' ? 443 : 80;
    final port = proxyPort ?? (uri.port != 0 ? uri.port : fallbackPort);
    final secure = uri.scheme == 'https' && proxyHost == null;
    final watch = Stopwatch()..start();
    final task = secure
        ? await SecureSocket.startConnect(host, port)
        : await Socket.startConnect(host, port);
    unawaited(
      task.socket.then(
        (socket) =>
            connObserverNote(port: socket.port, openedAfter: watch.elapsed),
        onError: (Object _) {},
      ),
    );
    return task;
  };
  return client;
}

/// The io composition root for the provider forensics (idempotent; every
/// seam keeps an earlier install). Call once at host startup — `bin/` and
/// embedding VM apps; the web build never imports this file.
void installProviderStallForensics() {
  providerStackEnvLookup ??= (name) => Platform.environment[name];
  connTraceStderrSink ??= stderr.writeln;
  connTraceObservedClientFactory ??= () => IOClient(observeHttpClient());
  installStallSentinelDiskSink();
}
