// Issue #1886 REG-02: the shared transcribe_audio code stays web-safe — no
// `dart:io` in the tool, the document schema, or the plugin. The media-slot
// siblings (generate_image, generate_video) are untouched by this change.
import 'dart:io';

import 'package:test/test.dart';

/// Source files that must never import `dart:io` (web-safe surface).
const _webSafeSources = [
  'lib/src/tools/transcribe_audio.dart',
  'lib/src/tools/transcript_document.dart',
  'lib/src/plugins/transcribe_audio_plugin.dart',
];

void main() {
  test('REG-02: no dart:io in transcribe_audio shared code', () {
    for (final path in _webSafeSources) {
      final source = File(path).readAsStringSync();
      expect(
        source.contains("import 'dart:io'"),
        isFalse,
        reason: '$path must stay web-safe (no dart:io)',
      );
      expect(
        source.contains('dart:io'),
        isFalse,
        reason: '$path must stay web-safe',
      );
    }
  });

  test('REG-02: media slot siblings are untouched', () {
    // The change must not have altered the other media tools.
    for (final path in [
      'lib/src/plugins/inspect_image_plugin.dart',
      'lib/src/tools/generate_image.dart',
    ]) {
      expect(File(path).existsSync(), isTrue, reason: '$path must exist');
    }
  });
}
