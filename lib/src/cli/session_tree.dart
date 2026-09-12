/// Tree-grouped session listings (issue #198): the shared pure row model +
/// renderer behind the REPL's `/sessions` list, the TUI sessions picker,
/// and the headless `fa session list` command.
///
/// Pure Dart (no `dart:io`), so all three entries render identically and
/// the headless path runs without booting the agent.
library;

import 'dart:convert';

import '../env/execution_env.dart';
import '../session/session_grouping.dart';
import '../session/session_repo.dart';
import '../session/session_storage.dart';
import 'tui_repl.dart';

/// One display row of a session listing: a main (numbered), an indented
/// child (`↳`), or an orphaned child surfaced top-level.
final class SessionListRow {
  const SessionListRow({
    required this.metadata,
    required this.label,
    required this.number,
    required this.isChild,
    required this.orphaned,
    required this.agentCount,
    required this.active,
  });

  final SessionMetadata metadata;

  /// Display name: the session's name, or `subagent <short-id>` for an
  /// unnamed child (never a bare id for children).
  final String label;

  /// 1-based row number — mains in tree mode, every row in flat mode;
  /// 0 for indented children.
  final int number;

  /// Rendered indented under its parent.
  final bool isChild;

  /// A subagent whose parent is missing from the listed set.
  final bool orphaned;

  /// Children count for a parent row (0 otherwise); the `[+N agents]`
  /// suffix source.
  final int agentCount;

  /// Whether this row is the currently active session.
  final bool active;
}

/// Builds the display rows for [sessions] (already in the caller's display
/// order — the CLI passes current-folder-first activity order).
///
/// [flat] renders a single-level list: every session numbered in input
/// order, no tree classification or nesting (the toggle's non-tree view,
/// not a byte-for-byte legacy output).
/// Tree mode numbers top-level rows sequentially and nests the rest
/// under their parent; [names] supplies resolved display names and
/// [currentSessionPath] marks the active row.
List<SessionListRow> buildSessionListRows({
  required List<SessionMetadata> sessions,
  required bool flat,
  Map<String, String> names = const {},
  String? currentSessionPath,
}) {
  final groups = flat
      ? [for (final s in sessions) SessionGroup(main: s)]
      : groupSessionsByParent(sessions);
  String labelFor(SessionMetadata m) {
    final name = names[m.id];
    if (name != null && name.isNotEmpty) return name;
    return !flat && isSubagentSession(m)
        ? 'subagent ${m.id.substring(0, m.id.length.clamp(0, 8))}'
        : m.id;
  }

  final rows = [
    for (final group in groups) ...[
      SessionListRow(
        metadata: group.main,
        label: labelFor(group.main),
        number: 0,
        isChild: false,
        // Flat mode: no tree classification, nothing marks a subagent.
        orphaned: !flat && isSubagentSession(group.main),
        agentCount: group.children.length,
        active: group.main.path == currentSessionPath,
      ),
      for (final child in group.children)
        SessionListRow(
          metadata: child,
          label: labelFor(child),
          number: 0,
          isChild: true,
          orphaned: false,
          agentCount: 0,
          active: child.path == currentSessionPath,
        ),
    ],
  ];
  // Number the top-level rows sequentially; flat mode numbers every row.
  var next = 1;
  return [
    for (final row in rows)
      flat || !row.isChild
          ? SessionListRow(
              metadata: row.metadata,
              label: row.label,
              number: next++,
              isChild: row.isChild,
              orphaned: row.orphaned,
              agentCount: row.agentCount,
              active: row.active,
            )
          : row,
  ];
}

/// Resolves each session's display name from its `session_info` record —
/// the same name `/rename` writes. Unreadable files degrade to no name.
Future<Map<String, String>> sessionDisplayNames(
  SessionRepo repo,
  List<SessionMetadata> sessions,
) async {
  final names = <String, String>{};
  for (final metadata in sessions) {
    try {
      final name = await (await repo.open(
        metadata,
        windowed: true,
      )).resolveSessionName();
      if (name != null && name.isNotEmpty) names[metadata.id] = name;
    } on Object {
      // Unreadable session: its row degrades to the bare id.
    }
  }
  return names;
}

/// Renders [rows] as printable lines. [dim] styles the low-emphasis parts
/// (the caller passes its own styling; tests pass null).
List<String> formatSessionListLines(
  List<SessionListRow> rows, {
  String Function(String text)? dim,
}) {
  String dimmed(String text) => dim == null ? text : dim(text);

  String folderTag(SessionMetadata m) {
    final base = m.cwd.split('/').last;
    if (base.isEmpty || base == '.' || base == '..') return '';
    return ' [$base]';
  }

  String parentLine(SessionListRow row) {
    final stamp = dimmed(row.metadata.createdAt.toLocal().toIso8601String());
    final agents = row.agentCount > 0
        ? '  ${dimmed('[+${row.agentCount} agents]')}'
        : '';
    final orphan = row.orphaned ? ' ${dimmed('(orphaned)')}' : '';
    return '  ${row.active ? '*' : ' '}${row.number}) ${row.label}'
        '${folderTag(row.metadata)}$agents$orphan  $stamp';
  }

  return [
    for (final row in rows)
      if (row.isChild)
        '      ↳ ${row.label} · subagent  '
            '${dimmed(row.metadata.createdAt.toLocal().toIso8601String())}'
      else
        parentLine(row),
  ];
}

/// The headless `fa session list [--json] [--flat]` command: lists every
/// session in the shared root (current folder first, issue #83) without
/// booting the agent. `--json` writes one compact NDJSON row per session
/// with the additive `agent`/`parent` fields; text mode prints the tree
/// (`--flat` prints that single-level view). [write]/[writeln] are the
/// host's output channel (a [CliIO] tear-off pair) so this file stays a
/// standalone library.
Future<int> runSessionListCliCommand({
  required void Function(String text) write,
  required void Function(String text) writeln,
  required FileSystem env,
  required String sessionRoot,
  String? cwd,
  required bool json,
  required bool flat,
}) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: sessionRoot);
  final List<SessionMetadata> sessions;
  try {
    sessions = sortSessionsCurrentFolderFirst(await repo.list(), cwd);
  } on Object catch (error) {
    writeln('failed to list sessions: $error');
    return 1;
  }
  if (sessions.isEmpty) {
    writeln('no sessions');
    return 0;
  }
  final names = await sessionDisplayNames(repo, sessions);
  if (json) {
    for (final metadata in sessions) {
      write('${jsonEncode(_sessionJsonRow(metadata, names[metadata.id]))}\n');
    }
    return 0;
  }
  writeln('sessions:');
  for (final line in formatSessionListLines(
    buildSessionListRows(sessions: sessions, flat: flat, names: names),
  )) {
    writeln(line);
  }
  writeln('switch: fa --session <name> · flat view: fa session list --flat');
  return 0;
}

Map<String, Object?> _sessionJsonRow(SessionMetadata m, String? name) => {
  'id': m.id,
  if (name != null) 'name': name,
  'cwd': m.cwd,
  'createdAt': m.createdAt.toIso8601String(),
  'lastUpdatedAt': (m.lastUpdatedAt ?? m.createdAt).toIso8601String(),
  'agent': m.metadata?['agent'],
  'parent': subagentParentId(m),
};

/// TUI sessions-picker items for [rows] (issue #198): the view toggle rides
/// first (`flat`/`tree`), then one item per row — parents numbered, children
/// indented with `↳`. Keys are `r<index>` into [rows], resolved by the
/// host against its cached row list.
List<MenuItem> sessionPickerItems(
  List<SessionListRow> rows, {
  required bool flat,
  bool toggle = true,
}) {
  return [
    if (toggle)
      MenuItem(
        key: flat ? 'tree' : 'flat',
        label: flat ? '⟳ tree view' : '⟳ flat list',
        description: 'switch the sessions listing layout',
      ),
    for (var i = 0; i < rows.length; i++)
      MenuItem(
        key: 'r$i',
        label: rows[i].isChild
            ? '   ↳ ${rows[i].label}'
            : '${rows[i].number}) ${rows[i].label}'
                  '${rows[i].agentCount > 0 ? '  [+${rows[i].agentCount} agents]' : ''}',
        description: _sessionPickerDescription(rows[i]),
      ),
  ];
}

/// Folder + classification tags + last-update timestamp for one
/// sessions-picker row.
String _sessionPickerDescription(SessionListRow row) {
  final metadata = row.metadata;
  final tags = [
    if (row.active) 'current',
    if (row.orphaned) 'orphaned',
    if (row.isChild || isSubagentSession(metadata)) 'subagent',
  ];
  final base = metadata.cwd.split('/').last;
  final folder = base.isEmpty || base == '.' ? '' : base;
  final timestamp = (metadata.lastUpdatedAt ?? metadata.createdAt)
      .toLocal()
      .toIso8601String();
  final stamp = folder.isEmpty ? timestamp : '$folder · $timestamp';
  return tags.isEmpty ? stamp : '${tags.join(' · ')} · $stamp';
}
