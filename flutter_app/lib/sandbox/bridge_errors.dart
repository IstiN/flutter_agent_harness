// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

/// Structured transport-failure reporting for the sandbox network paths
/// (gh-1444 AC3): the python HTTP bridge and the `curl`/`wget` builtins.
///
/// A swallowed request (connection reset before a response, TLS handshake
/// failure, timeout) must be indistinguishable from a fast success
/// NOWHERE in the harness — every failure renders a `[bridge]` line in the
/// tool result AND lands in app.log, with the host and a request id for
/// correlation. The lines carry host + error class only: never request
/// headers, bodies, or query strings.
///
/// Pure Dart (no `dart:io`) so the web shell's builtins compile with them;
/// exception classes are recognized through `dart:async` types and message
/// text, which keeps the classifier honest on every platform.

/// Transport-failure class for a failed request: the short lowercase
/// phrase rendered in `[bridge]` lines (`timeout`, `tls`, `connection
/// reset`, `connection refused`, `dns`, `aborted`, `socket`, `error`).
String bridgeErrorClass(Object error) {
  if (error is TimeoutException) return 'timeout';
  final text = error.toString().toLowerCase();
  if (text.contains('handshake') ||
      text.contains('tls') ||
      text.contains('certificate')) {
    return 'tls';
  }
  if (text.contains('connection refused')) return 'connection refused';
  if (text.contains('reset') || text.contains('connection closed')) {
    return 'connection reset';
  }
  if (text.contains('failed host lookup') || text.contains('dns')) return 'dns';
  if (text.contains('aborted')) return 'aborted';
  if (text.contains('socket')) return 'socket';
  return 'error';
}

/// The structured transport-failure line (gh-1444 AC3):
/// `[bridge] GET api.github.com: connection reset (rid ab12cd34)` — the
/// request id correlates the tool result with the app.log line.
/// [partialBytes] (E2) marks a body that broke mid-transfer: the payload
/// WAS partially delivered, and the line says so.
String bridgeFailureLine({
  required String method,
  required String host,
  required Object error,
  required String rid,
  int? partialBytes,
}) {
  final suffix = partialBytes == null
      ? ''
      : ' after $partialBytes bytes (truncated)';
  return '[bridge] $method $host: ${bridgeErrorClass(error)} '
      '(rid $rid)$suffix';
}

/// The host of a bridged authority (`https://api.github.com:443`) for
/// failure lines — the scheme, default port, any path, and IPv6 brackets
/// never render (`http://[::1]:8080/x` → `::1`; the manual first-colon
/// slice mangled bracketed hosts). The platform parser does the slicing;
/// a corrupt authority (never produced by the bridge or the curl URL
/// parse) still renders the raw text — the failure line must exist, never
/// crash the failure path.
String bridgeHostOfAuthority(String authority) {
  // A bare authority (`api.github.com:443`) needs the `//` so the parser
  // reads it as host:port instead of scheme:path.
  final parseable = authority.contains('://') ? authority : '//$authority';
  try {
    return Uri.parse(parseable).host;
  } on FormatException {
    return authority;
  }
}
