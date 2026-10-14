// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:typed_data';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/widget_payload_validator.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// One file of a picked folder: the path inside the folder (posix
/// separators, possibly still carrying the picked folder's own name as
/// the first segment — exactly what browser directory picks report) and
/// its bytes.
class UnpackedPickedFile {
  const UnpackedPickedFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// The pick contract of the "Load unpacked" flow (gh-1616): returns the
/// picked folder's files, or an empty list when the user cancelled (or
/// the folder vanished before it could be read — E1 treats both as an
/// honest no-op rather than an error dialog over nothing).
///
/// Implementations: the web folder picker
/// (`folder_picker_web.dart`, an `<input type="file" webkitdirectory>`)
/// and a null-producing stub elsewhere — hosts that cannot pick folders
/// hide the entry instead of showing a button that errors.
abstract interface class FolderPicker {
  Future<List<UnpackedPickedFile>> pickFolder();
}

/// The outcome of [UnpackedWidgetLoader.inspect]: the shared validator's
/// verdict plus the capability surface the load confirm must name before
/// the user grants the load (the exfiltration gate, gh-1616 E2).
class UnpackedInspection {
  const UnpackedInspection(this.validation);

  final WidgetPayloadValidation validation;

  /// Normalized payload files (`apps/<id>/`-relative posix paths).
  Map<String, Uint8List> get files => validation.files;

  /// The manifest id — the destination folder name under `apps/`. Null
  /// when the manifest never parsed (the load is refused anyway).
  ///
  /// Trimmed: the id rule (`^[a-z0-9][a-z0-9-]{1,31}$`) is enforced on
  /// `id.trim()` (the same value `WidgetManifest.fromJson` stores), so
  /// every consumer — the replace lookup, the confirm dialog, the install
  /// folder — sees the rule-enforced form. A padded manifest id
  /// (`" fa-agents "`) lands in `apps/fa-agents/`, never in a
  /// space-padded folder that violates the rule it just passed.
  String? get id => validation.id?.trim();
  String? get name => validation.name;
  String? get version => validation.version;

  /// Declared `network` capability (the confirm names it when true).
  bool get network => validation.network;

  /// Declared `jsr.exec` allowlist (the confirm names it when non-empty).
  List<String> get allowedCommands => validation.allowedCommands;

  /// Named errors (empty when the load may proceed).
  List<WidgetPayloadError> get errors => validation.errors;

  bool get isValid => validation.isValid;
}

/// Loads a local `apps/<id>/` folder into the env — the unpacked-widget
/// loader (gh-1616), Chrome's "Load unpacked" for fa widgets.
///
/// One sentence: validate the picked payload with the shared validator,
/// then store it EXACTLY like a catalog install ([AppsStore.installWidget]
/// — the same ownership-aware, write-verified, `storage.json`-keeping
/// path) with the install origin recorded as `unpacked`, so boot, the
/// `refreshSeconds` schedule, the Apps grid, uninstall and restart need
/// zero special cases (invariant I1).
///
/// Nothing is written until [install] runs on a valid [inspect] result;
/// every rejection is a named error (field + path) from the shared
/// validator — never a raw `app entry not found` (AC2).
class UnpackedWidgetLoader {
  UnpackedWidgetLoader({required ExecutionEnv env, AppsStore? appsStore})
    : appsStore = appsStore ?? AppsStore(env);

  /// The store the widget lands in — shared with the caller so grid
  /// reloads see the same install records.
  final AppsStore appsStore;

  /// The unpacked install origin recorded in `apps/.installed.json`
  /// (invariant I3 — provenance is data the UI and the updater read).
  static const String origin = 'unpacked';

  /// The synthesized source the load confirm shows for an existing app
  /// with NO install record (agent-created via the file tools): the
  /// replace warning must still fire (AC4 — any existing id is replaced
  /// by a load), and the label names the honest provenance — "created by
  /// the agent" — instead of inventing a fake install. Never written to
  /// `.installed.json`; purely a dialog-input marker.
  static const String agentCreatedSource = 'agent';

  /// Validates a picked folder (no writes). Deterministic and pure with
  /// respect to the env — the UI can show issues before any confirm.
  Future<UnpackedInspection> inspect(Map<String, Uint8List> pickedFiles) =>
      Future.value(
        UnpackedInspection(
          const WidgetPayloadValidator().validate(pickedFiles),
        ),
      );

  /// Stores a VALIDATED inspection into `apps/<id>/`. Throws
  /// [StateError] when [inspection] carries errors — callers confirm with
  /// the user first; the loader never silently downgrades a refused
  /// payload into an install.
  Future<void> install(UnpackedInspection inspection) async {
    final id = inspection.id;
    if (!inspection.isValid || id == null || id.isEmpty) {
      final named = inspection.errors.map((error) => error.message).join('; ');
      throw StateError('refusing to install an invalid widget: $named');
    }
    await appsStore.installWidget(
      id: id,
      version: inspection.version ?? '0.0.0',
      files: inspection.files,
      origin: origin,
    );
  }
}
