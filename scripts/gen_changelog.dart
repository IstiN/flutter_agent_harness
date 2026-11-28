#!/usr/bin/env dart
// gh-2463 — changelog/ entries aggregator: the release-time replacement for
// the single curated CHANGELOG.md.
//
// Each PR adds ITS OWN entry file `changelog/entries/<issue-or-pr>-<slug>.md`
// (YAML frontmatter `type`/`scope`/`issue` + 1–3 user-facing bullet lines)
// and never edits CHANGELOG.md — parallel agents never touch a shared file,
// so the merge-conflict surface is gone by construction. This script:
//
//   --stdout           print the pending aggregate as flat bullets in
//                      (numeric-prefix, filename) order — the same shape the
//                      old curated `## Unreleased` body had, so
//                      scripts/release_notes.sh stays content-identical
//                      (default mode when no flag is given);
//   --group-by-type    same bullets grouped under type headings (human view);
//   --validate         validate every entry (frontmatter schema, filename
//                      convention, non-empty body) — CI static-gate input;
//   --write-changelog  regenerate the thin CHANGELOG.md index (preamble +
//                      generated `## Unreleased` + archive index). The file
//                      is generated-only: a CI guard rejects hand edits.
//
// Entry format:
//
//   ---
//   type: feat|fix|perf|docs|ci|other
//   scope: <short scope, optional>
//   issue: <issue or PR number, optional>
//   ---
//
//   - user-facing bullet (1–3 lines; the release notes body rides verbatim)
//
// Entries sharing a non-empty `issue` are rework duplicates: the LAST file in
// sort order wins, the loser is dropped with a stderr note (deterministic —
// no mtime/randomness in the output).
import 'dart:io';

const _types = <String>['feat', 'fix', 'perf', 'docs', 'ci', 'other'];

const _groupHeadings = <String, String>{
  'feat': 'Features',
  'fix': 'Fixes',
  'perf': 'Performance',
  'docs': 'Docs',
  'ci': 'CI',
  'other': 'Other',
};

final _fileNameRe = RegExp(r'^(\d+)-[a-z0-9-]+\.md$');
final _versionNameRe = RegExp(r'^\d+\.\d+\.\d+$');

String get _usage =>
    'usage: gen_changelog.dart [--stdout|--group-by-type|--validate|'
    '--write-changelog]  (entries dir: ./changelog/entries)';

/// One parsed entry file.
class Entry {
  Entry(
    this.file,
    this.sortKey,
    this.sortNum,
    this.type,
    this.scope,
    this.issue,
    this.body,
  );
  final String file; // path as reported in diagnostics
  final String sortKey; // filename — tie-break and dedupe winner key
  final int sortNum; // numeric filename prefix — primary sort
  final String type;
  final String scope;
  final String issue; // empty when absent
  final String body; // trimmed markdown bullets, verbatim
}

/// A structural problem in an entry file (::error:: in --validate).
class EntryProblem {
  EntryProblem(this.file, this.message);
  final String file;
  final String message;
}

void main(List<String> args) {
  final mode = _parseMode(args);
  final entriesDir = Directory('changelog/entries');
  final files = entriesDir.existsSync()
      ? entriesDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.md'))
          .map((f) => f.path)
          .toList()
      : <String>[];
  files.sort();

  final problems = <EntryProblem>[];
  final entries = <Entry>[];
  for (final path in files) {
    final name = path.split(Platform.pathSeparator).last;
    _parseEntry(path, name, problems) == null
        ? null
        : entries.add(_parseEntry(path, name, problems)!);
  }

  if (mode == Mode.validate) {
    _validate(entriesDir, files, problems, entries);
    return;
  }
  // Aggregate modes stop loudly on ANY broken entry: silently dropping one
  // would ship release notes missing that change (the release train must
  // notice at PR time, not in the published notes).
  if (problems.isNotEmpty) {
    for (final p in problems) {
      stderr.writeln('::error::${p.file}: ${p.message}');
    }
    stderr.writeln(
      'gen_changelog: ${problems.length} broken entry file(s) — '
      'run `dart scripts/gen_changelog.dart --validate` for the full list',
    );
    exit(1);
  }

  final kept = _dedupe(entries);
  if (mode == Mode.writeChangelog) {
    _writeChangelog(kept);
  } else {
    stdout.write(_aggregate(kept, grouped: mode == Mode.groupByType));
  }
}

Mode _parseMode(List<String> args) {
  final flags = args.where((a) => a.startsWith('--')).toSet();
  if (args.any((a) => a == '-h' || a == '--help')) {
    stdout.writeln(_usage);
    exit(0);
  }
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isNotEmpty || flags.difference(_knownFlags).isNotEmpty) {
    stderr.writeln(_usage);
    exit(2);
  }
  if (flags.length > 1) {
    stderr.writeln('gen_changelog: pick ONE mode flag; $_usage');
    exit(2);
  }
  if (flags.contains('--validate')) return Mode.validate;
  if (flags.contains('--group-by-type')) return Mode.groupByType;
  if (flags.contains('--write-changelog')) return Mode.writeChangelog;
  return Mode.stdoutMode; // --stdout and no-flag default
}

const _knownFlags = <String>{
  '--stdout',
  '--group-by-type',
  '--validate',
  '--write-changelog',
};

enum Mode { stdoutMode, groupByType, validate, writeChangelog }

Entry? _parseEntry(String path, String name, List<EntryProblem> problems) {
  final match = _fileNameRe.firstMatch(name);
  if (match == null) {
    problems.add(
      EntryProblem(
        name,
        'filename must be <issue-or-pr>-<slug>.md with a NUMERIC prefix '
        '(it is the sort + dedupe key), e.g. 2463-changelog-entries.md',
      ),
    );
    return null;
  }
  final text = File(path).readAsStringSync();
  if (!text.startsWith('---')) {
    problems.add(
      EntryProblem(name, 'missing YAML frontmatter block (--- ... ---)'),
    );
    return null;
  }
  final close = text.indexOf('\n---', 3);
  if (close < 0) {
    problems.add(EntryProblem(name, 'unterminated YAML frontmatter block'));
    return null;
  }
  final fm = text.substring(3, close);
  final body = text.substring(text.indexOf('\n', close + 1) + 1).trim();
  final meta = <String, String>{};
  for (final line in fm.split('\n')) {
    final idx = line.indexOf(':');
    if (idx <= 0) continue;
    meta[line.substring(0, idx).trim()] = line.substring(idx + 1).trim();
  }
  final type = meta['type'] ?? '';
  if (type.isEmpty) {
    problems.add(EntryProblem(name, "frontmatter needs a 'type:' field"));
    return null;
  }
  if (!_types.contains(type)) {
    problems.add(
      EntryProblem(name, "unknown type '$type' — allowed: ${_types.join(', ')}"),
    );
    return null;
  }
  if (body.isEmpty) {
    problems.add(
      EntryProblem(name, 'empty body — add 1–3 user-facing bullet lines'),
    );
    return null;
  }
  final bullets = body.split('\n').where((l) => l.startsWith('- ')).length;
  if (bullets > 3) {
    stdout.writeln(
      '::warning::$name: $bullets bullets — keep entries to 1–3 '
      'user-facing lines (long-form rationale belongs in the PR/ticket)',
    );
  }
  return Entry(
    name,
    name,
    int.parse(match.group(1)!),
    type,
    meta['scope'] ?? '',
    meta['issue'] ?? '',
    body,
  );
}

void _validate(
  Directory entriesDir,
  List<String> files,
  List<EntryProblem> problems,
  List<Entry> entries,
) {
  if (!entriesDir.existsSync()) {
    stdout.writeln(
      '::error::changelog/entries/ does not exist — create it with the '
      'first entry file (gh-2463 conventions: docs/agents/commits-releases.md)',
    );
    exit(1);
  }
  var ok = true;
  for (final p in problems) {
    stdout.writeln('::error::${p.file}: ${p.message}');
    ok = false;
  }
  // Duplicate issues are RESOLVED by the aggregator (last file wins), so not
  // an error — but the author must see that one of their files will be
  // dropped from the notes.
  final byIssue = <String, List<Entry>>{};
  for (final e in entries) {
    if (e.issue.isNotEmpty) (byIssue[e.issue] ??= []).add(e);
  }
  for (final issue in byIssue.keys.toList()..sort()) {
    final group = byIssue[issue]!..sort((a, b) => a.sortKey.compareTo(b.sortKey));
    if (group.length > 1) {
      final winner = group.last.sortKey;
      for (final loser in group.take(group.length - 1)) {
        stdout.writeln(
          '::warning::duplicate issue $issue: $winner wins, '
          '${loser.sortKey} will be dropped from the notes',
        );
      }
    }
  }
  if (!ok) exit(1);
  stdout.writeln(
    'changelog entries: ${entries.length} file(s) valid '
    '(${byIssue.keys.length} issue-keyed)',
  );
}

/// Rework dedupe: same non-empty issue → last file in sort order wins.
List<Entry> _dedupe(List<Entry> entries) {
  final sorted = entries.toList()
    ..sort((a, b) {
      final byNum = a.sortNum.compareTo(b.sortNum);
      return byNum != 0 ? byNum : a.sortKey.compareTo(b.sortKey);
    });
  final winnerOf = <String, Entry>{};
  final losers = <Entry>[];
  for (final e in sorted) {
    if (e.issue.isEmpty) continue;
    final incumbent = winnerOf[e.issue];
    if (incumbent == null) {
      winnerOf[e.issue] = e;
    } else {
      // Sorted order means the later file is the rework.
      losers.add(incumbent == e ? incumbent : incumbent);
      winnerOf[e.issue] = e;
    }
  }
  final kept = sorted.where((e) => !losers.contains(e)).toList();
  for (final loser in losers) {
    final winner = winnerOf[loser.issue]!;
    stderr.writeln(
      'gen_changelog: note: dropping ${loser.sortKey} — issue ${loser.issue} '
      'is already covered by ${winner.sortKey} (rework dedupe)',
    );
  }
  return kept;
}

String _aggregate(List<Entry> entries, {required bool grouped}) {
  if (!grouped) {
    return entries.map((e) => e.body).join('\n') +
        (entries.isEmpty ? '' : '\n');
  }
  final buf = StringBuffer();
  for (final type in _types) {
    final group = entries.where((e) => e.type == type).toList();
    if (group.isEmpty) continue;
    if (buf.isNotEmpty) buf.writeln();
    buf.writeln('### ${_groupHeadings[type]}');
    buf.writeln();
    buf.write('${group.map((e) => e.body).join('\n')}\n');
  }
  return buf.toString();
}

// ── --write-changelog: the thin generated index ─────────────────────────────

const _changelogPreamble = '''
<!-- GENERATED FILE — `dart scripts/gen_changelog.dart --write-changelog`.
     DO NOT HAND-EDIT: the CI changelog guard rejects direct edits
     (gh-2463). Regenerate instead. -->

Per-change entries live in `changelog/entries/` — one Markdown file per
change (`<issue-or-pr>-<slug>.md`, YAML frontmatter `type`/`scope`/`issue`
plus 1–3 user-facing bullet lines). Every PR adds ITS OWN entry file
instead of editing this file, so parallel changes never touch a shared
file (zero merge conflicts by construction). At release time the pending
entries aggregate into the `Unreleased` section below and
`scripts/release_notes.sh` folds them into the release notes; versioned
history lives in `changelog/archive/` (one file per version — the
pre-1.0.506 tail stays in `CHANGELOG_ARCHIVE.md`). Conventions:
`docs/agents/commits-releases.md`.
''';

void _writeChangelog(List<Entry> kept) {
  final buf = StringBuffer('# Changelog\n\n$_changelogPreamble\n');
  buf.writeln('## Unreleased');
  buf.writeln();
  if (kept.isEmpty) {
    buf.writeln(
      '(Nothing pending — add `changelog/entries/<issue-or-pr>-<slug>.md` '
      'to your PR instead of editing this file.)',
    );
  } else {
    buf.write(_aggregate(kept, grouped: false));
  }
  buf.writeln();
  final archive = Directory('changelog/archive');
  if (archive.existsSync()) {
    buf.writeln('## Archive index');
    buf.writeln();
    for (final f in _archiveIndex(archive)) {
      buf.writeln('- [$f](changelog/archive/$f)');
    }
  }
  File('CHANGELOG.md').writeAsStringSync(buf.toString());
}

/// Version-named files first (newest version first, numeric compare —
/// lexicographic breaks at 1.0.100 vs 1.0.99), then non-version files
/// (legacy bodies) lexicographically.
List<String> _archiveIndex(Directory archive) {
  final names = archive
      .listSync()
      .whereType<File>()
      .map((f) => f.path.split(Platform.pathSeparator).last)
      .where((n) => n.endsWith('.md'))
      .toList();
  String base(String n) => n.substring(0, n.length - 3); // strip .md
  final versions = names.where((n) => _versionNameRe.hasMatch(base(n))).toList()
    ..sort((a, b) {
      List<int> v(String s) =>
          base(s).split('.').map(int.parse).toList();
      final va = v(a);
      final vb = v(b);
      for (var i = 0; i < 3; i++) {
        final c = vb[i].compareTo(va[i]); // desc
        if (c != 0) return c;
      }
      return b.compareTo(a);
    });
  final rest =
      names.where((n) => !_versionNameRe.hasMatch(base(n))).toList()..sort();
  return [...versions, ...rest];
}
