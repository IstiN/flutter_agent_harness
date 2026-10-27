import 'dart:io';

import 'package:fa_llm/src/utils/dotenv_loader.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fah_dotenv_loader_test');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  String write(String name, String contents) {
    final file = File('${dir.path}/$name')..writeAsStringSync(contents);
    return file.path;
  }

  test('missing file yields an empty map', () {
    expect(loadDotEnv('${dir.path}/absent.env'), isEmpty);
  });

  test('parses key/value pairs, skipping blanks and comments', () {
    final path = write('basic.env', '''
# leading comment
   # indented comment

PLAIN=value
  PADDED  =  padded value
''');
    expect(loadDotEnv(path), {'PLAIN': 'value', 'PADDED': 'padded value'});
  });

  test('lines without "=" are skipped', () {
    final path = write('no_equals.env', 'JUST_TOKENS\nNEXT=1\n');
    expect(loadDotEnv(path), {'NEXT': '1'});
  });

  test('empty key is skipped and only the first "=" splits', () {
    final path = write(
      'split.env',
      '=orphan\nURL=https://example.test/?a=1&b=2\n',
    );
    expect(loadDotEnv(path), {'URL': 'https://example.test/?a=1&b=2'});
  });

  test('a later duplicate key overrides the earlier one', () {
    final path = write('duplicate.env', 'KEY=first\nKEY=second\n');
    expect(loadDotEnv(path), {'KEY': 'second'});
  });
}
