/// The `saveCliConfig` merge machinery (gh-2422): the three-way emit over
/// top-level yaml blocks and the project-file targeting. A `part` of
/// `cli_config.dart` (the save owns the write chains and the atomic write,
/// this file owns the block algebra), so the helpers see the library's
/// private members (`_serializedConfigWrite`, `_atomicConfigWrite`).
///
/// Vocabulary: a "top-level block" is one column-0 `key:` line plus its
/// indented/comment continuation lines — exactly what the disk backstop
/// always carved out (`_topLevelYamlBlock`). The typed `toYaml()` renders
/// are unions of such blocks, so a per-block comparison of two renders IS
/// a per-section comparison.
part of 'cli_config.dart';

/// The project-capable sections a save may target into
/// `<projectDir>/.fah/config.yaml`: every section the boot actually reads
/// from there (the `loadProject*` loaders in this library — each wins over
/// the user file). `agent` is NOT in the set: the project file participates
/// in only its `contextWindowCap` key, and a whole-section write would drag
/// user-file-only members into the repo-traveling file (nothing in
/// `persistConfig` mutates `agent:` either).
const _projectSaveSections = <String>{
  'memory',
  'cube',
  'tools',
  'spills',
  'compaction',
  'trajectory',
  'logging',
};

/// The column-0 `key:` line pattern every top-level block starts with.
final RegExp _topLevelKeyPattern = RegExp(r'^([A-Za-z][A-Za-z0-9_-]*):');

/// The exclusive end index of the top-level block that starts at
/// [start]: the first line the block's continuation rule rejects.
/// Blank, indented and column-0 comment lines continue the block —
/// comments are invisible to yaml indentation, so a `# …` line between
/// the section's own lines is still inside the section (stopping at it
/// would truncate the block and silently drop every line below).
int _blockEndLine(List<String> lines, int start) {
  var end = start + 1;
  while (end < lines.length &&
      (lines[end].isEmpty ||
          lines[end].startsWith(' ') ||
          lines[end].startsWith('\t') ||
          lines[end].startsWith('#'))) {
    end++;
  }
  return end;
}

/// The top-level block of [text] for [key] (key line + indented/comment
/// body) as a trailing-newline-terminated string, or null when absent.
String? _topLevelYamlBlock(String text, String key) {
  final lines = text.split('\n');
  var start = -1;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('$key:')) {
      start = i;
      break;
    }
  }
  if (start < 0) return null;
  final end = _blockEndLine(lines, start);
  return '${lines.sublist(start, end).join('\n').trimRight()}\n';
}

/// Every top-level block of [text] as `key → block` (see
/// [_topLevelYamlBlock]). Column-0 lines before the first key (a file
/// header comment) belong to no block. A typed render never repeats a
/// key, and neither does a valid yaml document — duplicate column-0 keys
/// would be duplicate mapping keys, which yaml forbids.
Map<String, String> _topLevelYamlBlocks(String text) {
  final blocks = <String, String>{};
  final lines = text.split('\n');
  var i = 0;
  while (i < lines.length) {
    final match = _topLevelKeyPattern.firstMatch(lines[i]);
    if (match == null) {
      i++;
      continue;
    }
    final key = match.group(1)!;
    final end = _blockEndLine(lines, i);
    blocks[key] = '${lines.sublist(i, end).join('\n').trimRight()}\n';
    i = end;
  }
  return blocks;
}

/// The three-way emit for a save with the boot baseline [base]:
/// [merged]'s render minus every top-level block whose render is
/// byte-identical to the baseline's — those sections the process did NOT
/// change, so the on-disk block (whatever another process made of it)
/// survives through the disk backstop. [removed] lists the keys the
/// process REMOVED (rendered by the baseline, not by the current config —
/// an emptied `models:` is the removal form) so the backstop does not
/// resurrect them from disk. Without a baseline the whole render is the
/// emit and nothing counts as removed: the legacy caller-wins contract
/// the section-preservation regression tests pin.
({String emitted, Set<String> removed}) _threeWayEmit(
  CliConfig merged,
  CliConfig? base,
) {
  final rendered = merged.toYaml();
  if (base == null) {
    return (emitted: rendered, removed: const <String>{});
  }
  final baseBlocks = _topLevelYamlBlocks(base.toYaml());
  final newBlocks = _topLevelYamlBlocks(rendered);
  final kept = StringBuffer();
  for (final entry in newBlocks.entries) {
    if (baseBlocks[entry.key] != entry.value) kept.write(entry.value);
  }
  final removed = <String>{
    for (final key in baseBlocks.keys)
      if (!newBlocks.containsKey(key)) key,
  };
  return (emitted: kept.toString(), removed: removed);
}

/// Drops [keys]' blocks from a top-level-block union [emitted] — the
/// sections the project write took over must not re-render into the
/// global file too.
String _dropTopLevelBlocks(String emitted, Set<String> keys) {
  if (keys.isEmpty || emitted.isEmpty) return emitted;
  final buffer = StringBuffer();
  for (final entry in _topLevelYamlBlocks(emitted).entries) {
    if (!keys.contains(entry.key)) buffer.write(entry.value);
  }
  return buffer.toString();
}

/// Replaces [key]'s top-level block in [text] with [block], appending it
/// when the key is absent. Every unrelated line — other sections, their
/// comments — stays byte-identical. Column-0 comment lines the old block
/// absorbed stay in place: they usually annotate whatever follows, not
/// the section's own members.
String _replaceTopLevelBlock(String text, String key, String block) {
  final lines = text.split('\n');
  final start = lines.indexWhere((line) => line.startsWith('$key:'));
  final newLines = block.trimRight().split('\n');
  if (start < 0) {
    final spacer = text.isNotEmpty && !text.endsWith('\n') ? '\n' : '';
    return '$text$spacer${newLines.join('\n')}\n';
  }
  final end = _blockEndLine(lines, start);
  var commentStart = end;
  while (commentStart > start + 1 && lines[commentStart - 1].startsWith('#')) {
    commentStart--;
  }
  return [
    ...lines.sublist(0, start),
    ...newLines,
    ...lines.sublist(commentStart, end),
    ...lines.sublist(end),
  ].join('\n');
}

/// Writes every project-capable section ([_projectSaveSections]) the
/// caller CHANGED vs [base] into `<projectDir>/.fah/config.yaml` when the
/// section LIVES there — the project scope wins at boot, so the edit must
/// land in the file that wins — and returns the targeted keys for the
/// caller's global emit. Upserts only: a section the caller REMOVED never
/// targets the project file (the repo-traveling policy is not this
/// session's to delete — the removal cleans the global file through the
/// caller's removed-keys flow). Nothing targets when the project file is
/// absent (the global file stays the destination) or unparseable (left
/// alone; the global write proceeds as if it did not exist). A project
/// path resolving to [globalConfigPath] targets nothing either — the
/// global write IS the write there, and nesting it in the same serialized
/// chain would deadlock. Returns an empty set without a [base]: the
/// legacy call shape has no notion of "this process changed it".
Future<Set<String>> _saveChangedProjectSections({
  required String projectDir,
  required CliConfig config,
  required CliConfig? base,
  required String globalConfigPath,
}) async {
  if (base == null) return const {};
  final file = File('$projectDir/.fah/config.yaml');
  if (!file.existsSync()) return const {};
  if (_samePath(file.path, globalConfigPath)) return const {};
  final doc = _parseYamlMapOrNull(file.readAsStringSync());
  if (doc == null) return const {};
  final newBlocks = _topLevelYamlBlocks(config.toYaml());
  final baseBlocks = _topLevelYamlBlocks(base.toYaml());
  final targets = _projectTargets(doc, baseBlocks, newBlocks);
  if (targets.isEmpty) return const {};
  await _serializedConfigWrite(file.path, () async {
    var text = file.existsSync() ? file.readAsStringSync() : '';
    for (final key in targets) {
      text = _replaceTopLevelBlock(text, key, newBlocks[key]!);
    }
    if (!text.endsWith('\n')) text = '$text\n';
    // Never persist a project file the next boot would reject: the edited
    // document must parse and every carried section must pass the real
    // strict parsers (same refusal rule as the global merge step).
    final edited = _parseYamlMapOrNull(text);
    if (edited == null) {
      throw ConfigException('refusing to write unparseable ${file.path}');
    }
    CliConfig.fromYaml(edited);
    await _atomicConfigWrite(file, text);
  });
  return targets;
}

/// The project-capable keys that live in [doc], changed between the
/// [baseBlocks] and [newBlocks] renders, and still rendered by the new
/// config (upserts only — a removal never targets the project file).
Set<String> _projectTargets(
  YamlMap doc,
  Map<String, String> baseBlocks,
  Map<String, String> newBlocks,
) {
  final carried = <String>{
    for (final key in doc.keys)
      if (_projectSaveSections.contains('$key')) '$key',
  };
  if (carried.isEmpty) return const {};
  return <String>{
    for (final key in carried)
      if (_sectionChanged(key, baseBlocks, newBlocks) &&
          newBlocks.containsKey(key))
        key,
  };
}

/// Whether [key]'s render differs between the baseline and the current
/// config (an absent current block with a present baseline block is a
/// removal; absent on both sides is not a change).
bool _sectionChanged(
  String key,
  Map<String, String> baseBlocks,
  Map<String, String> newBlocks,
) {
  final newBlock = newBlocks[key];
  if (newBlock == null) return baseBlocks.containsKey(key);
  return newBlock != baseBlocks[key];
}

/// [text] parsed as a yaml map, or null when it does not parse to one.
/// Used where a broken document must degrade (the project targeting
/// falls back to the global destination) — never where it must fail
/// loudly (that is the caller's `_mergeWithOnDisk` / pre-write validation
/// with their own named [ConfigException]s).
YamlMap? _parseYamlMapOrNull(String text) {
  if (text.trim().isEmpty) return null;
  try {
    final doc = loadYaml(text);
    return doc is YamlMap ? doc : null;
  } on Object {
    return null;
  }
}

/// Whether two config paths address the same file: absolute form with
/// trailing separators trimmed (symlinks are NOT resolved — the boot's
/// `cwd == home` guard compares the same way through the config service).
bool _samePath(String a, String b) {
  String normalize(String path) {
    final absolute = File(path).absolute.path.replaceAll(RegExp(r'/+$'), '');
    return absolute;
  }

  return normalize(a) == normalize(b);
}
