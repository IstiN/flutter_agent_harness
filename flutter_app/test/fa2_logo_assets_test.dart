// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:fa/ui/widgets/fa_mark.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const bubbleV2 =
      'M20 22 H64 A8 8 0 0 1 72 30 V46 A8 8 0 0 1 64 54 '
      'H38 L26 62 V54 H20 A8 8 0 0 1 12 46 V30 '
      'A8 8 0 0 1 20 22 Z';

  test('every canonical SVG surface uses Squircle-V2 geometry', () {
    final sources = <String, String>{
      'in-app dark mark': kFaBrandTileDarkSvg,
      'in-app light mark': kFaBrandTileLightSvg,
      'launcher SVG': File('icon/icon.svg').readAsStringSync(),
      'favicon SVG': File('web/favicon.svg').readAsStringSync(),
    };
    for (final entry in sources.entries) {
      expect(
        entry.value,
        contains(bubbleV2),
        reason: '${entry.key} must use the Squircle-V2 bubble',
      );
      expect(
        entry.value,
        contains('M52 28 L57 33 L52 38'),
        reason: '${entry.key} must use the compact upper-right prompt',
      );
      expect(
        entry.value,
        contains('cx="60" cy="46" r="3"'),
        reason: '${entry.key} must keep the V2 agent dot',
      );
      expect(
        entry.value,
        isNot(contains('M20 20 H64')),
        reason: '${entry.key} must not retain the retired V4 bubble',
      );
    }
  });
}
