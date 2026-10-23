// gh-180 rework — Windows checkout guard for the Binaries (PR) legs.
//
// The gh-180 rework branch went red on BOTH binaries checks
// (run 39951221058, head 538b4668, 2026-10-23): a WIP auto-save swept two
// zero-byte redirect artifacts named `:debug,` and `:release,` onto the
// branch (2fb405b29d), and git-for-windows refuses to check out ANY path
// with a Win32-invalid character:
//
//   error: invalid path ':debug,'
//   The process 'C:\Program Files\Git\bin\git.exe' failed with exit code 128
//
// One junk file therefore fails the whole `binaries-pr` matrix before a
// single step runs, and the `Binaries smoke gate` needs-gate fails with it
// — while every Linux leg stays green, so only the Windows jobs expose it.
// This guard runs in the default suite on the Linux legs and fails loud
// when a tracked path could not be checked out on Windows, so the junk is
// caught on the PR (and by the pre-commit fast gate) instead of at CI.
//
// What git-for-windows rejects (compat/mingw.c is_invalid_dos_char):
//   - the characters < > : " | ? * anywhere in a path component
//     (`/` and `\` are separators and are checked per component here);
//   - components ending in a dot or a space;
//   - the reserved DOS device names CON, PRN, AUX, NUL, COM1-9, LPT1-9
//     as a component, with or without an extension.
import 'dart:io';

import 'package:test/test.dart';

final _win32InvalidChars = RegExp(r'[<>:"|?*]');

final _reservedDosDevice = RegExp(
  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$',
  caseSensitive: false,
);

void main() {
  test('every tracked path is checkoutable on Windows '
      '(no <>:"|?* characters, no trailing dots/spaces, '
      'no reserved DOS device names)', () {
    final r = Process.runSync('git', ['ls-files', '-z']);
    expect(
      r.exitCode,
      0,
      reason: 'git ls-files must run from the repo root: ${r.stderr}',
    );
    final paths = (r.stdout as String)
        .split('\x00')
        .where((p) => p.isNotEmpty)
        .toList();
    expect(
      paths,
      isNotEmpty,
      reason: 'git ls-files returned nothing — is this the repo root?',
    );

    final offenders = <String>[];
    for (final path in paths) {
      for (final component in path.split('/')) {
        final invalid = _win32InvalidChars.firstMatch(component);
        if (invalid != null) {
          offenders.add(
            '$path — component "$component" contains the Win32-invalid '
            'character "${invalid[0]}" (git-for-windows checkout fails '
            'with "error: invalid path")',
          );
          break;
        }
        if (component != component.replaceFirst(RegExp(r'[. ]+$'), '')) {
          offenders.add(
            '$path — component "$component" ends with a dot/space '
            '(Windows silently strips or rejects it at checkout)',
          );
          break;
        }
        if (_reservedDosDevice.hasMatch(component)) {
          offenders.add(
            '$path — component "$component" is a reserved DOS device '
            'name (git-for-windows checkout fails with "invalid path")',
          );
          break;
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'these tracked paths cannot be checked out on Windows — every '
          'windows-latest job (binaries-pr matrix) fails before its first '
          'step; remove the files or rename them: \n  '
          '${offenders.join('\n  ')}',
    );
  });
}
