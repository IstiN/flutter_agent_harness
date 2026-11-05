// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import '../src/settings_merge.dart';
import 'package:test/test.dart';

void main() {
  group('mergeProvider (settings_put field-level merge)', () {
    test('empty incoming fields keep the stored values', () {
      final merged = mergeProvider(
        const {
          'baseUrl': 'https://api.z.ai/api/paas/v4',
          'apiKey': 'old-key',
          'model': 'glm-5.3-flash',
        },
        const {'baseUrl': '', 'apiKey': '', 'model': ''},
      );
      expect(merged, {
        'baseUrl': 'https://api.z.ai/api/paas/v4',
        'apiKey': 'old-key',
        'model': 'glm-5.3-flash',
        'contextWindow': null,
        'contextWindowCap': null,
      });
    });

    test('non-empty incoming fields win', () {
      final merged = mergeProvider(
        const {
          'baseUrl': 'https://old.example/v1',
          'apiKey': 'old',
          'model': 'old-model',
        },
        const {
          'baseUrl': 'https://new.example/v1',
          'apiKey': 'new-key',
          'model': 'new-model',
        },
      );
      expect(merged, {
        'baseUrl': 'https://new.example/v1',
        'apiKey': 'new-key',
        'model': 'new-model',
        'contextWindow': null,
        'contextWindowCap': null,
      });
    });

    test('absent stored values stay empty', () {
      final merged = mergeProvider(null, const {
        'baseUrl': 'https://api.z.ai/api/paas/v4',
        'apiKey': 'k',
        'model': '',
      });
      expect(merged, {
        'baseUrl': 'https://api.z.ai/api/paas/v4',
        'apiKey': 'k',
        'model': '',
        'contextWindow': null,
        'contextWindowCap': null,
      });
    });

    test('non-string incoming values are ignored safely', () {
      final merged = mergeProvider(
        const {'baseUrl': 'https://a/v1', 'apiKey': 'k', 'model': 'm'},
        const {
          'baseUrl': 42,
          'apiKey': null,
          'model': ['x'],
        },
      );
      expect(merged, {
        'baseUrl': 'https://a/v1',
        'apiKey': 'k',
        'model': 'm',
        'contextWindow': null,
        'contextWindowCap': null,
      });
    });

    test('gh-2059 AC7: an incoming window override wins over the stored', () {
      final merged = mergeProvider(
        const {
          'baseUrl': 'https://a/v1',
          'apiKey': 'k',
          'model': 'm',
          'contextWindow': 128000,
          'contextWindowCap': null,
        },
        const {
          'baseUrl': '', // key not retyped
          'apiKey': '',
          'model': 'bigger-model',
          'contextWindow': 264000,
        },
      );
      expect(merged, {
        'baseUrl': 'https://a/v1',
        'apiKey': 'k',
        'model': 'bigger-model',
        'contextWindow': 264000,
        'contextWindowCap': null,
      });
    });

    test('gh-2059 AC7: a partial save keeps the stored window and cap', () {
      final merged = mergeProvider(
        const {
          'baseUrl': 'https://a/v1',
          'apiKey': 'k',
          'model': 'm',
          'contextWindow': 264000,
          'contextWindowCap': 128000,
        },
        const {
          'baseUrl': 'https://b/v1',
          'apiKey': 'k2',
          'model': 'm2',
          // no window keys at all
        },
      );
      expect(merged['contextWindow'], 264000);
      expect(merged['contextWindowCap'], 128000);
    });
  });
}
