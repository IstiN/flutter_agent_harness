// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The CodeMie sign-in poll for the extension-hosted web build.
///
/// Why no webview and no localhost callback: the app runs as an extension
/// page, and an extension page may use capabilities a web page cannot —
/// `chrome.tabs.create` (open the login page in a NORMAL tab; IdPs send
/// `X-Frame-Options` that forbid framing, and MV3 has no webview anyway)
/// and a cookie-authenticated fetch (`<all_urls>` host permissions = no
/// CORS; `credentials: 'include'` attaches the browser jar — a `Cookie`
/// header itself is a forbidden fetch header). So the redirect-interception
/// dance desktop/mobile need (localhost callback server) collapses into:
/// open the login tab, poll the models endpoint until the jar holds a
/// live session.
library;

import 'dart:convert';

/// Parses a CodeMie `llm_models` response body into model ids (first
/// non-empty of `id`/`base_name`/`deployment_name` per descriptor).
///
/// Returns null when the body is not the JSON list — a logged-out fetch
/// can still answer `200` with the SPA's login HTML, which must read as
/// "not signed in yet", not as a model list.
List<String>? codeMieModelIdsFromJson(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return null;
  }
  if (decoded is! List) return null;
  return [
    for (final model in decoded)
      if (model is Map) ?_firstId(model),
  ];
}

/// The first non-empty id field of a CodeMie model descriptor.
String? _firstId(Map<Object?, Object?> model) {
  for (final field in const ['id', 'base_name', 'deployment_name']) {
    final value = model[field];
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return null;
}

/// One probe result from the extension fetch.
typedef CodeMieProbe = Future<({int status, String body})> Function();

/// Polls [probe] until the CodeMie API answers with the models list —
/// the moment the user's login (opened via [openLoginPage] on the first
/// 401/403) has landed cookies in the jar.
///
/// A `200` whose body parses as the models list ends the poll; a `200`
/// with an HTML body keeps polling (the SPA's logged-out shell). Network
/// hiccups (throwing probes) never end the poll. Returns the model ids,
/// or null when [cancelled] fires or [timeout] passes.
Future<List<String>?> pollCodeMieSignIn({
  required CodeMieProbe probe,
  required void Function() openLoginPage,
  Duration timeout = const Duration(minutes: 5),
  Duration interval = const Duration(seconds: 4),
  bool Function()? cancelled,
}) async {
  final deadline = DateTime.now().add(timeout);
  var loginAsked = false;
  while (true) {
    final (models, openLogin) = await _probeCodeMieSignIn(
      probe,
      loginAsked: loginAsked,
    );
    if (models != null) return models;
    if (openLogin) {
      loginAsked = true;
      openLoginPage();
    }
    if (_pollAbandoned(cancelled, deadline)) return null;
    await Future<void>.delayed(interval);
  }
}

/// One probe of the CodeMie API. Answers the model ids when the jar
/// holds a live session (a 2xx whose body parses as the models list),
/// else whether this probe is the FIRST logged-out signal. A throwing
/// probe is transient (SW waking up, offline blip) — it keeps polling.
Future<(List<String>?, bool)> _probeCodeMieSignIn(
  CodeMieProbe probe, {
  required bool loginAsked,
}) async {
  final int status;
  final List<String>? models;
  try {
    final result = await probe();
    status = result.status;
    models = codeMieModelIdsFromJson(result.body);
  } on Object {
    return (null, false);
  }
  if (_isSignedInProbe(status, models)) return (models, false);
  return (null, _shouldOpenLoginPage(status, loginAsked, models));
}

/// The signed-in signal: a 2xx probe whose body parses as the models
/// list.
bool _isSignedInProbe(int status, List<String>? models) =>
    _is2xx(status) && models != null;

/// Whether [status] is an HTTP 2xx.
bool _is2xx(int status) => status >= 200 && status < 300;

/// Whether this probe is the FIRST logged-out signal: a bare 401/403,
/// OR a 200 carrying the SPA's login HTML (the transparent SSO
/// redirect). Both mean "open the login tab once" — without the HTML
/// branch the poll would spin to the timeout without ever opening the
/// tab.
bool _shouldOpenLoginPage(int status, bool loginAsked, List<String>? models) {
  if (loginAsked) return false;
  return status == 401 || status == 403 || (_is2xx(status) && models == null);
}

/// The poll's stop conditions: an external cancel, or the deadline
/// passed.
bool _pollAbandoned(bool Function()? cancelled, DateTime deadline) =>
    (cancelled?.call() ?? false) || DateTime.now().isAfter(deadline);
