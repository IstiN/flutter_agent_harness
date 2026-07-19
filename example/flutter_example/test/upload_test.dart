import 'package:flutter_agent_example/upload.dart';
import 'package:flutter_test/flutter_test.dart';

/// Host tests for the upload classification rules: only decodable raster
/// images may ever inline — SVG is markup and always travels as a plain
/// file reference.
void main() {
  group('mimeTypeForUploadName', () {
    test('maps raster extensions to image MIME types', () {
      expect(mimeTypeForUploadName('a.png'), 'image/png');
      expect(mimeTypeForUploadName('a.jpg'), 'image/jpeg');
      expect(mimeTypeForUploadName('a.jpeg'), 'image/jpeg');
      expect(mimeTypeForUploadName('a.gif'), 'image/gif');
      expect(mimeTypeForUploadName('a.webp'), 'image/webp');
    });

    test('is case-insensitive', () {
      expect(mimeTypeForUploadName('PHOTO.JPG'), 'image/jpeg');
      expect(mimeTypeForUploadName('Icon.PNG'), 'image/png');
    });

    test('SVG and anything unrecognized is octet-stream, never an image', () {
      expect(mimeTypeForUploadName('icon.svg'), 'application/octet-stream');
      expect(mimeTypeForUploadName('icon.SVG'), 'application/octet-stream');
      expect(mimeTypeForUploadName('notes.txt'), 'application/octet-stream');
      expect(
        mimeTypeForUploadName('archive.tar.gz'),
        'application/octet-stream',
      );
      expect(mimeTypeForUploadName('no-extension'), 'application/octet-stream');
    });
  });

  group('isInlineImageMimeType', () {
    test('accepts the decodable raster formats', () {
      for (final mime in [
        'image/png',
        'image/jpeg',
        'image/gif',
        'image/webp',
      ]) {
        expect(isInlineImageMimeType(mime), isTrue, reason: mime);
      }
    });

    test('rejects SVG and every other image/* type', () {
      for (final mime in [
        'image/svg+xml',
        'image/bmp',
        'image/tiff',
        'image/avif',
        'image/heic',
        'image/x-icon',
      ]) {
        expect(isInlineImageMimeType(mime), isFalse, reason: mime);
      }
      expect(isInlineImageMimeType('application/octet-stream'), isFalse);
      expect(isInlineImageMimeType('text/plain'), isFalse);
    });
  });
}
