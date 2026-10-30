// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// gh-2004 AC7 — the on-device Gema stack removal gate.
///
/// The flutter_gemma + flutter_gemma_litertlm stack (packages, `lib/gemma/`,
/// wiring, settings/model-cache UI, pod plumbing) was removed in gh-2004.
/// This gate makes a re-introduction RED: a future `flutter_gemma` dep or
/// `lib/gemma/` file trips here, so coming back needs a deliberate new
/// card, not an accident.
///
/// Exclusions:
/// - `lib/webllm/` and `lib/transformers_js/` are the two OTHER local-model
///   stacks (gh-2004 non-goals) whose model catalogs legitimately carry
///   Gema-family model names (`onnx-community/gemma-4-E2B-it-ONNX`,
///   `gemma-2-2b-it-q4f16_1-MLC` — the real upstream model ids);
/// - `lib/services/gemma_leftover_cleanup.dart` (+ `gemma_web_artifacts*`)
///   is gh-2004's own removal machinery — it must name the artifacts it
///   deletes.
/// Tokens anywhere else under `lib/` or in `pubspec.yaml` fail the gate.
void main() {
  final appDir = Directory.current.path;
  const pattern = 'gemma|litert|litertlm|mediapipe';
  final regex = RegExp(pattern, caseSensitive: false);

  /// lib files the gate inspects (see the exclusion list above).
  final libFiles = Directory('$appDir/lib')
      .listSync(recursive: true)
      .whereType<File>()
      .map((f) => f.path)
      .where(
        (p) =>
            !p.contains('/lib/webllm/') &&
            !p.contains('/lib/transformers_js/') &&
            !p.contains('gemma_leftover_cleanup') &&
            !p.contains('gemma_web_artifacts'),
      )
      .toList()..sort();

  test('no gema/litert/litertlm/mediapipe tokens under flutter_app/lib',
      () {
    final hits = <String>[];
    for (final path in libFiles) {
      for (final match in regex.allMatches(File(path).readAsStringSync())) {
        hits.add(
          '${path.substring(appDir.length + 1)}:'
          '${File(path).readAsStringSync().substring(0, match.start).split('\n').length}',
        );
      }
    }
    expect(hits, isEmpty, reason: 'gema-stack tokens found at:\n${hits.join('\n')}');
  });

  test('pubspec.yaml carries no gemma/litert packages or pins', () {
    final pubspec = File(
      '$appDir/pubspec.yaml',
    ).readAsStringSync();
    final hits = regex
        .allMatches(pubspec)
        .map((m) => m.group(0)!)
        .toSet();
    expect(hits, isEmpty, reason: 'gema-stack tokens in pubspec.yaml: $hits');
  });

  test('pubspec.lock resolves no gemma/litert/mediapipe packages', () {
    final lock = File('$appDir/pubspec.lock').readAsStringSync();
    final packageNames = RegExp(
      r'^  ([a-z0-9_]+):',
      multiLine: true,
    ).allMatches(lock).map((m) => m.group(1)!).toSet();
    final offenders = packageNames
        .where(
          (name) =>
              name.contains('gemma') ||
              name.contains('litert') ||
              name.contains('mediapipe'),
        )
        .toList();
    expect(offenders, isEmpty);
  });

  test('the lib/gemma and lib/on_device gemma modules stay gone', () {
    expect(Directory('$appDir/lib/gemma').existsSync(), isFalse,
        reason: 'lib/gemma/ was removed in gh-2004');
  });
}
