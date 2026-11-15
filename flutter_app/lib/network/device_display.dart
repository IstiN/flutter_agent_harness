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

/// Resolves a session row title without exposing a hash when a human hint
/// exists: real title, preview snippet, path basename, then short id.
String deviceSessionDisplayTitle({
  required String id,
  String? title,
  String? preview,
  String? path,
}) {
  final named = title?.trim();
  if (named != null && named.isNotEmpty && named != id) return named;
  final snippet = deviceSessionPreviewTitle(preview);
  if (snippet != null) return snippet;
  final basename = _pathBasename(path);
  if (basename != null) return basename;
  return id.length > 8 ? id.substring(0, 8) : id;
}

String? _pathBasename(String? path) {
  final value = path?.trim().replaceAll('\\', '/') ?? '';
  if (value.isEmpty) return null;
  final parts = value.split('/').where((part) => part.isNotEmpty).toList();
  if (parts.isEmpty) return null;
  final basename = parts.last.trim();
  return basename.isEmpty || basename == '.' ? null : basename;
}
