// gh-2007 review thread 1 — the PR added `export 'src/tools/generate_image.dart';`
// to the public barrel, and that broke 5 CI checks at once:
//
// - `generate_image.dart` DEFINES `MediaKeyResolver`, `MediaEndpoint`,
//   `generateImageTool` and `generateImageToolName`; `flutter_app` carries
//   its own parallel copies of those exact names
//   (`package:fa/services/media_tools.dart`,
//   `package:fa_ui/src/stores/media_models_store.dart`,
//   `package:fa_ui/src/chat/media_tool_names.dart`) in files that also
//   import this barrel — so the export turned every app-side compile into
//   ambiguous-import errors (flutter analyze, build web, extension size
//   gate, office add-in suite, build android/ios/macos).
// - It also made the direct `src/tools/generate_image.dart` imports in
//   test/tools/generate_image_test.dart and
//   test/tools/generate_media_cancel_test.dart redundant
//   (unnecessary_import infos → `dart analyze --fatal-infos` fails).
//
// Guard: the barrel must never re-export `generate_image.dart` (the
// generate-image API surface stays reachable via direct `src/` imports
// only). Same static pattern as the ci_* guard tests.
import 'dart:io';

import 'package:test/test.dart';

const barrelPath = 'lib/flutter_agent_harness.dart';

void main() {
  test('the public barrel does not export src/tools/generate_image.dart '
      '(its MediaKeyResolver/MediaEndpoint/generateImageTool names collide '
      'with flutter_app\'s parallel copies)', () {
    final barrel = File(barrelPath).readAsStringSync();
    final exports = RegExp(r"^export '([^']+)';", multiLine: true)
        .allMatches(barrel)
        .map((m) => m.group(1)!)
        .toList();
    expect(exports, isNotEmpty, reason: 'sanity: the barrel parses');
    expect(
      exports.where((path) => path.endsWith('generate_image.dart')),
      isEmpty,
      reason:
          'exporting generate_image.dart makes MediaKeyResolver, '
          'MediaEndpoint, generateImageTool and generateImageToolName '
          'ambiguous in every flutter_app file that imports the barrel '
          'alongside fa_ui\'s own copies — and turns the direct src/ '
          'imports in test/tools/generate_image_test.dart and '
          'test/tools/generate_media_cancel_test.dart into '
          'unnecessary_import infos (--fatal-infos red). '
          'Found: $exports',
    );
  });
}
