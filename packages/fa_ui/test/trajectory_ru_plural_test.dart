// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Russian plural classifier (`_ruPlural` behind every countable Ru
/// string): one / few / many, with the 11 and 12–14 exceptions. Exercised
/// through `statsTurns` (ход / хода / ходов — three distinct endings, so
/// every classifier branch has a distinct observable).
void main() {
  test('_ruPlural: mod10 == 1 outside 11 picks "one"', () {
    const ru = TrajectoryStringsRu();
    expect(ru.statsTurns(1), '1 ход');
    expect(ru.statsTurns(21), '21 ход');
    expect(ru.statsTurns(101), '101 ход');
  });

  test('_ruPlural: mod10 == 1 with mod100 == 11 picks "many"', () {
    const ru = TrajectoryStringsRu();
    expect(ru.statsTurns(11), '11 ходов');
    expect(ru.statsTurns(111), '111 ходов');
  });

  test('_ruPlural: mod10 2–4 outside the 12–14 band picks "few"', () {
    const ru = TrajectoryStringsRu();
    expect(ru.statsTurns(2), '2 хода');
    expect(ru.statsTurns(4), '4 хода');
    expect(ru.statsTurns(22), '22 хода');
    expect(ru.statsTurns(24), '24 хода');
  });

  test('_ruPlural: mod10 2–4 inside the 12–14 band picks "many"', () {
    const ru = TrajectoryStringsRu();
    expect(ru.statsTurns(12), '12 ходов');
    expect(ru.statsTurns(14), '14 ходов');
    expect(ru.statsTurns(112), '112 ходов');
  });

  test('_ruPlural: everything else (0, 5–9, teens, tens) picks "many"', () {
    const ru = TrajectoryStringsRu();
    expect(ru.statsTurns(0), '0 ходов');
    expect(ru.statsTurns(5), '5 ходов');
    expect(ru.statsTurns(9), '9 ходов');
    expect(ru.statsTurns(10), '10 ходов');
    expect(ru.statsTurns(20), '20 ходов');
  });

  test('_ruPlural: the same classifier serves the other countable strings', () {
    const ru = TrajectoryStringsRu();
    expect(ru.summarySteps(1), '1 шаг');
    expect(ru.summarySteps(3), '3 шага');
    expect(ru.summarySteps(13), '13 шагов');
    expect(ru.unitChars(1), '1 символ');
    expect(ru.unitChars(2), '2 символа');
    expect(ru.unitChars(7), '7 символов');
  });
}
