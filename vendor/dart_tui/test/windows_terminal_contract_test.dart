// The Windows console shim is FFI + Windows-only code (see the
// `coverage:ignore-file` header in lib/src/windows_terminal.dart): the CI
// runners are macOS/Linux, so its behaviour cannot be executed there. This
// contract test pins the parts a future edit could silently drop — the input
// CODE PAGE switch that makes Cyrillic keystrokes arrive as UTF-8, and its
// restore on teardown.
import 'dart:io';

import 'package:test/test.dart';

void main() {
  final source = File('lib/src/windows_terminal.dart').readAsStringSync();

  test('raw mode switches the console input code page to UTF-8', () {
    expect(source, contains('GetConsoleCP'));
    expect(source, contains('SetConsoleCP'));
    expect(source, contains('const int _utf8CodePage = 65001;'));
    expect(
      source,
      contains('setConsoleCP(_utf8CodePage);'),
      reason: 'a legacy OEM input page sends one byte per Cyrillic character, '
          'which the UTF-8 parser cannot decode (fa: cannot type Russian)',
    );
  });

  test('the previous code page is restored on teardown', () {
    expect(source, contains('_savedCodePage ??= previousCp;'));
    expect(
      source,
      contains("lookupFunction<_SetConsoleCpC, _SetConsoleCpD>('SetConsoleCP')(savedCp);"),
      reason: 'the shell must not inherit UTF-8 if the user had another page',
    );
  });
}
