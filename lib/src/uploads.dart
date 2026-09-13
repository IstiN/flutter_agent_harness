// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Chat-attachment staging shared by every Fa surface (issue #313): the
/// app's [AgentService.stageAttachment] and the extension service worker's
/// `agent.stageUpload` ext_request op run THE SAME routine over their
/// `ExecutionEnv`, so a staged `uploads/…` path means the same thing on
/// both sides — identical sanitize, dedupe and directory semantics.
library;

import 'dart:typed_data';

import 'env/execution_env.dart';

/// Directory (relative to the env's working directory) where chat
/// attachments are staged before the outgoing message references them.
const String uploadsDirName = 'uploads';

/// Strips path separators and `.`/`..` segments from a picked file [name]
/// (some browsers send a `webkitRelativePath`), so the upload stays inside
/// the target directory. Returns the cleaned relative path — possibly with
/// subdirectories — or an empty string when nothing usable is left.
String sanitizeUploadName(String name) {
  final segments = name
      .split(RegExp(r'[/\\]'))
      .where((s) => s.isNotEmpty && s != '.' && s != '..')
      .toList();
  return segments.join('/');
}

/// `name.ext` → `name-1.ext` for n = 1; names without an extension get
/// the suffix appended whole.
String dedupeUploadName(String name, int n) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return '$name-$n';
  return '${name.substring(0, dot)}-$n${name.substring(dot)}';
}

/// Stages one chat attachment into [uploadsDirName] inside [env], creating
/// the directory and de-duplicating the file name on collision
/// (`report.pdf` → `report-1.pdf` → …). Returns the env-relative path
/// (`uploads/report.pdf`) the outgoing message should reference.
///
/// Throws [StateError] with a readable message when nothing was written —
/// callers must surface it (a snackbar), never fail silently.
Future<String> stageUpload(
  ExecutionEnv env, {
  required String name,
  required Uint8List bytes,
}) async {
  // A picked name can carry browser-supplied subdirectories
  // (webkitRelativePath); chat attachments flatten into uploads/.
  final base = sanitizeUploadName(name).split('/').last;
  if (base.isEmpty) {
    throw StateError('"$name" has no usable file name.');
  }
  final dirResult = await env.createDir(uploadsDirName);
  if (dirResult.isErr) {
    throw StateError(
      'Could not create $uploadsDirName: ${dirResult.errorOrNull!.message}',
    );
  }
  var candidate = '$uploadsDirName/$base';
  for (var n = 1; (await env.exists(candidate)).valueOrNull ?? false; n++) {
    candidate = '$uploadsDirName/${dedupeUploadName(base, n)}';
  }
  final writeResult = await env.writeBinaryFile(candidate, bytes);
  if (writeResult.isErr) {
    throw StateError(
      'Could not store $base: ${writeResult.errorOrNull!.message}',
    );
  }
  return candidate;
}
