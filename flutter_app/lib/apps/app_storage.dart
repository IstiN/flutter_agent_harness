// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The single app-storage namespace (gh-1614 I1).
///
/// Every `apps/<id>/…` path — the Apps tab's listing, the engine's boot
/// reads, catalog install writes — resolves through [appDir]/[appFile]
/// here: one validator, one clamp, no second path normalization. Listing
/// and reading therefore resolve the same root on every host (VM / web /
/// extension), and an id or path arriving from user storage can never
/// escape the namespace (gh-1614 AC4) — the escapes are rejected
/// by construction, before any filesystem call.
final class AppStorage {
  AppStorage._();

  /// Namespace root every app directory lives under.
  static const String root = 'apps';

  /// The entry file every manifest namespace names.
  static const String defaultEntry = 'widget.js';

  /// The manifest every app carries.
  static const String manifestFile = 'manifest.json';

  /// App-id rule (gh-1614): 2–32 chars of lowercase ASCII alnum plus
  /// dashes, starting with alnum. Rejects traversal (`..`), separators,
  /// absolute paths, dot-dirs, uppercase and unicode look-alikes — an id
  /// outside the pattern cannot name a path that leaves `<root>/<id>/`.
  static final RegExp idPattern = RegExp(r'^[a-z0-9][a-z0-9-]{1,31}$');

  /// One safe path segment inside an app dir (file or subdirectory name).
  static final RegExp _segmentPattern = RegExp(r'^[A-Za-z0-9._-]{1,128}$');

  /// Whether [id] can name an app directory inside the namespace.
  static bool isValidId(String id) => idPattern.hasMatch(id);

  /// Whether every segment of [relative] is a safe in-namespace name.
  static bool isValidRelativePath(String relative) {
    if (relative.isEmpty) return false;
    for (final segment in relative.split('/')) {
      if (segment == '.' || segment == '..') return false;
      if (!_segmentPattern.hasMatch(segment)) return false;
    }
    return true;
  }

  /// Whether [dir] is a safe directory prefix for app reads: non-empty,
  /// relative, and free of traversal segments. [appDir] results pass by
  /// construction; session-scoped dir overrides (dynamic-message widgets
  /// under `.widgets/…`) pass when every segment is a plain name.
  static bool isSafeDir(String dir) {
    if (dir.isEmpty) return false;
    for (final segment in dir.split('/')) {
      if (segment == '.' || segment == '..') return false;
      if (!_segmentPattern.hasMatch(segment)) return false;
    }
    return true;
  }

  /// Resolves `apps/<id>`.
  ///
  /// Throws [ArgumentError] naming the id and the namespace when [id]
  /// cannot live in it (gh-1614 AC4: rejected at read).
  static String appDir(String id) {
    if (!isValidId(id)) {
      throw ArgumentError(
        'app id "$id" cannot be resolved under $root/ — ids must match '
        '${idPattern.pattern} (the path would leave the $root/ namespace)',
      );
    }
    return '$root/$id';
  }

  /// Null-returning [appDir] for listing: null when [id] cannot live in
  /// the namespace (the listing skips it — never listed, never startable).
  static String? tryAppDir(String id) => isValidId(id) ? '$root/$id' : null;

  /// Resolves a file under `apps/<id>/`. [relative] may carry
  /// subdirectories (`game/main.js`); every segment is validated, so the
  /// result always stays under the app dir. Throws [ArgumentError] for a
  /// hostile name (traversal, absolute, backslash, empty).
  static String appFile(String id, String relative) {
    if (!isValidRelativePath(relative)) {
      throw ArgumentError(
        'path "$relative" cannot be resolved under $root/$id/ — every '
        'segment must match ${_segmentPattern.pattern} and no segment may '
        'be "." or ".."',
      );
    }
    return '${appDir(id)}/$relative';
  }

  /// The app's manifest path.
  static String manifestPath(String id) => appFile(id, manifestFile);

  /// The app's boot entry path ([entry] defaults to the manifest
  /// namespace's [defaultEntry]).
  static String entryPath(String id, [String entry = defaultEntry]) =>
      appFile(id, entry);
}
