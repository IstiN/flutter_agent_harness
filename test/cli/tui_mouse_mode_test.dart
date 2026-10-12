// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/src/cli/tui_mouse_mode.dart';
import 'package:test/test.dart';

void main() {
  group('parseTuiMouseMode', () {
    test('truthy values resolve to on, case-insensitive and trimmed', () {
      for (final v in ['1', 'true', 'yes', 'on', 'ON', ' True ', 'YES']) {
        expect(parseTuiMouseMode(v), TuiMouseMode.on, reason: '$v → on');
      }
    });

    test('falsy values resolve to off', () {
      for (final v in ['0', 'false', 'no', 'FALSE', ' No ']) {
        expect(parseTuiMouseMode(v), TuiMouseMode.off, reason: '$v → off');
      }
    });

    test('null, empty, and unknown values default to auto', () {
      expect(parseTuiMouseMode(null), TuiMouseMode.auto);
      expect(parseTuiMouseMode(''), TuiMouseMode.auto);
      expect(parseTuiMouseMode('   '), TuiMouseMode.auto);
      expect(parseTuiMouseMode('y'), TuiMouseMode.auto);
      expect(parseTuiMouseMode('enabled'), TuiMouseMode.auto);
    });
  });
}
