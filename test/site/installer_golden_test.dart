// gh-1596 UT-2 — golden drift: every emitted installer is byte-identical
// to a fresh regeneration from its sources. The sources now include the
// LIVE provider catalog (`provider_catalog.dart`), the live approval-mode
// enum and the CLI's offline model presets — so a catalog change without
// `dart run scripts/gen_installers.dart` fails here (AC6's drift hook,
// extended to the data sections).
//
// The renderer is imported as a library: `renderInstallers()` is pure
// (returns the artifact contents, no writes), so the test never mutates
// the working tree.
import 'dart:io';

import 'package:test/test.dart';

import '../../scripts/gen_installers.dart' as gen;

String _repoRoot() {
  var dir = Directory.current;
  while (true) {
    if (Directory('${dir.path}/site').existsSync() &&
        Directory('${dir.path}/scripts').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('run from inside the flutter_agent repo');
    }
    dir = parent;
  }
}

void main() {
  final root = _repoRoot();
  final rendered = gen.renderInstallers();

  test('the renderer covers every generated installer artifact', () {
    expect(rendered.keys.toSet(), {
      'site/install.sh',
      'site/install.ps1',
      'site/install.bat',
      'site/setup.sh',
      'site/setup.ps1',
    });
  });

  for (final artifact in rendered.keys) {
    test('$artifact is byte-identical to a fresh regeneration (UT-2)', () {
      final committed = File('$root/$artifact').readAsStringSync();
      expect(
        committed,
        rendered[artifact],
        reason:
            '$artifact drifted from its sources (template + yaml + '
            'live catalog). Regenerate and commit:\n'
            '  dart run scripts/gen_installers.dart',
      );
    });
    if (artifact.endsWith('.ps1')) {
      // gh-1945: the served .ps1 is consumed through `irm | iex`, and GitHub
      // Pages serves it as application/octet-stream with no charset —
      // Windows PowerShell 5.1 decodes the body as ISO-8859-1, so a BOM
      // becomes the literal text `ï»¿` glued to line 1, the leading `#`
      // stops being a comment and the install fails with "The term 'ï»¿#'
      // is not recognized". The artifact must stay BOM-less: position 0 is
      // plain ASCII `#`, which is decode-invariant in every ANSI code page,
      // while the non-ASCII glyphs sit inside comments/string literals where
      // a Latin-1 mis-decode is cosmetic, never syntactic.
      // (readAsStringSync strips a BOM, so assert bytes.)
      test('$artifact is served/piped BOM-less (gh-1945)', () {
        final bytes = File('$root/$artifact').readAsBytesSync();
        expect(
          bytes.sublist(0, 3),
          isNot([0xEF, 0xBB, 0xBF]),
          reason:
              '$artifact carries a UTF-8 BOM — Windows PowerShell 5.1 '
              'decodes the irm|iex pipe as ISO-8859-1 and chokes on the '
              "`ï»¿#` first line (gh-1945)",
        );
      });
    }
  }

  test('install.ps1 copies bundle version.txt next to fa.exe (gh-1945)', () {
    final ps = rendered['site/install.ps1']!;
    // The CLI's _packageVersion() probes <exe_dir>/version.txt in the
    // installer layout; without it `fa --version` reports the hardcoded
    // 0.1.0 fallback even for a fresh release binary.
    expect(ps, contains(r'Copy-Item $srcVersion (Join-Path $binDir "version.txt") -Force'));
    // Guarded like the lib copy — a bundle without the stamp must not fail
    // the install.
    expect(ps, contains(r'Test-Path $srcVersion'));
  });

  test('install.ps1 prints a cmd-safe recipe under the bat wrapper (gh-1945)', () {
    final ps = rendered['site/install.ps1']!;
    // install.bat delegates here from cmd.exe, where `irm` and `$env:` do
    // not exist — the completion recipe must speak the host shell.
    expect(ps, contains(r'if ($env:FA_INSTALL_VIA -eq "cmd") {'));
    expect(
      ps,
      contains(
        'powershell -NoProfile -ExecutionPolicy Bypass -Command '
        '"irm https://fa1.dev/setup.ps1 | iex"',
      ),
    );
    expect(ps, contains('set OPENROUTER_API_KEY=<your-key>'));
    // The PowerShell-native recipe stays the default for direct irm|iex runs.
    expect(ps, contains('Write-Host "    irm https://fa1.dev/setup.ps1 | iex"'));
  });

  test('install.bat flags the cmd shell for the installer recipe (gh-1945)', () {
    final bat = rendered['site/install.bat']!;
    expect(bat, contains('set "FA_INSTALL_VIA=cmd"'));
  });
}
