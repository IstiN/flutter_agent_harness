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
/// escape the namespace (gh-1614 AC4) — the escapes are rejected by
/// construction, before any filesystem call.
///
/// Two validation layers, one responsibility each:
///
///  * [idPattern] (strict) — the canonical rule a NEW app id must satisfy
///    (2–32 chars of lowercase ASCII alnum plus dashes). Catalog ids and
///    every flow that mints an id conform.
///  * [isResolvableId] (escape floor) — the security floor for resolving
///    ids that ALREADY exist in user storage. Legacy stores hold ids the
///    strict pattern rejects (`bad_types`, a single-letter graduation
///    slug); the listing must not silently hide a user's app over its
///    name. The floor still makes the AC4 escapes (`../x`, absolute,
///    separators) impossible to resolve: an id that cannot be a single
///    in-namespace segment never resolves, at list and at read alike.
final class AppStorage {
  AppStorage._();

  /// Namespace root every app directory lives under.
  static const String root = 'apps';

  /// The entry file every manifest namespace names.
  static const String defaultEntry = 'widget.js';

  /// The manifest every app carries.
  static const String manifestFile = 'manifest.json';

  /// The canonical app-id rule (gh-1614): 2–32 chars of lowercase ASCII
  /// alnum plus dashes, starting with alnum. Every id minted by this
  /// codebase (catalog install, graduation, dynamic widgets) conforms.
  static final RegExp idPattern = RegExp(r'^[a-z0-9][a-z0-9-]{1,31}$');

  /// Whether [id] satisfies the canonical new-id rule ([idPattern]).
  static bool isValidId(String id) => idPattern.hasMatch(id);

  /// Whether the existing storage id [id] can resolve inside the
  /// namespace: a single plain segment with no traversal, no separators,
  /// no absolute form, no NUL. This is the AC4 floor — `../x`, `a/../b`
  /// and `/abs` are all false, so `apps/<id>` cannot leave `apps/`.
  static bool isResolvableId(String id) =>
      id.isNotEmpty &&
      !id.contains('/') &&
      !id.contains('\\') &&
      !id.contains('\u0000') &&
      id != '.' &&
      id != '..' &&
      !id.startsWith('.');

  /// One safe path segment inside an app dir (file or subdirectory name).
  static final RegExp _segmentPattern = RegExp(r'^[A-Za-z0-9._-]{1,128}$');

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
  /// under `.widgets/…`) pass too — their slugs derive from cwd-encoded
  /// session paths and may carry arbitrary non-separator characters, which
  /// the reader's lexical clamp handles: only a `..` segment, an empty
  /// segment or a leading separator could escape, and those are rejected
  /// here.
  static bool isSafeDir(String dir) {
    if (dir.isEmpty) return false;
    if (dir.startsWith('/') || dir.startsWith('\\')) return false;
    for (final segment in dir.split('/')) {
      if (segment == '.' || segment == '..') return false;
      if (segment.isEmpty) return false;
    }
    return true;
  }

  /// Resolves `apps/<id>`.
  ///
  /// Throws [ArgumentError] naming the id and the namespace when [id]
  /// cannot resolve inside it (gh-1614 AC4: rejected at read — traversal,
  /// absolute, separator-carrying ids).
  static String appDir(String id) {
    if (!isResolvableId(id)) {
      throw ArgumentError(
        'app id "$id" cannot be resolved under $root/ — an id must be a '
        'single plain segment (no "..", no "/", no absolute form; the '
        'path would leave the $root/ namespace)',
      );
    }
    return '$root/$id';
  }

  /// Null-returning [appDir] for listing: null when [id] cannot resolve
  /// inside the namespace (the listing skips it — never listed, never
  /// startable).
  static String? tryAppDir(String id) =>
      isResolvableId(id) ? '$root/$id' : null;

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
