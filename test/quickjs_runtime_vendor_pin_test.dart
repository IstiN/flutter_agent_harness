// PR #1785 rework: bumping js_widget_runtime 0.4.177 → 0.4.180 drags
// quickjs_runtime 0.3.6 → 0.4.2 into flutter_app, and 0.4.2's
// `hook/build.dart` (Native Assets) cannot build on two CI legs:
//
//   Build Android APK (debug):
//     ld.ld: error: unable to find library -lpthread
//   The Android NDK has shipped no libpthread since r18 — pthread lives
//   in bionic's libc — so the unconditional `-lpthread` in `libraries:`
//   fails the link for every ABI.
//
//   Lockfile smoke (windows release):
//     quickjs.h(672): error C2440 …  __ATOMIC_ACQUIRE undeclared …
//     fatal error C1083: Cannot open include file: 'sys/time.h'
//   The QuickJS 2024-01-13 sources are not MSVC-clean (C11
//   <stdatomic.h>, POSIX sys/time.h, GNU packed attributes), so the
//   MSVC flutter_assemble.vcxproj build dies.
//
// The upstream fix belongs in the next quickjs_runtime publish; until it
// lands flutter_app consumes the patched vendored fork (same pattern as
// vendor/dart_tui and vendor/wasm_run*), and js_widget_runtime falls
// back to its flutter_js backend wherever the native asset is absent —
// exactly the pre-0.4.0 behavior. Static pins over the vendored fork,
// same style as wasmrun_macos_pod_link_test.dart.
import 'dart:io';

import 'package:test/test.dart';
const vendorDir = 'vendor/quickjs_runtime';
const hookPath = '$vendorDir/hook/build.dart';
const vendorPubspecPath = '$vendorDir/pubspec.yaml';
const appPubspecPath = 'flutter_app/pubspec.yaml';
const appLockPath = 'flutter_app/pubspec.lock';

/// The YAML block that follows a top-level `key:` (all deeper-indented
/// lines plus blanks, up to the next top-level key).
String _topLevelBlock(String yaml, String key, {String reason = ''}) {
  final lines = yaml.split('\n');
  final start = lines.indexWhere((l) => l.trim() == '$key:');
  expect(start, isNot(-1), reason: reason.isEmpty ? 'no `$key:` found' : reason);
  final block = StringBuffer();
  for (var i = start + 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      block.writeln(line);
      continue;
    }
    if (line.startsWith(' ') || line.startsWith('\t')) {
      block.writeln(line);
    } else {
      break;
    }
  }
  return block.toString();
}

/// The hook with comments stripped (whole-line and trailing `// …`) so
/// the pins below only see executable code. The hook contains no `//`
/// inside string literals.
String _hookCode() {
  final raw = File(hookPath).readAsStringSync();
  expect(File(hookPath).existsSync(), isTrue, reason: '$hookPath must exist');
  return raw
      .split('\n')
      .map((l) {
        final comment = l.indexOf('//');
        return comment >= 0 ? l.substring(0, comment) : l;
      })
      .join('\n');
}

void main() {
  group('quickjs_runtime vendored fork pins (PR #1785 CI reds)', () {
    test('flutter_app overrides quickjs_runtime to the vendored fork', () {
      final overrides = _topLevelBlock(
        File(appPubspecPath).readAsStringSync(),
        'dependency_overrides',
        reason:
            '$appPubspecPath must declare `dependency_overrides:` — hosted '
            'quickjs_runtime 0.4.2 cannot build its Native Asset on '
            'Android (-lpthread) or Windows (MSVC).',
      );
      expect(
        overrides,
        contains('quickjs_runtime:'),
        reason:
            'flutter_app must consume the patched vendored quickjs_runtime '
            '(see vendor/quickjs_runtime) — the hosted 0.4.2 hook fails the '
            'Build Android APK and Lockfile smoke (windows) CI legs.',
      );
      expect(
        overrides,
        contains('../vendor/quickjs_runtime'),
        reason: 'the override must point at the vendored patched fork',
      );
    });

    test('vendored fork tracks upstream 0.4.2 and keeps its build hook', () {
      final pubspec = File(vendorPubspecPath).readAsStringSync();
      expect(
        RegExp(r'^version:\s*0\.4\.2\s*$', multiLine: true).hasMatch(pubspec),
        isTrue,
        reason:
            '$vendorPubspecPath must stay on the upstream 0.4.2 version so '
            'it still satisfies js_widget_runtime ^0.4.0 (re-vendor on the '
            'next upstream publish that fixes Android/Windows).',
      );
      expect(
        File(hookPath).existsSync(),
        isTrue,
        reason: 'the Native Assets hook must stay present for '
            'iOS/macOS/Linux/Android (js_widget_runtime 0.4.180 prefers the '
            'QuickJS backend there)',
      );
    });

    test('Android never links libpthread (NDK has no libpthread since r18)', () {
      final code = _hookCode();
      final androidArm = RegExp(
        r"OS\.android\s*=>\s*const\s*\[([^\]]*)\]",
      ).firstMatch(code);
      expect(
        androidArm,
        isNotNull,
        reason:
            '$hookPath must link libraries via an explicit `OS.android =>` '
            'switch arm so the pthread exclusion is greppable — upstream '
            '0.4.2 links `-lpthread` unconditionally and the NDK link dies '
            'with `ld.lld: error: unable to find library -lpthread`.',
      );
      expect(
        androidArm!.group(1),
        isNot(contains('pthread')),
        reason:
            'bionic ships pthread inside libc; there is no libpthread in '
            'the Android NDK sysroot since r18 — `-lpthread` fails the link '
            'for every ABI (Build Android APK CI leg).',
      );
      // Desktop Linux (glibc) still has a real libpthread — dropping it
      // there would trade one red leg for another.
      expect(code, contains("'pthread'"), reason: 'pthread must stay linked '
          'on the non-Android VM platforms where it exists');
    });

    test('Windows returns before the Native Assets CBuilder', () {
      final code = _hookCode();
      final guard = RegExp(
        r'if\s*\(\s*os\s*==\s*OS\.windows\s*\)\s*return\s*;',
      ).firstMatch(code);
      expect(
        guard,
        isNotNull,
        reason:
            '$hookPath must early-return for OS.windows — the QuickJS '
            '2024-01-13 sources are not MSVC-clean (C11 <stdatomic.h>/'
            '__ATOMIC_ACQUIRE, POSIX sys/time.h, GNU packed attributes) and '
            'upstream 0.4.2 dies in flutter_assemble.vcxproj (Lockfile '
            'smoke windows leg). js_widget_runtime falls back to its '
            'flutter_js backend when the native asset is absent — the '
            'pre-0.4.0 Windows behavior.',
      );
      final builder = code.indexOf('CBuilder');
      expect(builder, greaterThan(-1), reason: 'the CBuilder must remain for '
          'iOS/Android/macOS/Linux');
      expect(
        guard!.start,
        lessThan(builder),
        reason: 'the Windows early-return must sit before the CBuilder '
            'construction — anything after it never runs on Windows',
      );
    });

    test('CodeQL-flagged C expressions use explicit widening casts', () {
      // CodeQL default setup analyzes C/C++ in `none` build mode — every
      // vendored QuickJS source is extracted and scanned, and 3 upstream
      // `cpp/integer-multiplication-cast-to-long` ("multiplication result
      // converted to larger type") alerts fail the CodeQL check on the PR.
      //
      // Inline suppression comments are NOT an option: GitHub's code
      // scanning service does not honor `// codeql [...]` / `// lgtm [...]`
      // comments (github/codeql#11427 has been open for exactly that since
      // 2022 — the AlertSuppression.qll library is third-party/legacy), and
      // default-setup configuration (paths-ignore) is admin-only.
      //
      // The fix is cast-before-multiply at the 3 flagged sites — each is
      // VALUE-IDENTICAL to upstream under its existing guard/invariant:
      //   1. `r -= (dlimb_t)q * q;` — the else arm of `if ((q >> l) != 0)`
      //      guarantees q < 2^l, so the limb_t product never wraps and the
      //      widened product is the same number.
      //   2. `pos_incr = (slimb_t)digits_per_limb * radix_bits;` — the
      //      product is exactly LIMB_BITS (≤ 64) by construction.
      //   3. `(size_t)new_size * elem_size` — identical for every input
      //      where the original int product was defined; the theoretical
      //      >INT_MAX path becomes a clean OOM instead of signed UB
      //      (upstream carries its own `XXX: potential arithmetic
      //      overflow` remark on that line).
      final casts = <(String, String, String)>[
        (
          '$vendorDir/native/quickjs/libbf.c',
          'r -= (dlimb_t)q * q;',
          'r -= q * q;',
        ),
        (
          '$vendorDir/native/quickjs/libbf.c',
          'pos_incr = (slimb_t)digits_per_limb * radix_bits;',
          'pos_incr = digits_per_limb * radix_bits;',
        ),
        (
          '$vendorDir/native/quickjs/quickjs.c',
          'new_array = js_realloc2(ctx, *parray, (size_t)new_size * '
              'elem_size, &slack);',
          'new_array = js_realloc2(ctx, *parray, new_size * elem_size, '
              '&slack);',
        ),
      ];
      // Match on whitespace-normalized text: the C sources may wrap long
      // statements across lines.
      String norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ');
      for (final (path, castForm, narrowForm) in casts) {
        final source = norm(File(path).readAsStringSync());
        expect(
          source.contains(castForm),
          isTrue,
          reason:
              '$path must contain the widening-cast form `$castForm` — the '
              'narrow product is a cpp/integer-multiplication-cast-to-long '
              'alert and inline `// codeql [...]` comments are not honored '
              'by GitHub code scanning (github/codeql#11427), so the CodeQL '
              'check goes red on the PR without the cast.',
        );
        expect(
          source.contains(narrowForm),
          isFalse,
          reason:
              '$path still contains the narrow form `$narrowForm` — it '
              'raises a fresh cpp/integer-multiplication-cast-to-long alert '
              'on every re-analysis; keep only the widening-cast form '
              '`$castForm`.',
        );
      }
      // The suppression comments were inert (the service never read them)
      // — make sure none survive to mislead the next re-vendor.
      for (final c in const ['libbf.c', 'quickjs.c']) {
        final source = norm(
          File('$vendorDir/native/quickjs/$c').readAsStringSync(),
        );
        expect(
          source.contains('// codeql ['),
          isFalse,
          reason:
              '$c contains an inert `// codeql [...]` suppression comment — '
              'GitHub code scanning does not honor inline suppression '
              'comments; the widening casts above are the actual fix. Drop '
              'the stale comment.',
        );
      }
    });

    test('flutter_app/pubspec.lock resolves quickjs_runtime as a path dep', () {
      // CI resolves flutter_app with `flutter pub get --enforce-lockfile`
      // (.github/actions/flutter-pub-get): a pubspec/lockfile skew is a
      // deterministic red on every package leg.
      final entry = _topLevelBlock(
        File(appLockPath).readAsStringSync(),
        'quickjs_runtime',
        reason:
            '$appLockPath must still contain a quickjs_runtime entry — '
            'regenerate it (cd flutter_app && flutter pub get) after adding '
            'the override.',
      );
      expect(
        entry,
        contains('source: path'),
        reason:
            'the lock must resolve quickjs_runtime from the vendored path, '
            'not the hosted 0.4.2 with the broken Native Assets hook',
      );
      expect(entry, contains('../vendor/quickjs_runtime'));
    });

    test('vendored hook/build.dart compiles to kernel', () {
      // The Native Assets runner compiles the hook with
      // `dart compile kernel --packages=<app package_config>` before every
      // flutter/dart build — a hook that only fails to COMPILE (syntax
      // drift, a `const` collection wrapping a runtime `if (os == …)`
      // arm, …) strings pins cannot see. Replicate that compile so it
      // fails here, at the root gate, instead of on every flutter leg.
      // Skipped where flutter_app is not pub-resolved (bare root legs).
      final packageConfig = File('flutter_app/.dart_tool/package_config.json');
      if (!packageConfig.existsSync()) {
        return markTestSkipped(
          'flutter_app is not pub-resolved in this leg — the hook kernel '
          'compile runs wherever the app package_config exists',
        );
      }
      final outDir = Directory.systemTemp.createTempSync('qjs-hook-pin-');
      addTearDown(() => outDir.deleteSync(recursive: true));
      final result = Process.runSync(Platform.resolvedExecutable, [
        'compile',
        'kernel',
        '--packages=${packageConfig.resolveSymbolicLinksSync()}',
        '--output=${outDir.path}/hook.dill',
        hookPath,
      ]);
      expect(
        result.exitCode,
        0,
        reason:
            '$hookPath must compile — the Native Assets runner kernel-compiles '
            'it before every build:\n${result.stdout}\n${result.stderr}',
      );
    });
  });
}
