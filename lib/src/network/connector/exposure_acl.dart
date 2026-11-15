/// Inbound exposure ACL — the connector-side sanitizer for remote writers
/// (contract `docs/fa_network_connector.md` §6, amendment v1.1 §3).
///
/// Remote writers are always VIEWERS (§6, issue #428 semantics): inbound
/// mail addressed to a local agent is written into the agent's mailbox as
/// plain user text. This library is the connector's WHOLE content-sanitizing
/// surface — per amendment v1.1 the server does structural checks only
/// (routing, dedup, seq); everything content-shaped is rejected HERE:
/// slash-commands (`/...` leading), approval/config, tool grants and
/// takeover/admin-shaped payloads never reach a local sink.
///
/// Pure Dart: no `dart:io`, no Flutter.
library;

import 'dart:convert';

/// The allowed verdict: [text] is the sanitized plain user text a local
/// sink may accept.
final class AclAllow {
  const AclAllow(this.text);

  /// The plain user text (remote writers are viewers — nothing else).
  final String text;

  @override
  String toString() => 'AclAllow(<${text.length} chars>)';
}

/// The rejection verdict: the payload never reaches a local sink; [reason]
/// is the stable, credential-free explanation surfaced in reports.
final class AclReject {
  const AclReject(this.reason);

  /// Why the write was refused.
  final String reason;

  @override
  String toString() => 'AclReject($reason)';
}

/// The decision type of [sanitizeRemoteWrite]: [AclAllow] (sanitized text)
/// or [AclReject] (reason).
typedef AclDecision = Object;

/// Payload keys that mark a remote write as approval/config/tool-grant/
/// takeover-shaped (§6 negative-test surface). Matched case-insensitively
/// against JSON object keys, scanned at ANY depth.
const Set<String> aclForbiddenPayloadKeys = {
  'approval',
  'approved',
  'config',
  'configuration',
  'tool_grant',
  'toolgrant',
  'grant',
  'takeover',
  'admin',
};

/// Sanitizes one inbound remote write (§6). Decision rules:
/// - empty writes are rejected (nothing to deliver);
/// - a leading slash-command (`/...` — `/approval`, `/config`, `/allow`,
///   ...) is rejected: commands are local-only;
/// - a JSON-object payload is scanned for [aclForbiddenPayloadKeys] at any
///   depth (case-insensitive) and rejected when one appears; a clean
///   payload carrying a `text` string is reduced to that plain user text
///   (re-sanitized recursively); a structured payload without `text` is
///   rejected outright;
/// - anything else is plain user text and passes as-is.
AclDecision sanitizeRemoteWrite(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return const AclReject('empty remote write carries nothing to deliver');
  }
  if (trimmed.startsWith('/') &&
      trimmed.length > 1 &&
      _nonSpaceAt(trimmed, 1)) {
    return AclReject(
      'slash-commands are local-only (remote writers are viewers): '
      '${trimmed.split(_firstWhitespace).first}',
    );
  }
  if (trimmed.startsWith('{')) {
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      decoded = null;
    }
    if (decoded is Map) {
      final forbidden = _findForbiddenKey(decoded, const []);
      if (forbidden != null) {
        return AclReject(
          'remote write carries forbidden payload key '
          '"${forbidden.key}" (approval/config/tool-grant/takeover shape '
          '${forbidden.path.isEmpty ? '' : 'at ${forbidden.path.join('.')} '}'
          'is never accepted)',
        );
      }
      final text = decoded['text'];
      if (text is String) {
        return sanitizeRemoteWrite(text);
      }
      return const AclReject(
        'structured payloads are not accepted from remote viewers; '
        'remote writes reduce to plain user text',
      );
    }
    // Looks like JSON but is not an object (or does not parse): treat as
    // literal user text — a human typing `{hello` is not a payload.
  }
  return AclAllow(trimmed);
}

final RegExp _firstWhitespace = RegExp(r'\s');

bool _nonSpaceAt(String text, int index) =>
    !text.substring(index, index + 1).contains(_firstWhitespace);

final class _ForbiddenHit {
  const _ForbiddenHit(this.key, this.path);
  final String key;
  final List<String> path;
}

_ForbiddenHit? _findForbiddenKey(Object? node, List<String> path) {
  if (node is Map) {
    for (final entry in node.entries) {
      final key = entry.key.toString().toLowerCase();
      final nextPath = [...path, entry.key.toString()];
      if (aclForbiddenPayloadKeys.contains(key)) {
        return _ForbiddenHit(key, [...path]);
      }
      final nested = _findForbiddenKey(entry.value, nextPath);
      if (nested != null) return nested;
    }
  } else if (node is List) {
    for (final item in node) {
      final nested = _findForbiddenKey(item, path);
      if (nested != null) return nested;
    }
  }
  return null;
}
