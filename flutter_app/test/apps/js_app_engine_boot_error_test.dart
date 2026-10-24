library;

import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// gh-1831 AC4 — the never-rendered boot failure must be READABLE.
///
/// When the web catalog install dropped a multi-file widget's sources, the
/// assembler commented every missing import out and the widget evaluated to
/// an empty script; the 10s watchdog then blamed "the app source likely
/// fails to parse (syntax error)" — wrong cause, wrong remedy. The
/// watchdog now reads the `/* … file not found: … */` markers the
/// assembler leaves and names the missing files (reinstall the app) instead.
///
/// Pure statics — no native JS bridge needed (the engine-boot suites stay
/// bridge-gated).
void main() {
  group('JsAppEngine.missingSourceFiles', () {
    test('finds import and jsr.include markers', () {
      const js = "/* import: file not found: ./game/main.js */\n"
          "jsr.render({type:'column'});\n"
          '/* jsr.include: file not found: ui/hud.js */\n';
      expect(JsAppEngine.missingSourceFiles(js), [
        './game/main.js',
        'ui/hud.js',
      ]);
    });

    test('a healthy assembly has none', () {
      const js = 'var x = 1;\njsr.render({});\n';
      expect(JsAppEngine.missingSourceFiles(js), isEmpty);
    });

    test('markers are deduplicated and order-stable', () {
      const js = "/* import: file not found: ./a.js */\n"
          "/* import: file not found: ./a.js */\n"
          '/* jsr.include: file not found: ./b.js */\n';
      expect(JsAppEngine.missingSourceFiles(js), ['./a.js', './b.js']);
    });
  });

  group('JsAppEngine.bootTimeoutMessage', () {
    test('keeps the parse-error wording when nothing is missing', () {
      final message = JsAppEngine.bootTimeoutMessage(
        appId: 'fa-craft',
        entryFile: 'widget.js',
        waited: '10s',
      );
      expect(message, contains('fa-craft'));
      expect(message, contains('10s'));
      expect(message, contains('fails to parse'));
    });

    test('names the missing sources and the remedy when the install is torn',
        () {
      final message = JsAppEngine.bootTimeoutMessage(
        appId: 'fa-craft',
        entryFile: 'widget.js',
        waited: '10s',
        missingFiles: const ['./game/main.js', './game/blocks.js'],
      );
      expect(message, contains('missing source files'));
      expect(message, contains('./game/main.js'));
      expect(message, contains('./game/blocks.js'));
      expect(message, contains('reinstall'));
      // The wrong cause must not ride along: the sources are not broken.
      expect(message, isNot(contains('syntax error')));
    });
  });
}
