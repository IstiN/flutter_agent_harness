// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

// The manifest-schema engine shared with the fa_widgets catalog CI (issue
// #1045): the unpacked loader validates with the SAME parser, so a
// manifest that loads unpacked is one the catalog tooling understands —
// byte-identical error strings included. The public barrel also exports
// the zip packager, which does not compile against the app's archive 4;
// only the manifest + issues subtrees are needed here.
// ignore: implementation_imports
import 'package:fa_widgets_tool/src/issues.dart';
// ignore: implementation_imports
import 'package:fa_widgets_tool/src/manifest.dart';

/// One named finding of the [WidgetPayloadValidator].
///
/// [code] is stable and machine-readable (`manifest_missing`, `id_invalid`,
/// … — asserted in tests and shown to the agent); [message] is the
/// human-readable text naming the field and the path, never a raw engine
/// crash (gh-1616 AC2).
sealed class WidgetPayloadIssue {
  const WidgetPayloadIssue(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

final class WidgetPayloadError extends WidgetPayloadIssue {
  const WidgetPayloadError(super.code, super.message);
}

final class WidgetPayloadWarning extends WidgetPayloadIssue {
  const WidgetPayloadWarning(super.code, super.message);
}

/// The outcome of validating one unpacked widget payload: the normalized
/// files (picked-folder root stripped, posix separators), the decoded
/// manifest (null when it never parsed), and every named issue.
class WidgetPayloadValidation {
  const WidgetPayloadValidation({
    required this.files,
    required this.manifest,
    required this.errors,
    required this.warnings,
  });

  /// Normalized payload: `apps/<id>/`-relative posix paths → bytes.
  final Map<String, Uint8List> files;

  /// The decoded manifest JSON, or null when it is missing or not a JSON
  /// object.
  final Map<String, Object?>? manifest;

  final List<WidgetPayloadError> errors;
  final List<WidgetPayloadWarning> warnings;

  /// The manifest's declared `network` capability (`jsr.fetchJson`) —
  /// false when the manifest never parsed. Surfaced on the load confirm
  /// (the exfiltration gate, gh-1616 E2).
  bool get network => manifest?['network'] == true;

  /// The manifest `id` (null when the manifest never parsed) — the
  /// destination folder name under `apps/`.
  String? get id => manifest?['id']?.toString();

  /// The manifest `name` (null when the manifest never parsed).
  String? get name => manifest?['name']?.toString();

  /// The manifest `version` (null when the manifest never parsed).
  String? get version => manifest?['version']?.toString();

  /// The manifest's declared `allowedCommands` (the `jsr.exec` allowlist)
  /// — empty when the manifest never parsed. Surfaced on the load confirm.
  List<String> get allowedCommands => [
    for (final command
        in (manifest?['allowedCommands'] as List<Object?>?) ?? const [])
      command.toString(),
  ];

  /// True when nothing blocks the load — warnings never do.
  bool get isValid => errors.isEmpty;
}

/// The shared widget validator (gh-1616): one ruleset over an in-memory
/// `apps/<id>/` payload, used by the unpacked loader before anything is
/// written to the env — and shaped so #1614-style storage reads can run
/// the exact same checks over exactly the same map shape.
///
/// What it validates (the runtime contract boot depends on):
/// - `manifest.json` present, parses, and passes the catalog engine's
///   schema parser (`WidgetManifest.fromJson` — verbatim strings);
/// - the manifest `id` matches `^[a-z0-9][a-z0-9-]{1,31}$` (the catalog
///   rule — ids that could not name a folder are rejected before any
///   `apps/…` write, so traversal is impossible by construction);
/// - the entry `widget.js` is present and non-empty (plus a declared tile
///   entry);
/// - no payload path escapes the widget root (`../`, absolute) — the same
///   root clamping the storage side enforces;
/// - size caps: a huge file or package fails with a clear message (E4)
///   instead of a quota blow-up at write time.
///
/// What it deliberately does NOT enforce (deltas from the catalog CI
/// ruleset, so a worktree under development loads):
/// - the picked folder's own NAME is irrelevant — the id lives in the
///   manifest and the destination `apps/<id>/` is derived from it;
/// - a non-strict-semver `version` warns instead of erroring (the
///   updater tolerates it; the catalog gate stays in the publish flow).
class WidgetPayloadValidator {
  const WidgetPayloadValidator();

  /// The entry file every widget must ship.
  static const String entryFile = 'widget.js';

  /// The manifest file, at the widget root.
  static const String manifestFile = 'manifest.json';

  /// Hard per-file cap (E4). The catalog engine only WARNS past 1 MiB;
  /// an unpacked load is a local trust action, but a single multi-megabyte
  /// file into the OPFS-backed env is still refused with a clear message.
  static const int maxFileBytes = 2 * 1024 * 1024;

  /// Hard total-payload cap (E4).
  static const int maxPackageBytes = 10 * 1024 * 1024;

  /// The widget id rule — identical to the catalog engine's.
  static final RegExp idPattern = RegExp(r'^[a-z0-9][a-z0-9-]{1,31}$');

  /// `minRuntime` stamped into manifests that omit it, so the shared
  /// schema parser accepts them — same floor the publish pre-flight uses
  /// ([WidgetPublishService.catalogFloorRuntime], issue #1045 AC2).
  static const String catalogFloorRuntime = '0.4.79';

  /// Validates [pickedFiles] (a folder pick: paths may share one root
  /// folder prefix, as browser directory picks report them) and returns
  /// the normalized validation. Never throws for content problems.
  WidgetPayloadValidation validate(Map<String, Uint8List> pickedFiles) {
    final errors = <WidgetPayloadError>[];
    final warnings = <WidgetPayloadWarning>[];

    // ── path normalization + root clamping ─────────────────────────────
    var files = normalizePaths(pickedFiles, errors);
    if (errors.isNotEmpty) {
      return WidgetPayloadValidation(
        files: const {},
        manifest: null,
        errors: errors,
        warnings: warnings,
      );
    }
    files = stripCommonRoot(files);

    // ── manifest ────────────────────────────────────────────────────────
    Map<String, Object?>? manifest;
    final manifestBytes = files[manifestFile];
    if (manifestBytes == null) {
      final root = _sharedRootOf(files);
      errors.add(
        WidgetPayloadError(
          'manifest_missing',
          root == null
              ? 'manifest.json not found in the picked folder — a widget is '
                    'a folder with manifest.json and widget.js at its root'
              : 'manifest.json not found in the picked folder (looked at '
                    '"$root/manifest.json") — a widget is a folder with '
                    'manifest.json and widget.js at its root',
        ),
      );
    } else {
      manifest = _decodeManifest(manifestBytes, errors);
      if (manifest != null) {
        _checkSchema(manifest, errors, warnings);
      }
    }

    // ── entry presence ──────────────────────────────────────────────────
    final entryBytes = files[entryFile];
    if (entryBytes == null) {
      errors.add(
        const WidgetPayloadError(
          'entry_missing',
          'widget.js not found in the picked folder — the entry file the '
              'engine runs is missing',
        ),
      );
    } else if (entryBytes.isEmpty) {
      errors.add(const WidgetPayloadError('entry_empty', 'widget.js is empty'));
    }
    // A declared live-tile entry is as mandatory as the main entry: the
    // tile host would fail at boot otherwise.
    final tileEntry = switch (manifest?['widget']) {
      final Map<Object?, Object?> widget => widget['entry']?.toString(),
      _ => null,
    };
    if (tileEntry != null &&
        tileEntry.isNotEmpty &&
        tileEntry != entryFile &&
        !files.containsKey(tileEntry)) {
      errors.add(
        WidgetPayloadError(
          'tile_entry_missing',
          'declared tile entry "$tileEntry" not found in the picked folder',
        ),
      );
    }

    // ── declared icon (cosmetic — warns, never blocks) ──────────────────
    final icon = manifest?['icon']?.toString();
    if (icon != null &&
        icon.isNotEmpty &&
        !icon.startsWith('&#') && // emoji glyph icons are inline
        RegExp(r'^[\w./-]+$').hasMatch(icon) && // …not a bare "📦"
        !files.containsKey(icon)) {
      warnings.add(
        WidgetPayloadWarning(
          'icon_missing',
          'declared icon "$icon" not found in the picked folder — the '
              'fallback glyph renders instead',
        ),
      );
    }

    // ── size caps (E4) ──────────────────────────────────────────────────
    var total = 0;
    for (final entry in files.entries) {
      total += entry.value.length;
      if (entry.value.length > maxFileBytes) {
        errors.add(
          WidgetPayloadError(
            'file_too_large',
            '${entry.key} is ${_kb(entry.value.length)} KB — the limit is '
                '${_kb(maxFileBytes)} KB per file',
          ),
        );
      }
    }
    if (total > maxPackageBytes) {
      errors.add(
        WidgetPayloadError(
          'package_too_large',
          'the widget is ${_kb(total)} KB in total — the limit is '
              '${_kb(maxPackageBytes)} KB',
        ),
      );
    }

    return WidgetPayloadValidation(
      files: files,
      manifest: manifest,
      errors: errors,
      warnings: warnings,
    );
  }

  /// The id rule — one named error per failing id (deduped by the
  /// caller's error list; raw and parsed ids are usually the same).
  void _checkId(String id, List<WidgetPayloadError> errors) {
    if (idPattern.hasMatch(id)) return;
    final known = errors.any(
      (error) => error.code == 'id_invalid' && error.message.contains("'$id'"),
    );
    if (known) return;
    errors.add(
      WidgetPayloadError(
        'id_invalid',
        "manifest id '$id' must match [a-z0-9][a-z0-9-]{1,31}",
      ),
    );
  }

  /// Decodes the manifest bytes: named errors for malformed JSON and
  /// non-object documents, null manifest for both.
  Map<String, Object?>? _decodeManifest(
    Uint8List bytes,
    List<WidgetPayloadError> errors,
  ) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException catch (e) {
      errors.add(
        WidgetPayloadError(
          'manifest_malformed',
          'manifest.json is not valid JSON: ${e.message}',
        ),
      );
      return null;
    } on Object catch (e) {
      errors.add(WidgetPayloadError('manifest_malformed', 'manifest.json: $e'));
      return null;
    }
    if (decoded is! Map) {
      errors.add(
        const WidgetPayloadError(
          'manifest_invalid',
          'manifest.json: manifest must be a JSON object',
        ),
      );
      return null;
    }
    return Map<String, Object?>.from(decoded);
  }

  /// Runs the catalog engine's schema parser and the id rule. The parser
  /// errors are surfaced verbatim (issue #1045's one-ruleset invariant).
  ///
  /// Like the publish pre-flight ([WidgetPublishService.stampedManifest]),
  /// a missing/empty `minRuntime` is stamped with the catalog floor
  /// BEFORE parsing — dev worktrees routinely omit it, and the value is a
  /// catalog-compat declaration, not a runtime requirement.
  void _checkSchema(
    Map<String, Object?> manifest,
    List<WidgetPayloadError> errors,
    List<WidgetPayloadWarning> warnings,
  ) {
    final existingRuntime = manifest['minRuntime'];
    final stamped = <String, Object?>{...manifest};
    if (existingRuntime is! String || existingRuntime.trim().isEmpty) {
      stamped['minRuntime'] = catalogFloorRuntime;
    }
    // A missing version is a dev-worktree shape, not a broken one: stamp
    // the placeholder (the app's own default) with a warning — the catalog
    // gate still refuses it at publish time.
    final existingVersion = manifest['version'];
    if (existingVersion is! String || existingVersion.trim().isEmpty) {
      stamped['version'] = '0.0.0';
      warnings.add(
        const WidgetPayloadWarning(
          'version_missing',
          'manifest has no version — "0.0.0" is assumed (the catalog '
              'requires strict semver)',
        ),
      );
    }
    // The id rule runs against the RAW manifest FIRST: a structurally
    // broken manifest (a missing version, say) must still name its bad id
    // in the same pass — the user fixes the folder in one round, not one
    // error per retry.
    final rawId = stamped['id'];
    if (rawId is String && rawId.trim().isNotEmpty) {
      _checkId(rawId.trim(), errors);
    }
    try {
      final parsed = WidgetManifest.fromJson(stamped);
      _checkId(parsed.id, errors);
      if (!isValidSemver(parsed.version)) {
        warnings.add(
          WidgetPayloadWarning(
            'version_not_semver',
            "version '${parsed.version}' is not strict semver X.Y.Z — the "
                'catalog requires it, unpacked loads tolerate it',
          ),
        );
      }
      for (final key in manifest.keys) {
        if (!knownManifestKeys.contains(key)) {
          warnings.add(
            WidgetPayloadWarning(
              'unknown_manifest_key',
              "unknown manifest key '$key' (forward-compat: ignored)",
            ),
          );
        }
      }
    } on ManifestException catch (e) {
      for (final message in e.errors) {
        errors.add(
          WidgetPayloadError('manifest_invalid', 'manifest.json: $message'),
        );
      }
    }
  }

  /// Rejects absolute paths and `..` escapes, normalizes separators to
  /// posix. The rejected entries are removed; a [path_unsafe] error names
  /// the first offender.
  static Map<String, Uint8List> normalizePaths(
    Map<String, Uint8List> pickedFiles,
    List<WidgetPayloadError> errors,
  ) {
    final files = <String, Uint8List>{};
    for (final entry in pickedFiles.entries) {
      final path = entry.key.replaceAll('\\', '/');
      final segments = path.split('/');
      if (path.startsWith('/') || segments.contains('..')) {
        errors.add(
          WidgetPayloadError(
            'path_unsafe',
            'the picked folder contains "$path" — paths must stay inside '
                'the widget folder',
          ),
        );
        continue;
      }
      if (path.isEmpty) continue;
      files[path] = entry.value;
    }
    return files;
  }

  /// The one shared root folder of [files] (the picked folder's own
  /// name, as browser picks report it), or null when the payload has no
  /// common first segment. Used only for error messages.
  static String? _sharedRootOf(Map<String, Uint8List> files) {
    String? root;
    for (final path in files.keys) {
      final slash = path.indexOf('/');
      if (slash <= 0) return null;
      final first = path.substring(0, slash);
      if (root == null) {
        root = first;
      } else if (root != first) {
        return null;
      }
    }
    return root;
  }

  /// Browser directory picks report every file as `<picked-folder>/<rel>`;
  /// a payload that already IS the widget (no shared root) passes
  /// through unchanged. The common prefix is stripped only when every
  /// file shares exactly one first segment — a widget with its own nested
  /// `lib/` still normalizes, and no foreign shape is silently mangled.
  static Map<String, Uint8List> stripCommonRoot(Map<String, Uint8List> files) {
    String? root;
    for (final path in files.keys) {
      final slash = path.indexOf('/');
      if (slash <= 0) return files; // a top-level file — already a widget
      final first = path.substring(0, slash);
      if (root == null) {
        root = first;
      } else if (root != first) {
        return files; // multiple roots — not a single picked folder
      }
    }
    final prefix = root;
    if (prefix == null) return files;
    return {
      for (final entry in files.entries)
        entry.key.substring(prefix.length + 1): entry.value,
    };
  }

  static String _kb(int bytes) => (bytes / 1024).round().toString();
}
