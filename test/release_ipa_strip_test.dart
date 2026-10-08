// gh-1403: the release-hygiene suite grew past the gh-1232 god-file
// ceiling (2800 lines) when the IPA strip-step coverage landed here, so
// the strip-step concern moved to this sibling file (the established
// split-by-concern pattern: agent_cli_test.dart → agent_cli_*_test.dart).
//
// The strip step went red on the daily testflight leg with
// `zip error: Could not create output file (.../fa.ipa.stripped)` —
// `find` yields a RELATIVE IPA_PATH and the rezip runs inside
// `(cd "$STRIP" && …)`, so the output path resolved against the
// mktemp dir. Latent since #1331: every prior IPA took the
// "no Symbols/" early exit, so the main path had zero executions and
// zero coverage. These tests execute the exact run block against a
// fixture IPA — the guard path stays pinned too.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

YamlMap jobsOf(String workflowPath) =>
    loadYaml(read(workflowPath))['jobs'] as YamlMap;

/// The `run:` block of the named step (first match across the workflow's
/// jobs) — the suite executes workflow shell blocks verbatim against
/// fixture sandboxes (the bench/terminal_bench/test_bench_workflow.py
/// pattern), so a step's guard-only coverage can never again hide a broken
/// main path.
String runBlockOf(String workflowPath, String stepName) {
  for (final job in jobsOf(workflowPath).values) {
    if (job is! YamlMap || !job.containsKey('steps')) continue;
    for (final step in job['steps'] as YamlList) {
      if (step is YamlMap && step['name'] == stepName) {
        return step['run'].toString();
      }
    }
  }
  throw StateError('step "$stepName" not found in $workflowPath');
}

/// Fixture IPA (a real zip with the export shape: Payload/ plus, when
/// [withSymbols], the debug-symbols dir the strip step repacks away),
/// written to the sandbox path `find flutter_app/build/ios` discovers.
/// The DWARF payload is RANDOM bytes (the real dSYM bulk is machine code
/// — incompressible), so "IPA stripped: BEFORE -> AFTER" must shrink the
/// file — a no-op strip cannot pass on this fixture.
int writeIpa(Directory sandbox, {required bool withSymbols}) {
  final rng = Random(1403);
  final dwarf = List<int>.generate(256 * 1024, (_) => rng.nextInt(256));
  final archive = Archive();
  void add(String name, List<int> bytes) =>
      archive.addFile(ArchiveFile.bytes(name, bytes));
  add(
    'Payload/Fa.app/Info.plist',
    utf8.encode('<?xml version="1.0"?><plist/>'),
  );
  add('Payload/Fa.app/Fa', utf8.encode('fake-mach-o'));
  add(
    'Payload/Fa.app/_CodeSignature/CodeResources',
    utf8.encode('sig-resources'),
  );
  if (withSymbols) {
    add('Symbols/fa.app.dSYM/Contents/Info.plist', utf8.encode('dsym-plist'));
    add('Symbols/fa.app.dSYM/Contents/Resources/DWARF/Fa', dwarf);
  }
  final bytes = ZipEncoder().encode(archive);
  final dir = Directory('${sandbox.path}/flutter_app/build/ios/ipa')
    ..createSync(recursive: true);
  File('${dir.path}/fa.ipa').writeAsBytesSync(bytes);
  return bytes.length;
}

void main() {
  group(
    'gh-1403 — IPA strip step executes its MAIN path (not just the guard)',
    () {
      const buildMobile = '.github/workflows/build-mobile.yml';
      const stripStep = 'Strip debug symbols from IPA (#1331)';
      const ipaRel = 'flutter_app/build/ios/ipa/fa.ipa';

      late Directory sandbox;

      setUp(() {
        sandbox = Directory.systemTemp.createTempSync('gh-1403-strip-');
      });

      tearDown(() {
        if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
      });

      /// The step's run block as an executable driver. The step speaks BSD
      /// `stat -f%z` (authored for the macOS runner); ubuntu CI speaks GNU —
      /// a transparent shell-function shim translates, same GNU/BSD bridge
      /// as the sed shim in runAutoReleaseDirect.
      ProcessResult runStripStep() {
        File('${sandbox.path}/strip_step.sh').writeAsStringSync('''
#!/usr/bin/env bash
# gh-1403 test shim: translate the BSD form, forward everything else.
stat() {
  if [ "\${1:-}" = "-f%z" ]; then
    /usr/bin/stat -c%s "\$2" 2>/dev/null || /usr/bin/stat -f%z "\$2"
  else
    /usr/bin/stat "\$@"
  fi
}
${runBlockOf(buildMobile, stripStep)}
''');
        return Process.runSync(
          'bash',
          ['strip_step.sh'],
          workingDirectory: sandbox.path,
          environment: {'PATH': Platform.environment['PATH'] ?? ''},
        );
      }

      /// The entries of the sandbox IPA after the step ran.
      List<String> ipaEntries() => ZipDecoder()
          .decodeBytes(File('${sandbox.path}/$ipaRel').readAsBytesSync())
          .files
          .map((f) => f.name)
          .toList();

      test(
        'an IPA WITH Symbols/ is stripped in place — valid zip, Payload intact',
        () {
          final before = writeIpa(sandbox, withSymbols: true);
          final proc = runStripStep();
          expect(
            proc.exitCode,
            0,
            reason: 'stdout: ${proc.stdout}\nstderr: ${proc.stderr}',
          );
          // The atomic swap leaves the IPA at the SAME path…
          expect(File('${sandbox.path}/$ipaRel').existsSync(), isTrue);
          // …a valid zip with Symbols/ gone…
          final entries = ipaEntries();
          expect(entries.where((n) => n.startsWith('Symbols/')), isEmpty);
          // …Payload/ byte-intact (codesign validity lives inside the bundle).
          expect(
            entries,
            containsAll([
              'Payload/Fa.app/Info.plist',
              'Payload/Fa.app/Fa',
              'Payload/Fa.app/_CodeSignature/CodeResources',
            ]),
          );
          // The diet is real and reported.
          final m = RegExp(r'IPA stripped: (\d+) -> (\d+)')
              .firstMatch(proc.stdout as String);
          expect(
            m,
            isNotNull,
            reason: 'the step must report the diet: ${proc.stdout}',
          );
          final beforeBytes = int.parse(m!.group(1)!);
          final afterBytes = int.parse(m.group(2)!);
          expect(beforeBytes, before);
          expect(afterBytes, lessThan(beforeBytes));
        },
      );

      test('guard: an IPA without Symbols/ passes through untouched', () {
        final original = writeIpa(sandbox, withSymbols: false);
        final proc = runStripStep();
        expect(
          proc.exitCode,
          0,
          reason: 'stdout: ${proc.stdout}\nstderr: ${proc.stderr}',
        );
        expect(proc.stdout, contains('nothing to strip'));
        expect(
          File('${sandbox.path}/$ipaRel').readAsBytesSync().length,
          original,
          reason: 'the guard path must not touch the IPA',
        );
      });

      test('missing IPA fails loudly with the ::error:: annotation', () {
        // The reachable real-world state: the build step ran and produced no
        // IPA (the dir exists, find matches nothing).
        Directory('${sandbox.path}/flutter_app/build/ios/ipa')
            .createSync(recursive: true);
        final proc = runStripStep();
        expect(proc.exitCode, 1);
        expect(
          '${proc.stdout}${proc.stderr}',
          contains('::error::IPA file not found'),
        );
      });
    },
  );
}
