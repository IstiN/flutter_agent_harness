// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/relay/relay_probe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('decideRelay', () {
    test('build flag extension wins even when the probe says no', () {
      final d = decideRelay(buildHost: 'extension', probe: () => false);
      expect(d.hosted, isTrue);
      expect(d.reason, contains('FA_HOST=extension'));
    });

    test('no flag + positive probe → hosted by probe', () {
      final d = decideRelay(buildHost: '', probe: () => true);
      expect(d.hosted, isTrue);
      expect(d.reason, contains('chrome.runtime.id'));
    });

    test('no flag + negative probe → plain web', () {
      final d = decideRelay(buildHost: '', probe: () => false);
      expect(d.hosted, isFalse);
      expect(d.reason, contains('plain web'));
    });

    test('a throwing probe degrades to plain web with the error logged', () {
      final d = decideRelay(
        buildHost: '',
        probe: () => throw StateError('chrome undefined'),
      );
      expect(d.hosted, isFalse);
      expect(d.reason, contains('probe threw'));
      expect(d.reason, contains('chrome undefined'));
    });

    test('unknown build flags are not honored (only "extension")', () {
      final d = decideRelay(buildHost: 'web', probe: () => false);
      expect(d.hosted, isFalse);
    });
  });
}
