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

/// An identifier suitable for a compact row or composer hint.
String shortDeviceId(String id) =>
    id.length > 8 ? '${id.substring(0, 8)}…' : id;

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
}) {
  final named = title?.trim() ?? '';
  if (named.isNotEmpty && named != id && !named.contains(id)) return named;
  final fallback = _pathBasename(path) ?? shortDeviceId(id);
  if (named.isNotEmpty && named != id) {
    return named.replaceAll(id, fallback);
  }
  return fallback;
}

String? _pathBasename(String? path) {
  final value = path?.trim().replaceAll('\\', '/') ?? '';
  if (value.isEmpty) return null;
  final parts = value.split('/').where((part) => part.isNotEmpty).toList();
  if (parts.isEmpty) return null;
  final basename = parts.last.trim();
  return basename.isEmpty || basename == '.' ? null : basename;
}
