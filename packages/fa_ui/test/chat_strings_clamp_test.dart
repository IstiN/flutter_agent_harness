// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// The collapsed tool-output `+N lines` hint: every plural arm of the
/// Russian forms and the English singular/plural split (issue #1848
/// coverage).
void main() {
  group('FaChatStringsEn.chatClampHint', () {
    final strings = FaChatStringsEn();

    test('singular for exactly one line', () {
      expect(strings.chatClampHint(1), '+1 line');
    });

    test('plural otherwise', () {
      expect(strings.chatClampHint(0), '+0 lines');
      expect(strings.chatClampHint(5), '+5 lines');
      expect(strings.chatClampHint(250), '+250 lines');
    });
  });

  group('FaChatStringsRu.chatClampHint', () {
    final strings = FaChatStringsRu();

    test('строка arm: mod10 == 1 and mod100 != 11', () {
      expect(strings.chatClampHint(1), '+1 строка');
      expect(strings.chatClampHint(21), '+21 строка');
      expect(strings.chatClampHint(101), '+101 строка');
    });

    test('строки arm: mod10 2-4 outside the 12-14 window', () {
      expect(strings.chatClampHint(2), '+2 строки');
      expect(strings.chatClampHint(4), '+4 строки');
      expect(strings.chatClampHint(22), '+22 строки');
    });

    test('строк arm: everything else, including the 11/12-14 trap window', () {
      expect(strings.chatClampHint(5), '+5 строк');
      expect(strings.chatClampHint(11), '+11 строк');
      expect(strings.chatClampHint(12), '+12 строк');
      expect(strings.chatClampHint(14), '+14 строк');
      expect(strings.chatClampHint(25), '+25 строк');
      expect(strings.chatClampHint(111), '+111 строк');
      expect(strings.chatClampHint(112), '+112 строк');
    });
  });
}
