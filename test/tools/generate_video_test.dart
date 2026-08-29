import 'package:flutter_agent_harness/src/tools/generate_video.dart';
import 'package:test/test.dart';

void main() {
  group('MiniMaxVideoDialect.sizeFor', () {
    final dialect = MiniMaxVideoDialect();

    test('null size defaults to 2K 16:9', () {
      final result = dialect.sizeFor(null);
      expect(result.resolution, '2K');
      expect(result.ratio, '16:9');
    });

    test('empty size defaults to 2K 16:9', () {
      final result = dialect.sizeFor('');
      expect(result.resolution, '2K');
      expect(result.ratio, '16:9');
    });

    test('1920x1080 maps to 2K 16:9', () {
      final result = dialect.sizeFor('1920x1080');
      expect(result.resolution, '2K');
      expect(result.ratio, '16:9');
    });

    test('1280x720 maps to 1080P 16:9', () {
      final result = dialect.sizeFor('1280x720');
      expect(result.resolution, '1080P');
      expect(result.ratio, '16:9');
    });

    test('1024x1024 maps to 1080P 1:1', () {
      final result = dialect.sizeFor('1024x1024');
      expect(result.resolution, '1080P');
      expect(result.ratio, '1:1');
    });

    test('invalid format falls back to 2K 16:9', () {
      final result = dialect.sizeFor('large');
      expect(result.resolution, '2K');
      expect(result.ratio, '16:9');
    });

    test('single dimension falls back to 2K 16:9', () {
      final result = dialect.sizeFor('1920');
      expect(result.resolution, '2K');
      expect(result.ratio, '16:9');
    });

    test('zero width falls back to 2K 16:9', () {
      final result = dialect.sizeFor('0x1080');
      expect(result.resolution, '2K');
      expect(result.ratio, '16:9');
    });

    test('negative height falls back to 2K 16:9', () {
      final result = dialect.sizeFor('1920x-1080');
      expect(result.resolution, '2K');
      expect(result.ratio, '16:9');
    });
  });

  group('MiniMaxVideoDialect.matches', () {
    final dialect = MiniMaxVideoDialect();

    test('matches minimax baseUrl', () {
      expect(
        dialect.matches(
          const VideoEndpoint(
            baseUrl: 'https://api.minimax.io/v1',
            modelId: 'MiniMax-H3',
            apiKey: 'k',
          ),
        ),
        isTrue,
      );
    });

    test('does not match openai baseUrl', () {
      expect(
        dialect.matches(
          const VideoEndpoint(
            baseUrl: 'https://api.openai.com/v1',
            modelId: 'x',
            apiKey: 'k',
          ),
        ),
        isFalse,
      );
    });
  });
}
