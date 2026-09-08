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
    try {
      final result = await probe();
      final models = codeMieModelIdsFromJson(result.body);
      if (result.status >= 200 && result.status < 300 && models != null) {
        return models;
      }
      if ((result.status == 401 || result.status == 403) && !loginAsked) {
        loginAsked = true;
        openLoginPage();
      }
    } on Object {
      // Transient (SW waking up, offline blip) — keep polling.
    }
    if (cancelled?.call() ?? false) return null;
    if (DateTime.now().isAfter(deadline)) return null;
    await Future<void>.delayed(interval);
  }
}
