import 'package:flutter_agent_example/html_preview_document.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('lightCanvasDocument', () {
    test('prepends the light-canvas style when there is no doctype', () {
      final result = lightCanvasDocument('<h1>Hi</h1>');

      expect(result, '$lightCanvasStyle<h1>Hi</h1>');
    });

    test('injects right after the doctype so the document stays out of '
        'quirks mode', () {
      final result = lightCanvasDocument('<!DOCTYPE html><h1>Hi</h1>');

      expect(result, '<!DOCTYPE html>$lightCanvasStyle<h1>Hi</h1>');
    });

    test('recognizes the doctype case-insensitively and after leading '
        'whitespace', () {
      final result = lightCanvasDocument('  \n<!doctype html>\n<p>x</p>');

      expect(result, '  \n<!doctype html>$lightCanvasStyle\n<p>x</p>');
    });

    test('leaves the document body untouched after the injection point', () {
      const html = '<!doctype html><style>html{background:#000}</style>';
      final result = lightCanvasDocument(html);

      // The document's own styles come later, so they still win over the
      // injected light canvas.
      expect(
        result,
        '<!doctype html>$lightCanvasStyle'
        '<style>html{background:#000}</style>',
      );
    });

    test('treats a doctype without a closing bracket as no doctype', () {
      const html = '<!doctype';
      final result = lightCanvasDocument(html);

      expect(result, '$lightCanvasStyle$html');
    });

    test('the injected style forces a light canvas and light UA defaults', () {
      expect(
        lightCanvasStyle,
        '<style>html{background:#fff;color-scheme:light}</style>',
      );
    });
  });
}
