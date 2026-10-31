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
    expect(
      ps,
      contains(
        r'Copy-Item $srcVersion (Join-Path $binDir "version.txt") -Force',
      ),
    );
    // Guarded like the lib copy — a bundle without the stamp must not fail
    // the install.
    expect(ps, contains(r'Test-Path $srcVersion'));
  });

  test(
    'install.ps1 prints a cmd-safe recipe under the bat wrapper (gh-1945)',
    () {
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
      expect(
        ps,
        contains('Write-Host "    irm https://fa1.dev/setup.ps1 | iex"'),
      );
    },
  );

  test(
    'install.bat flags the cmd shell for the installer recipe (gh-1945)',
    () {
      final bat = rendered['site/install.bat']!;
      expect(bat, contains('set "FA_INSTALL_VIA=cmd"'));
    },
  );

  test('install.bat stays cmd.exe-safe: CRLF endings, ASCII body (gh-1945)', () {
    final renderedBat = rendered['site/install.bat']!;
    // cmd.exe seeks a .bat by BYTE offset and re-reads it as it executes, so
    // LF-only endings make it resume mid-line and run fragments of the next
    // comment (`'. was unexpected at this time.'`) — PowerShell is never
    // reached. A Linux checkout regenerates from LF sources, so the renderer
    // must force CRLF itself instead of inheriting it from the checkout.
    expect(
      RegExp(r'(?<!\r)\n').hasMatch(renderedBat),
      isFalse,
      reason:
          'the rendered install.bat carries a lone LF — cmd.exe loses its '
          'byte offset and executes fragments of the next line',
    );

    final committed = String.fromCharCodes(
      File('$root/site/install.bat').readAsBytesSync(),
    );
    expect(
      RegExp(r'(?<!\r)\n').hasMatch(committed),
      isFalse,
      reason:
          'site/install.bat is committed with a lone LF — commit it with CRLF '
          '(the renderer normalises, and .gitattributes pins the checkout)',
    );
    // Multi-byte UTF-8 glyphs are what turn the mis-seek into executable
    // command fragments, so the batch body must stay pure ASCII.
    expect(
      File('$root/site/install.bat')
          .readAsBytesSync()
          .where((b) => b >= 0x80),
      isEmpty,
      reason:
          'site/install.bat must be ASCII-only — box drawing / em dashes in a '
          'batch file reach cmd.exe as command fragments under LF endings',
    );
  });

  test('install.bat reports a failed install instead of success (gh-1945)', () {
    final bat = rendered['site/install.bat']!;
    // The wrapper used to print "fa is ready" even when PowerShell aborted
    // before downloading anything — the failure must be fatal and visible.
    expect(bat, contains('if errorlevel 1 goto :fa_install_failed'));
    expect(bat, contains(':fa_install_failed'));
    expect(bat, contains('exit /b 1'));
    expect(
      bat.indexOf('if errorlevel 1 goto :fa_install_failed'),
      lessThan(bat.indexOf('fa is ready in THIS console')),
      reason: 'the success banner must only be reachable on the success path',
    );
  });

  test('install.ps1 resolves LOCALAPPDATA in a shell without one (gh-1945)', () {
    final ps = rendered['site/install.ps1']!;
    // LOCALAPPDATA / APPDATA come from the per-logon volatile environment, not
    // from HKCU\Environment: a process spawned by a service, a scheduled task
    // or a supervisor app can inherit neither, and `Join-Path
    // $env:LOCALAPPDATA "Fa"` then throws under $ErrorActionPreference = Stop
    // before anything is downloaded.
    expect(
      ps,
      contains(
        r"$env:LOCALAPPDATA = [Environment]::GetFolderPath"
        "('LocalApplicationData')",
      ),
    );
    expect(ps, contains(r'if (-not $env:LOCALAPPDATA -and $env:USERPROFILE) {'));
    expect(ps, contains(r"if (-not $env:APPDATA -and $env:USERPROFILE) {"));
    expect(ps, contains('cannot resolve LOCALAPPDATA'));
    // TEMP is the same class of hazard: archive + extraction paths hang off it.
    expect(ps, contains(r'if (-not $env:TEMP) {'));
    // The install directory must be resolved after the fallbacks, never before.
    expect(
      ps.indexOf(r"GetFolderPath('LocalApplicationData')"),
      lessThan(ps.indexOf(r'$installDir = Join-Path $env:LOCALAPPDATA "Fa"')),
      reason: 'the fallback must run before the install dir is computed',
    );
  });

  test('install.ps1 retries the published x64 bundle on ARM64 (gh-1945)', () {
    final ps = rendered['site/install.ps1']!;
    // Only fa-windows-x64.zip is published (scripts/release_required_assets.txt):
    // an arm64 lookup 404s, and the installer used to drop straight to the
    // Dart fallback even though the x64 build runs under Windows' emulation.
    expect(
      ps,
      contains(
        r"$candidates = if ($arch -eq 'arm64') { @('arm64', 'x64') } else { @($arch) }",
      ),
    );
    expect(ps, contains('runs under x64 emulation'));
    // A non-404 failure (TLS, disk, truncated zip) must not be masked by
    // retrying another asset.
    expect(ps, contains(r'if ($status -ne 404) { break }'));
  });

  test('install.ps1 fails hard on an unexpected bundle layout (gh-1945)', () {
    final ps = rendered['site/install.ps1']!;
    // Copying lib/ and reporting success with no executable is exactly how an
    // install "succeeds" while `fa` is still missing on PATH.
    expect(ps, contains('the downloaded bundle has no bin\\fa.exe'));
    expect(ps, contains(r'function Install-FaBundle([string]$archName)'));
  });

  test('the piped installers never call exit (gh-1945)', () {
    // Both scripts are documented as `irm ... | iex`; `exit` there closes the
    // caller's console instead of merely failing the script.
    for (final artifact in ['site/install.ps1', 'site/setup.ps1']) {
      final text = rendered[artifact]!;
      expect(
        RegExp(r'^\s*exit\b', multiLine: true).hasMatch(text),
        isFalse,
        reason:
            '$artifact calls exit - under `irm | iex` that closes the '
            'user console window; use throw/return instead',
      );
    }
  });

  test('install.ps1 refuses to overwrite a running Fa (gh-1945)', () {
    final ps = rendered['site/install.ps1']!;
    // Windows locks a running executable: an in-place upgrade over an open TUI
    // failed with a bare "being used by another process" and then slid into
    // the Dart fallback, telling the user no binary had been published.
    expect(ps, contains(r'Get-Process -Name fa, fah'));
    expect(ps, contains('Close every Fa window, then run the installer again.'));
    expect(ps, contains('catch [System.IO.IOException]'));
  });

  test('setup.ps1 finds a just-installed CLI before PATH refreshes (gh-1945)', () {
    final ps = rendered['site/setup.ps1']!;
    // The installer writes the *user* PATH, which only new logons read: run
    // right after it, the wizard used to report "fa is not installed".
    expect(ps, contains(r"$faBin = Join-Path $faLocalRoot 'Fa\bin'"));
    expect(ps, contains('PATH is refreshed for new windows only'));
  });

  test(
    'cmd set hint is paste-safe — no # tail on the printed line (gh-1945)',
    () {
      final ps = rendered['site/install.ps1']!;
      // cmd.exe has no comment syntax: a trailing `# or ...` on the printed
      // `set` line is silently included in the value when the user pastes it
      // verbatim (auth then fails non-obviously). The PowerShell/sh recipes
      // may keep `#` tails — those shells treat it as a comment.
      final setLines = ps
          .split('\n')
          .where((l) => l.contains('set OPENROUTER_API_KEY=<your-key>'))
          .toList();
      expect(setLines, hasLength(1), reason: 'exactly one cmd set hint');
      expect(
        setLines.single,
        isNot(contains('#')),
        reason:
            'the cmd set line must be paste-safe — move the alternatives '
            'onto their own hint line (cmd has no comments)',
      );
      // The alternatives stay visible, on their own cmd-safe hint line.
      expect(
        ps,
        contains(
          '(or: set ANTHROPIC_API_KEY / GOOGLE_API_KEY / OPENAI_API_KEY)',
        ),
      );
    },
  );

  test('FA_INSTALL_VIA is scoped to the batch frame (gh-1945 review)', () {
    final bat = rendered['site/install.bat']!;
    // A Ctrl+C (or closed console) mid-install aborts the batch before the
    // happy-path clear runs. setlocal/endlocal makes the flag local to the
    // batch invocation, so an interrupted run cannot leave it behind in the
    // user's cmd session (the PATH persistence below must stay OUTSIDE the
    // frame — it is meant to outlive the script).
    final lines = bat.split('\n');
    // Whole-statement match: a comment mentioning setlocal/endlocal must
    // not satisfy the ordering.
    int lineOf(String needle) =>
        lines.indexWhere((l) => l.trim() == needle.trim());
    final setlocalLine = lineOf('setlocal');
    final setFlagLine = lineOf('set "FA_INSTALL_VIA=cmd"');
    final powershellLine = lines.indexWhere(
      (l) => l.contains('powershell -NoProfile'),
    );
    final clearFlagLine = lineOf('set "FA_INSTALL_VIA="');
    final endlocalLine = lineOf('endlocal');
    final pathLine = lines.indexWhere(
      (l) => l.trim().startsWith(r'set "PATH='),
    );
    expect(setlocalLine, greaterThanOrEqualTo(0), reason: 'setlocal present');
    expect(
      setFlagLine,
      greaterThan(setlocalLine),
      reason: 'flag set inside the frame',
    );
    expect(powershellLine, greaterThan(setFlagLine));
    expect(clearFlagLine, greaterThan(powershellLine));
    expect(
      endlocalLine,
      greaterThan(clearFlagLine),
      reason: 'frame closed after the run',
    );
    expect(
      pathLine,
      greaterThan(endlocalLine),
      reason: 'PATH persistence must survive endlocal',
    );
  });
}
