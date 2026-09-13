import 'package:dart_tui/src/editor.dart';
import 'package:test/test.dart';
LineEditor type(String s) { var e = const LineEditor.empty(); for (final c in s.split('')) { e = e.insert(c); } return e; }
void main() {
  test('dump groups', () {
    final e = type('hello world');
    var i = 0;
    for (final s in e.undoStack) { print('#$i [${s.buffer.text}] ${s.group}'); i++; }
  });
}
