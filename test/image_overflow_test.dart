// Issue #1750 UT-4 — the image-cap refusal detector: the pinned
// Google-shape fixture classifies to (modelId, learnedCap); near-misses
// and unrelated errors never match (AC5).

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  test('the pinned refusal string classifies to (modelId, cap)', () {
    final refusal = classifyImageCapError(
      'error: 400: too many images: maximum allowed for model '
      'gemini-4-argon is 10, got 15',
    );
    expect(refusal, isNotNull);
    expect(refusal!.modelId, 'gemini-4-argon');
    expect(refusal.learnedCap, 10);
  });

  test('case-insensitive and mid-message matches work', () {
    expect(
      classifyImageCapError(
        '400 {"error":{"message":"Too Many Images: maximum allowed for '
        'model m-1 is 3"}}',
      )!.learnedCap,
      3,
    );
  });

  test('near-miss: cap text WITHOUT "too many images" never matches (AC5)', () {
    expect(
      classifyImageCapError(
        '400: maximum allowed for model gemini-4-argon is 10, got 15',
      ),
      isNull,
    );
  });

  test(
    'near-miss: "too many images" without a parseable cap never matches',
    () {
      expect(
        classifyImageCapError(
          '400: too many images in request for model gemini-4-argon',
        ),
        isNull,
      );
    },
  );

  test('unrelated errors never match (AC5)', () {
    expect(classifyImageCapError(null), isNull);
    expect(classifyImageCapError(''), isNull);
    expect(classifyImageCapError('429: rate limit exceeded'), isNull);
    expect(classifyImageCapError('401: invalid api key'), isNull);
    expect(
      classifyImageCapError(
        '400: The input token count (1196265) exceeds the maximum number '
        'of tokens allowed (1048575)',
      ),
      isNull,
    );
  });

  test('a degenerate cap still classifies — the caller guards (E3)', () {
    final refusal = classifyImageCapError(
      '400: too many images: maximum allowed for model m-0 is 0, got 15',
    );
    expect(refusal, isNotNull);
    expect(refusal!.learnedCap, 0);
  });
}
