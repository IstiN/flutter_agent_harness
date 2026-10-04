import 'package:flutter_agent_harness/src/utils/list_equals.dart';
import 'package:test/test.dart';

void main() {
  test('length mismatch is never equal', () {
    expect(listEquals(<int>[1], <int>[1, 2]), isFalse);
    expect(listEquals(<String>['a'], <String>[]), isFalse);
  });

  test('element mismatch is not equal', () {
    expect(listEquals(<int>[1, 2, 3], <int>[1, 2, 4]), isFalse);
  });

  test('identical contents are equal, including empty', () {
    expect(listEquals(<int>[1, 2, 3], <int>[1, 2, 3]), isTrue);
    expect(listEquals(<String>[], <String>[]), isTrue);
  });
}
