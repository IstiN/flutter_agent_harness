// gh-1596 UT-1 (+ the AC1/AC6 data hooks): POSIX-sh dialect lint over every
// sh-targeted installer artifact, plus structural assertions that the
// wizard's data sections are generated from the live catalog.
//
// AC1 — `site/setup.sh.template` (and every sh artifact the generator
// emits) contains zero POSIX-violating constructs: `printf -v`, `[[`,
// `read -p/-a/-n/-N`, arrays, `${var,,}`, `=~`, bash-only substitutions.
// Under `curl | sh` the shebang is dead text — whatever `sh` resolves to
// (dash on Ubuntu 24.04) parses the bytes, so the dialect is pinned here,
// statically, before anything ships.
//
// AC6 — the wizard's provider list, approval-mode list, and model presets
// are GENERATED from `provider_catalog.dart` (openrouter first, catalog
// order, `custom` last) + `ApprovalMode.values` (always-ask/write/yolo/
// autopilot) + the CLI's offline model presets. A catalog change without
// regeneration fails UT-2 (golden drift); the assertions here name the
// data contract explicitly so a renderer regression cannot hide behind a
// re-committed golden.
//
// Pure string scans — no IO beyond reading the committed artifacts.
import 'dart:io';

import 'package:flutter_agent_harness/src/approval/approval.dart';
import 'package:flutter_agent_harness/src/cli/model_presets.dart';
import 'package:flutter_agent_harness/src/model_roles/provider_catalog.dart';
import 'package:test/test.dart';

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

/// Full-line comments are dead text (`install.sh` self-documents with
/// "no arrays/[[]]/pipefail" and the PEM block carries base64 `==`) —
/// the lint judges only executable bytes.
String _stripCommentLines(String source) => source
    .split('\n')
    .map((line) => line.trimLeft().startsWith('#') ? '' : line)
    .join('\n');

/// bash/dash-incompatible constructs. Each entry names the construct the
/// way a failure should read. Calibrated so the POSIX-legal subset the
/// installers already rely on passes: `read -s` is NOT in the forbidden
/// set only because no artifact uses it (dash has no `-s` — hidden input
/// goes through `stty -echo`, see `ask_hidden` in the wizard template),
/// `local` INSIDE functions (dash + busybox ash both support it; busybox
/// is only strict about `local` outside functions), `printf '\033[..m'`
/// (proved by the #1596 report — the crash hit the FIRST `printf -v`,
/// lines after the colored helpers).
final _forbidden = <String, RegExp>{
  'printf -v (bash-only variable assignment)': RegExp(r'printf\s+-v\b'),
  '[[ ]] bash test': RegExp(r'\[\['),
  'read -p/-a/-n/-N (bash read flags)': RegExp(r'\bread\s+-[aApPnN]\b'),
  r'${var,,} / ${var^^} case expansion': RegExp(
    r'\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)',
  ),
  '=~ regex match (bash [[ only])': RegExp(r'=~'),
  'the `function` keyword (bash-only spelling)': RegExp(
    r'\bfunction\s+[A-Za-z_]',
  ),
  '(( )) bash arithmetic command': RegExp(r'(?<!\$)\(\('),
  '+= append assignment (not POSIX)': RegExp(r'\+='),
  '== inside [ ] (bash test operator)': RegExp(r'\[\s+\S+\s+=='),
  '<<< here-string (bash)': RegExp(r'<<<'),
  '>() / <() process substitution': RegExp(r'[<>]\('),
  'echo -e/-n (unportable echo flags)': RegExp(r'\becho\s+-[ne]\b'),
  "\$' ANSI-C quoting (bash)": RegExp(r"\$'"),
  '\$" locale quoting (bash)': RegExp(r'\$"'),
  'declare/typeset/local with flags (e.g. local -a)': RegExp(
    r'\b(declare|typeset|local)\s+-',
  ),
  r'${var/pat/repl} substitution (bash, not POSIX)': RegExp(
    r'\$\{[A-Za-z_][A-Za-z0-9_]*[/]',
  ),
  r'${var[n]} array subscript': RegExp(r'\$\{[A-Za-z_][A-Za-z0-9_]*\['),
  r'${!var} indirect expansion (bash)': RegExp(r'\$\{!'),
  r'${var:1:2} substring (bash)': RegExp(
    r'\$\{[A-Za-z_][A-Za-z0-9_]*:\s*-?[0-9]',
  ),
  '|& co-process pipe (bash)': RegExp(r'\|&'),
};

/// Every artifact the generator emits for a POSIX shell — templates AND
/// committed outputs (a template-only scan would let a renderer regress
/// the dialect after the fact; I1 covers every sh-targeted emitted script).
const _shArtifacts = [
  'site/setup.sh.template',
  'site/setup.sh',
  'site/install.sh.template',
  'site/install.sh',
];

void main() {
  final root = _repoRoot();

  group('UT-1 — POSIX dialect lint (AC1)', () {
    for (final artifact in _shArtifacts) {
      final source = _stripCommentLines(
        File('$root/$artifact').readAsStringSync(),
      );
      test('$artifact parses with zero forbidden constructs', () {
        final violations = <String>[];
        for (final entry in _forbidden.entries) {
          if (entry.value.hasMatch(source)) violations.add(entry.key);
        }
        expect(
          violations,
          isEmpty,
          reason:
              '$artifact carries POSIX-violating constructs — the '
              '#1596 crash class (dash aborts at the first bashism). Fix '
              'the SOURCE (template) and regenerate, never hand-patch the '
              'artifact. Offending: ${violations.join(", ")}',
        );
      });
    }
  });

  group('UT-1b — temp-file hygiene (gh-1596 review hardening)', () {
    // The bug shape: the wizard wrote its atomic temp config through a
    // FIXED, predictable path — `FAH_TMP_CONF="$FAH_CONFIG_DIR/.config.yaml.tmp"`
    // — so a pre-planted symlink at that path redirects the write (the
    // `> "$FAH_TMP_CONF"` redirect follows it). Temp files must be
    // mktemp-created with an XXXXXX template (random suffix); install.sh
    // already does exactly this for its downloads.
    final fixedTmpPath = RegExp(r'=\s*"[^"]*\.(tmp|temp)"');
    final mktempTemplate = RegExp(r'mktemp\s+"[^"]*X{6}"');

    for (final artifact in _shArtifacts) {
      final source = _stripCommentLines(
        File('$root/$artifact').readAsStringSync(),
      );
      test('$artifact writes temp files only through mktemp', () {
        final violations = fixedTmpPath
            .allMatches(source)
            .map((m) => m.group(0)!)
            .toList();
        expect(
          violations,
          isEmpty,
          reason:
              '$artifact assigns a fixed predictable temp path '
              '(${violations.join(", ")}) — symlink-followable. Create it '
              'with `mktemp "<dir>/<name>.XXXXXX"` in the SOURCE (template) '
              'and regenerate, never hand-patch the artifact.',
        );
        if (source.contains('TMP_CONF')) {
          expect(
            mktempTemplate.hasMatch(source),
            isTrue,
            reason:
                '$artifact uses a TMP_CONF temp file — it must be '
                'mktemp-created with a random XXXXXX suffix (GNU + busybox '
                '+ BSD all take the template form)',
          );
        }
      });
    }
  });

  group('UT-1/AC6 — wizard data is generated from the live catalog', () {
    final setup = File('$root/site/setup.sh').readAsStringSync();

    /// `1|openrouter) provider="openrouter"; provider_kind="..."; break ;;`
    final providerCase = RegExp(
      r'^\s{4}(\d+)\|([a-z0-9-]+)\) provider="([a-z0-9-]+)"; '
      r'provider_kind="([a-z0-9-]+)"; break ;;',
      multiLine: true,
    );

    /// The wizard's expected provider order: openrouter first
    /// (recommended), then the catalog order, `custom` last.
    final expectedProviders = [
      'openrouter',
      ...providerCatalog.keys.where((id) => id != 'openrouter'),
      'custom',
    ];

    test('the provider case list equals the catalog (+ custom last)', () {
      final cases = providerCase
          .allMatches(setup)
          .map((m) => (index: int.parse(m.group(1)!), id: m.group(2)!))
          .toList();
      expect(
        cases.map((c) => c.id).toList(),
        expectedProviders,
        reason:
            'AC6: provider menu == catalog names — openrouter first, '
            'then catalog order, custom last. Stale menus ship stale '
            'providers on every fresh download (the #1596 audit finding).',
      );
      expect(cases.map((c) => c.index).toList(), [
        for (var i = 1; i <= expectedProviders.length; i++) i,
      ]);
    });

    test('every provider case writes the catalog adapter kind', () {
      for (final m in providerCase.allMatches(setup)) {
        final id = m.group(2)!;
        final expectedKind = id == 'custom'
            ? 'openai-completions'
            : providerCatalog[id]!.kind;
        expect(
          m.group(4),
          expectedKind,
          reason:
              'config `provider:` must carry the canonical adapter '
              'kind for $id (canonicalProviderKind boundary)',
        );
      }
    });

    test('the approval case list equals ApprovalMode labels in order', () {
      final expected = [for (final mode in ApprovalMode.values) mode.label];
      final actual = RegExp(
        r'^\s{4}(\d+)\|([a-z-]+)\) approval="[a-z-]+"; break ;;',
        multiLine: true,
      ).allMatches(setup).map((m) => m.group(2)!).toList();
      expect(
        actual,
        expected,
        reason:
            'AC6: approval menu == always-ask/write/yolo/autopilot '
            '(kAutopilotLabel) — the fourth mode the wizard never offered',
      );
    });

    test('model presets match the CLI offline presets per provider', () {
      for (final entry in knownModelPresets.entries) {
        for (final model in entry.value) {
          expect(
            setup.contains('model="$model"; break ;;'),
            isTrue,
            reason:
                'preset $model for ${entry.key} missing from the '
                'wizard — presets are generated from knownModelPresets',
          );
        }
        // The recommended marker rides the FIRST preset of each provider.
        expect(
          setup.contains('${entry.value.first}   (recommended)'),
          isTrue,
          reason:
              '${entry.value.first} must carry the (recommended) '
              'marker — first preset wins, as in the CLI fallback list',
        );
      }
    });

    test('preset-less providers ask for the model id directly', () {
      for (final id in providerCatalog.keys) {
        if (knownModelPresets.containsKey(id)) continue;
        final block = RegExp(
          '^  $id\\)\\n(.*?)^    ;;',
          multiLine: true,
          dotAll: true,
        ).firstMatch(setup);
        expect(
          block,
          isNotNull,
          reason: 'provider $id missing from the model-selection case',
        );
        expect(
          block!.group(1)!,
          contains(r'model=$(ask "Model id on that endpoint")'),
          reason:
              'no presets for $id — the wizard must ask for the model '
              'id directly instead of showing a fake numbered menu',
        );
      }
    });
  });
}
