// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/firebase_options.dart';
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('DefaultFirebaseOptions.currentPlatform', () {
    test('every registered platform maps to its options', () {
      void expectFor(TargetPlatform platform, FirebaseOptions expected) {
        debugDefaultTargetPlatformOverride = platform;
        expect(DefaultFirebaseOptions.currentPlatform, same(expected));
      }

      expectFor(TargetPlatform.android, DefaultFirebaseOptions.android);
      expectFor(TargetPlatform.iOS, DefaultFirebaseOptions.ios);
      expectFor(TargetPlatform.macOS, DefaultFirebaseOptions.macos);
    });

    test('unregistered platforms throw a platform-specific explanation', () {
      void expectUnsupported(String message) {
        expect(
          () => DefaultFirebaseOptions.currentPlatform,
          throwsA(
            isA<UnsupportedError>().having(
              (error) => error.message,
              'message',
              message,
            ),
          ),
        );
      }

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expectUnsupported(
        'Firebase is not configured for Windows in this project.',
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expectUnsupported(
        'Firebase is not configured for Linux in this project.',
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
      expect(
        () => DefaultFirebaseOptions.currentPlatform,
        throwsA(
          isA<UnsupportedError>().having(
            (error) => error.message,
            'message',
            contains('TargetPlatform.fuchsia'),
          ),
        ),
      );
    });
  });

  test('optionsFor is null exactly for unregistered platforms', () {
    expect(DefaultFirebaseOptions.optionsFor(TargetPlatform.android), isNotNull);
    expect(DefaultFirebaseOptions.optionsFor(TargetPlatform.iOS), isNotNull);
    expect(DefaultFirebaseOptions.optionsFor(TargetPlatform.macOS), isNotNull);
    expect(DefaultFirebaseOptions.optionsFor(TargetPlatform.windows), isNull);
    expect(DefaultFirebaseOptions.optionsFor(TargetPlatform.linux), isNull);
    expect(DefaultFirebaseOptions.optionsFor(TargetPlatform.fuchsia), isNull);
  });
}
