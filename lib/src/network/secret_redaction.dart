// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Small last-line-of-defence redactor for diagnostics that include an HTTP
/// error body. Normal command/status output never includes token fields.
library;

/// Redacts common token fields, bearer values and JWT-shaped strings from
/// free-form diagnostic [text]. This is not a general log sanitizer; callers
/// should avoid printing request/response documents in the first place.
String redactNetworkSecretText(String text) {
  var redacted = text.replaceAllMapped(
    RegExp(
      r'("(?:access_?token|refresh_?token|device_?token|id_?token|ticket)"'
      r'\s*:\s*")[^"]*(")',
      caseSensitive: false,
    ),
    (match) => '${match[1]}<redacted>${match[2]}',
  );
  redacted = redacted.replaceAll(
    RegExp(r'Bearer\s+[^\s,;]+', caseSensitive: false),
    'Bearer <redacted>',
  );
  return redacted.replaceAll(
    RegExp(r'eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*'),
    '<redacted-jwt>',
  );
}
