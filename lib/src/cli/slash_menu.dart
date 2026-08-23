import '../plugins/plugin.dart';
import '../skills/skills.dart';
import 'prompt_templates.dart';
import 'tui_repl.dart';

/// Builds the slash-menu items for [prefix]: builtin commands (matched on
/// name or description), plugin commands (name only), prompt templates, and
/// user-invocable skills (name or description). A skill's key carries a
/// trailing space so accepting it leaves the cursor ready for args.
List<MenuItem> buildSlashMenuItems(
  String prefix, {
  required Map<String, String> slashCommands,
  required Map<String, SlashCommand> pluginSlashCommands,
  required List<PromptTemplate> templates,
  List<Skill> skills = const [],
}) {
  final lower = prefix.toLowerCase();
  return [
    ..._builtinMenuItems(slashCommands, lower),
    ..._pluginMenuItems(pluginSlashCommands, lower),
    ..._templateMenuItems(templates, lower),
    ..._skillMenuItems(skills, lower),
  ];
}

List<MenuItem> _builtinMenuItems(
  Map<String, String> slashCommands,
  String lower,
) {
  final items = <MenuItem>[];
  for (final entry in slashCommands.entries) {
    if (entry.key.toLowerCase().contains(lower) ||
        entry.value.toLowerCase().contains(lower)) {
      items.add(
        MenuItem(key: entry.key, label: entry.key, description: entry.value),
      );
    }
  }
  return items;
}

List<MenuItem> _pluginMenuItems(
  Map<String, SlashCommand> pluginSlashCommands,
  String lower,
) {
  final items = <MenuItem>[];
  for (final entry in pluginSlashCommands.entries) {
    if (entry.key.toLowerCase().contains(lower)) {
      items.add(MenuItem(key: entry.key, label: entry.key));
    }
  }
  return items;
}

List<MenuItem> _templateMenuItems(
  List<PromptTemplate> templates,
  String lower,
) {
  final items = <MenuItem>[];
  for (final t in templates) {
    final name = '/${t.name}';
    if (name.toLowerCase().contains(lower)) {
      items.add(
        MenuItem(key: name, label: name, description: t.argumentHint ?? ''),
      );
    }
  }
  return items;
}

List<MenuItem> _skillMenuItems(List<Skill> skills, String lower) {
  final items = <MenuItem>[];
  for (final skill in userInvocableSkills(skills)) {
    final hint = skill.manifest.argumentHint;
    final description = hint == null || hint.isEmpty
        ? skill.description
        : '${skill.description} $hint';
    // The prefix carries the leading slash — match it like templates do.
    if ('/${skill.name}'.toLowerCase().contains(lower) ||
        skill.description.toLowerCase().contains(lower)) {
      items.add(
        MenuItem(
          key: '/skill:${skill.name} ',
          label: '/${skill.name}',
          description: description,
        ),
      );
    }
  }
  return items;
}

/// The skills offered by the slash menu / line-mode menu: explicit
/// invocation requires the manifest's `user-invocable` (default true).
Iterable<Skill> userInvocableSkills(List<Skill> skills) =>
    skills.where((s) => s.userInvocable);

/// The builtin slash commands, in help/menu order.
const builtinSlashCommands = <String, String>{
  '/exit': 'quit',
  '/reset': 'start a new session',
  '/compact': 'summarize history to free context',
  '/stats': 'show token and cost totals',
  '/tasks': '[cancel <id>] — list background agents',
  '/memory': '[maintain] — memory stats or run consolidation',
  '/a2a': 'show A2A remote agent servers status',
  '/skills': 'list discovered skills (invoke with /skill:<name>)',
  '/agents': '[types|<id>|open <id>] — live agents tree, observe, open session',
  '/model': '<provider/model> — select model (opens selector)',
  '/models': '[filter] | config | set <slot> <model> [baseUrl] | remove <slot>',
  '/model-edit':
      '[contextWindow|maxTokens <n>] — show or override token limits',
  '/provider':
      '[name] [baseUrl] [token] | add | custom — switch or add provider',
  '/providers': 'alias for /provider',
  // /provider-edit removed — edit/delete is now inline in /provider picker.
  '/mode': '[name] — show or switch the active mode',
  '/session': '[name] — show current or switch/create a named session',
  '/session-new': '<name> — create a new named session',
  '/sessions': 'list all sessions across workspaces',
  '/resume': 'switch to the most recent session',
  '/rename-session': '<name> — rename the current session',
  '/approval': '[mode] — show or set tool approval',
  '/settings': '— settings hub: provider, model, approval, keys, MCP',
  '/allow': '[tool] — always-allow a tool (or list them)',
  '/mcp': '[list|reload] — show MCP servers or reload config',
  '/code': 'switch to coding mode',
  '/architect': 'switch to architect mode',
  '/review': 'switch to review mode',
  '/help': 'this help',
  '!': '<command> — run a shell command directly',
};

/// The `/help` listing as styled lines: the (optionally filtered) builtin
/// commands, then — for the full listing only — plugin commands, prompt
/// templates, skills, and the steer hint.
List<String> helpLines({
  String filter = '',
  required Map<String, SlashCommand> pluginSlashCommands,
  required List<PromptTemplate> templates,
  required TuiStyle style,
  List<Skill> skills = const [],
}) {
  final lower = filter.toLowerCase();
  final entries = builtinSlashCommands.entries
      .where(
        (e) =>
            e.key.toLowerCase().contains(lower) ||
            e.value.toLowerCase().contains(lower),
      )
      .toList();
  if (entries.isEmpty) return [_helpEmptyLine(filter)];
  final lines = [
    style.bold(filter.isEmpty ? '[Commands]' : '[Commands matching "$filter"]'),
    for (final entry in entries)
      '  ${style.cyan(entry.key.padRight(18))} ${entry.value}',
  ];
  // Plugin commands, prompt templates, skills, and the steer hint are part
  // of the full listing only, never of a filtered one.
  if (filter.isNotEmpty) return lines;
  return [
    ...lines,
    ..._helpExtrasLines(pluginSlashCommands, templates, style, skills),
  ];
}

/// The no-match line for a filtered `/help`.
String _helpEmptyLine(String filter) => filter.isNotEmpty
    ? 'unknown command: /$filter (try /help)'
    : 'no commands match "$filter"';

/// The full-listing appendix: plugin commands, prompt templates, skills,
/// and the steer hint.
List<String> _helpExtrasLines(
  Map<String, SlashCommand> pluginSlashCommands,
  List<PromptTemplate> templates,
  TuiStyle style,
  List<Skill> skills,
) {
  return [
    if (pluginSlashCommands.isNotEmpty) ...[
      '',
      style.bold('[Plugin commands]'),
      for (final entry in pluginSlashCommands.entries)
        '  ${style.cyan(entry.key)}',
    ],
    if (templates.isNotEmpty) ...[
      '',
      style.bold('[Prompt templates]'),
      for (final t in templates)
        '  ${style.cyan('/${t.name}')} ${t.argumentHint ?? ''}',
    ],
    if (skills.isNotEmpty) ...[
      '',
      style.bold('[Skills]'),
      for (final s in skills) '  ${style.cyan('/${s.name}')} ${s.description}',
    ],
    '',
    style.dim('While a run streams, type to steer the agent; Ctrl-C aborts.'),
  ];
}

/// The numbered entries of the line-mode menu: builtin commands, then
/// user-invocable skills (a skill choice resolves to `/skill:<name>`).
List<MenuItem> lineModeMenuEntries(List<Skill> skills) {
  return [
    for (final entry in builtinSlashCommands.entries)
      MenuItem(key: entry.key, label: entry.key, description: entry.value),
    for (final skill in userInvocableSkills(skills))
      MenuItem(
        key: '/skill:${skill.name}',
        label: '/${skill.name}',
        description: skill.description,
      ),
  ];
}

/// The numbered command list of the line-mode menu, as styled lines.
List<String> lineModeMenuLines(
  TuiStyle style, {
  List<Skill> skills = const [],
}) {
  final entries = lineModeMenuEntries(skills);
  return [
    '',
    style.bold('[Commands]'),
    for (var i = 0; i < entries.length; i++)
      '  ${i + 1}) ${style.cyan(entries[i].label)} ${entries[i].description}',
    '',
  ];
}

/// Resolves a line-mode menu answer: a 1-based number over the builtin
/// commands + skills, or a command/skill name with or without the leading
/// slash. Null when neither matches.
String? resolveLineModeMenuChoice(String trimmed, List<Skill> skills) {
  final entries = lineModeMenuEntries(skills);
  // Numeric choice.
  final index = int.tryParse(trimmed);
  if (index != null && index >= 1 && index <= entries.length) {
    return entries[index - 1].key;
  }
  // Name choice; accept with or without leading slash. Builtins first.
  final name = trimmed.startsWith('/') ? trimmed : '/$trimmed';
  if (builtinSlashCommands.containsKey(name)) return name;
  for (final skill in userInvocableSkills(skills)) {
    if ('/${skill.name}'.toLowerCase() == name.toLowerCase()) {
      return '/skill:${skill.name}';
    }
  }
  return null;
}
