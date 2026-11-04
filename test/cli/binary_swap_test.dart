// issue #2052: the Windows binary swap must never leave the install without a
// runnable executable. Every branch below pins one way that used to happen.
import 'dart:io';

import 'package:flutter_agent_harness/src/cli/binary_swap.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('fa-swap-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String path(String name) => '${tmp.path}${Platform.pathSeparator}$name';

  void writeFile(String name, String content) =>
      File(path(name)).writeAsStringSync(content);

  String readFile(String name) => File(path(name)).readAsStringSync();

  bool exists(String name) => File(path(name)).existsSync();

  group('swapBinary (Windows)', () {
    test('the live binary is parked as .old and the staged one takes over', () {
      writeFile('fa.exe', 'old-binary');
      writeFile('fa.exe.new', 'new-binary');

      swapBinary(
        staging: path('fa.exe.new'),
        target: path('fa.exe'),
        isWindows: true,
      );

      expect(readFile('fa.exe'), 'new-binary');
      expect(readFile('fa.exe.old'), 'old-binary',
          reason: 'one generation is kept for a manual rollback');
      expect(exists('fa.exe.new'), isFalse);
    });

    test('a missing staging file aborts BEFORE the live binary is touched', () {
      writeFile('fa.exe', 'old-binary');

      expect(
        () => swapBinary(
          staging: path('fa.exe.new'),
          target: path('fa.exe'),
          isWindows: true,
        ),
        throwsA(isA<StateError>()),
      );

      expect(readFile('fa.exe'), 'old-binary');
      expect(exists('fa.exe.old'), isFalse,
          reason: 'the aside must not be created for a failed download');
    });

    test('an empty staging file aborts before the live binary is touched', () {
      writeFile('fa.exe', 'old-binary');
      writeFile('fa.exe.new', '');

      expect(
        () => swapBinary(
          staging: path('fa.exe.new'),
          target: path('fa.exe'),
          isWindows: true,
        ),
        throwsA(isA<StateError>()),
      );

      expect(readFile('fa.exe'), 'old-binary');
      expect(exists('fa.exe.old'), isFalse);
    });

    test('a failing rename-in restores the parked binary', () {
      writeFile('fa.exe', 'old-binary');
      writeFile('fa.exe.new', 'new-binary');

      expect(
        () => swapBinary(
          staging: path('fa.exe.new'),
          target: path('fa.exe'),
          isWindows: true,
          rename: (from, to) {
            if (from.endsWith('fa.exe.new')) {
              throw const FileSystemException('staged file is locked');
            }
            File(from).renameSync(to);
          },
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(readFile('fa.exe'), 'old-binary',
          reason: 'the user must keep a runnable fa after a failed swap');
    });

    test('a swap that produces no target surfaces instead of lying', () {
      writeFile('fa.exe', 'old-binary');
      writeFile('fa.exe.new', 'new-binary');

      expect(
        () => swapBinary(
          staging: path('fa.exe.new'),
          target: path('fa.exe'),
          isWindows: true,
          rename: (from, to) {
            // "Succeeds" without producing anything.
            if (from.endsWith('fa.exe.new')) return;
            File(from).renameSync(to);
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(readFile('fa.exe'), 'old-binary');
    });

    test('an install already broken by an earlier update heals itself', () {
      // The state this issue was reported in: fa.exe gone, the previous
      // binary parked as fa.exe.old.
      writeFile('fa.exe.old', 'old-binary');
      writeFile('fa.exe.new', 'new-binary');

      swapBinary(
        staging: path('fa.exe.new'),
        target: path('fa.exe'),
        isWindows: true,
      );

      expect(readFile('fa.exe'), 'new-binary');
    });

    test('neither target nor aside: a named error, not a silent no-op', () {
      writeFile('fa.exe.new', 'new-binary');

      expect(
        () => swapBinary(
          staging: path('fa.exe.new'),
          target: path('fa.exe'),
          isWindows: true,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('reinstall'),
          ),
        ),
      );
    });
  });

  group('swapBinary (Unix)', () {
    test('keeps a .bak copy and marks the new binary executable', () async {
      writeFile('fa', 'old-binary');
      writeFile('fa.new', 'new-binary');
      final calls = <String>[];

      await swapBinary(
        staging: path('fa.new'),
        target: path('fa'),
        isWindows: false,
        runProcess: (executable, arguments) async {
          calls.add('$executable ${arguments.join(' ')}');
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(readFile('fa'), 'new-binary');
      expect(readFile('fa.bak'), 'old-binary');
      expect(calls.single, startsWith('chmod +x '));
    });

    test('a missing staging file still aborts first', () async {
      writeFile('fa', 'old-binary');

      await expectLater(
        swapBinary(
          staging: path('fa.new'),
          target: path('fa'),
          isWindows: false,
        ),
        throwsA(isA<StateError>()),
      );
      expect(readFile('fa'), 'old-binary');
    });
  });
}
