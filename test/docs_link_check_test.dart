// gh-2181 — AGENTS.md docs-reference integrity + structure pins.
//
// The slim AGENTS.md replaces subsystem essays with one-line entries that
// reference canonical docs/*.md files. This test pins the invariants the
// ticket makes testable:
//   AC3 — the mermaid module map renders sanely (structural check: fenced
//         block, flowchart header, every section the card pins is named,
//         edge endpoints are declared nodes, quotes/brackets balanced) and
//         a golden pin on the required section names;
//   AC5 — every `docs/...` pointer in AGENTS.md resolves, and docs/README.md
//         (the docs index) lists every doc AGENTS.md references;
//   AC6 — the memory footnote block is <= 15 lines and carries the scope
//         rules + the churn pointer;
//   AC7 — spot-check prompts stay answerable from the slim file alone:
//         god-file ceiling value, compaction policy location, golden-test
//         mandate, memory scopes.
//   Border case — the barrel purity invariants + god-file ceiling STAY
//         inline (hard rules agents must see un-truncated).
import 'dart:io';

import 'package:test/test.dart';

/// Docs references use backticked repo-relative paths (`docs/x.md`) or
/// markdown links. Both must point at real files.
final _docsRefPattern = RegExp(r'docs/[A-Za-z0-9][A-Za-z0-9._/-]*\.md');

/// Sections the ticket pins into the module map (gh-2181 target shape 1).
final _requiredMapSections = <String, RegExp>{
  'SDK': RegExp(r'SDK', caseSensitive: false),
  'CLI': RegExp(r'\bCLI\b'),
  'Flutter app': RegExp(r'Flutter app', caseSensitive: false),
  'packages': RegExp(r'packages', caseSensitive: false),
  'extension': RegExp(r'extension', caseSensitive: false),
  'office': RegExp(r'office', caseSensitive: false),
  'fa_network': RegExp(r'fa_network', caseSensitive: false),
  'UI golden/styles': RegExp(r'golden|styles', caseSensitive: false),
};

String read(String path) => File(path).readAsStringSync();

/// Lines of the section under [heading] (inclusive) up to the next `## `
/// heading (exclusive).
List<String> section(String text, String heading) {
  final lines = text.split('\n');
  final start = lines.indexWhere((l) => l.startsWith(heading));
  if (start < 0) return const [];
  var end = start + 1;
  while (end < lines.length && !lines[end].startsWith('## ')) {
    end++;
  }
  return lines.sublist(start, end);
}

void main() {
  final agents = read('AGENTS.md');

  group('AC5 — docs reference integrity', () {
    test('every docs/... pointer in AGENTS.md resolves', () {
      final refs = _docsRefPattern
          .allMatches(agents)
          .map((m) => m.group(0)!)
          .toSet();
      expect(refs, isNotEmpty, reason: 'the slim file must reference docs/');
      final broken = <String>[];
      for (final ref in refs) {
        if (!File(ref).existsSync()) broken.add(ref);
      }
      expect(
        broken,
        isEmpty,
        reason:
            'AGENTS.md references docs files that do not exist — the '
            'one-line entries are pointer-only, a dead pointer orphans '
            'the fact (gh-2181 AC5)',
      );
    });

    test('docs/README.md index exists and lists every referenced doc', () {
      final index = File('docs/README.md');
      expect(
        index.existsSync(),
        isTrue,
        reason: 'docs/README.md is the docs index (gh-2181 AC5)',
      );
      final indexText = index.readAsStringSync();
      final refs = _docsRefPattern
          .allMatches(agents)
          .map((m) => m.group(0)!)
          .toSet();
      final missing = refs.where((ref) => !indexText.contains(ref)).toList()
        ..sort();
      expect(
        missing,
        isEmpty,
        reason:
            'docs referenced from AGENTS.md must be listed in the docs '
            'index: $missing',
      );
    });

    test('no orphaned gh-2181 reference docs (every new doc is reachable)', () {
      // The docs the slim file points at must be discoverable both ways:
      // from AGENTS.md directly AND from the index.
      final indexText = read('docs/README.md');
      for (final dir in ['docs/agents']) {
        for (final f in Directory(dir).listSync()) {
          if (f is! File || !f.path.endsWith('.md')) continue;
          final ref = f.path;
          expect(
            indexText.contains(ref),
            isTrue,
            reason: '$ref exists but the docs index never lists it',
          );
        }
      }
    });

    test('every docs/*.md on disk is git-tracked (ignore-rule trap pin)', () {
      // gh-2181 lesson: a bare `agents/` .gitignore rule swallowed the new
      // docs/agents/*.md files — they existed on disk, tests saw them, but
      // `git status` hid them and a commit would silently drop them. Every
      // canonical doc must be tracked; a disk-only docs file is a bug.
      final tracked = Process.runSync('git', [
        'ls-files',
        'docs/',
      ]).stdout.toString().split('\n').toSet();
      final untracked = <String>[];
      for (final f in Directory('docs').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.md')) continue;
        if (!f.path.contains('${Platform.pathSeparator}.git')) {
          if (!tracked.contains(f.path)) untracked.add(f.path);
        }
      }
      expect(
        untracked,
        isEmpty,
        reason:
            'docs files exist on disk but git does not track them — an '
            'ignore rule (the gh-2181 `agents/` trap) would silently drop '
            'them from the commit: $untracked',
      );
    });
  });

  group('AC3 — mermaid module map', () {
    late String mermaid;

    setUp(() {
      final start = agents.indexOf('```mermaid');
      expect(
        start,
        greaterThanOrEqualTo(0),
        reason: 'AGENTS.md must carry the mermaid module map',
      );
      final end = agents.indexOf('```', start + '```mermaid'.length);
      mermaid = agents.substring(start + '```mermaid'.length, end);
    });

    test('flowchart header + no tabs (GitHub renderer requirements)', () {
      expect(mermaid, contains('flowchart'));
      expect(mermaid.contains('\t'), isFalse, reason: 'tabs break mermaid');
    });

    test('names every section the card pins', () {
      for (final entry in _requiredMapSections.entries) {
        expect(
          entry.value.hasMatch(mermaid),
          isTrue,
          reason: 'module map must name the "${entry.key}" section',
        );
      }
    });

    test('edge endpoints are declared nodes/subgraphs', () {
      // Collect declared ids: `ID[...`, `ID("...`, `subgraph ID` — and the
      // ids used on edge lines `A --> B` (one edge per line, the only edge
      // form the map uses).
      final declared = RegExp(
        r'^\s*(?:subgraph\s+([A-Za-z0-9_]+)|([A-Za-z0-9_]+)\s*[\[(])',
        multiLine: true,
      ).allMatches(mermaid).map((m) => m.group(1) ?? m.group(2)!).toSet();
      final used = <String>{};
      final edgeLine = RegExp(
        r'^\s*([A-Za-z0-9_]+)\s+-->\s*([A-Za-z0-9_]+)\s*$',
        multiLine: true,
      );
      for (final line in mermaid.split('\n')) {
        final m = edgeLine.firstMatch(line);
        if (m == null) continue;
        used
          ..add(m.group(1)!)
          ..add(m.group(2)!);
      }
      expect(declared, isNotEmpty, reason: 'fixture: nodes are declared');
      expect(used, isNotEmpty, reason: 'fixture: edges exist');
      final dangling = used.where((id) => !declared.contains(id)).toList()
        ..sort();
      expect(
        dangling,
        isEmpty,
        reason:
            'mermaid edge references undeclared node ids: $dangling — '
            'GitHub renders dangling ids as empty boxes',
      );
    });

    test('labels are balanced (quotes and brackets per line)', () {
      for (final line in mermaid.split('\n')) {
        final quotes = line.codeUnits.where((c) => c == 0x22).length;
        expect(
          quotes.isEven,
          isTrue,
          reason: 'unbalanced quotes break the mermaid render: $line',
        );
        final openBrackets = '['.allMatches(line).length;
        final closeBrackets = ']'.allMatches(line).length;
        expect(
          openBrackets,
          closeBrackets,
          reason: 'unbalanced brackets break the mermaid render: $line',
        );
        final openParens = '('.allMatches(line).length;
        final closeParens = ')'.allMatches(line).length;
        expect(
          openParens,
          closeParens,
          reason: 'unbalanced parens break the mermaid render: $line',
        );
      }
    });
  });

  group('AC6 — memory footnote block', () {
    test('exists, <= 15 lines, carries scopes + churn pointer', () {
      final memory = section(agents, '## Memory');
      expect(memory, isNotEmpty, reason: 'the memory footnote block is gone');
      expect(
        memory.length,
        lessThanOrEqualTo(15),
        reason:
            'the memory block must stay a footnote (<= 15 lines incl. the '
            'heading) — got ${memory.length}: ${memory.take(3)}…',
      );
      final block = memory.join('\n');
      expect(
        block,
        contains('project'),
        reason: 'scope rule: project memory is this repo, committed',
      );
      expect(
        block,
        contains('user'),
        reason: 'scope rule: user memory is global/private',
      );
      expect(
        block,
        contains('docs/memory-churn.md'),
        reason: 'the churn-pitfall pointer (gh-2181 AC6)',
      );
    });
  });

  group('AC7 — spot-check questions stay answerable from the slim file', () {
    test('god-file ceiling value is inline', () {
      expect(
        agents,
        contains('2800'),
        reason: 'the 2800-line .dart ceiling must stay inline (hard rule)',
      );
    });

    test('barrel/io.dart purity invariants stay inline', () {
      expect(
        agents,
        contains('dart:io'),
        reason: 'the pure-Dart/no-dart:io rule must stay inline',
      );
      expect(
        agents,
        contains('lib/io.dart'),
        reason: 'the IO entry-point invariant must stay inline',
      );
      expect(
        agents,
        contains('APPEND-ONLY'),
        reason: 'the barrel append-only policy must stay inline',
      );
    });

    test('compaction policy location is referenced', () {
      expect(
        agents,
        contains('docs/compaction.md'),
        reason: 'AC7 spot-check: compaction policy location',
      );
    });

    test('golden-test mandate is inline (not pointer-only)', () {
      final golden = section(agents, '## Golden tests');
      expect(
        golden.join('\n'),
        contains('MANDATORY'),
        reason: 'AC7 spot-check: the mandate itself must be visible',
      );
    });
  });
}
