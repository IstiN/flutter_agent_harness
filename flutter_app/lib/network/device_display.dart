// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// A compact, display-worthy title derived from the first-message preview.
String? deviceSessionPreviewTitle(String? preview) {
  final collapsed = preview?.trim().replaceAll(RegExp(r'\s+'), ' ') ?? '';
  if (collapsed.isEmpty) return null;
  final runes = collapsed.runes;
  if (runes.length <= 60) return collapsed;
  return '${String.fromCharCodes(runes.take(59))}…';
}

/// An identifier suitable for a compact row or composer hint. Both ends
/// remain visible so same-prefix sessions are still distinguishable.
String shortDeviceId(String id) => id.length > 12
    ? '${id.substring(0, 8)}…${id.substring(id.length - 4)}'
    : id;

/// Resolves a session row title like the Local tab: the registry display
/// name, then the project folder basename, then a short id. First-prompt
/// snippets stay previews; they never stand in for the session name.
///
/// Legacy DM titles sometimes prefixed the raw id with a device label. Keep
/// that useful prefix while replacing only the id with the same fallback.
String deviceSessionDisplayTitle({
  required String id,
  String? title,
  String? path,
  String? preview,
  bool cliFallback = false,
}) {
  var named = title?.trim() ?? '';
  // Older peers sometimes truncate a raw UUID before putting it in `title`.
  // Treat that as missing metadata too; otherwise the prefix check below
  // mistakes the truncated id for a human name and leaks it into the UI.
  if (_isSessionIdPrefix(named, id)) named = '';
  if (named.isNotEmpty && named != id && !named.contains(id)) return named;
  final base =
      _pathBasename(path) ??
      (cliFallback ? deviceSessionPreviewTitle(preview) : null) ??
      shortDeviceId(id);
  if (named.isNotEmpty && named != id) {
    return named.replaceAll(id, base);
  }
  // A remote row with no registry entry still gets an honest CLI identity;
  // neither a full nor a bare truncated UUID is ever its primary title.
  return cliFallback ? 'CLI · $base' : base;
}

/// Whether an agent mailbox is actually a raw session UUID rather than a
/// human/agent name. Such rows must use session metadata/fallbacks too.
bool deviceSessionIdIsUuid(String value) => RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
).hasMatch(value.trim());

/// Compact project label for session context.
String deviceSessionProjectName(String? path) =>
    _pathBasename(path) ?? path?.trim() ?? '';

/// A path subtitle that keeps both its anchor and project suffix visible.
/// Twenty-six runes matches the compact session-row anatomy; the slightly
/// longer tail favors the useful folder name over intermediate directories.
String deviceSessionPathSubtitle(String? path) {
  final value = path?.trim() ?? '';
  final runes = value.runes.toList(growable: false);
  if (runes.length <= 26) return value;
  return '${String.fromCharCodes(runes.take(12))}…'
      '${String.fromCharCodes(runes.skip(runes.length - 13))}';
}

bool _isSessionIdPrefix(String candidate, String id) {
  if (candidate.length < 9 || candidate.length >= id.length) return false;
  return id.startsWith(candidate) && candidate.contains('-');
}

String? _pathBasename(String? path) {
  final value = path?.trim().replaceAll('\\', '/') ?? '';
  if (value.isEmpty) return null;
  final parts = value.split('/').where((part) => part.isNotEmpty).toList();
  if (parts.isEmpty) return null;
  final basename = parts.last.trim();
  return basename.isEmpty || basename == '.' ? null : basename;
}
