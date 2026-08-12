import '../plugins/plugin.dart';
import 'prompt_templates.dart';
import 'tui_repl.dart';

/// Builds the slash-menu items for [prefix]: builtin commands (matched on
/// name or description), plugin commands (name only), and prompt templates.
List<MenuItem> buildSlashMenuItems(
  String prefix, {
  required Map<String, String> slashCommands,
  required Map<String, SlashCommand> pluginSlashCommands,
  required List<PromptTemplate> templates,
}) {
  final lower = prefix.toLowerCase();
  final items = <MenuItem>[];
  for (final entry in slashCommands.entries) {
    if (entry.key.toLowerCase().contains(lower) ||
        entry.value.toLowerCase().contains(lower)) {
      items.add(
        MenuItem(key: entry.key, label: entry.key, description: entry.value),
      );
    }
  }
  for (final entry in pluginSlashCommands.entries) {
    if (entry.key.toLowerCase().contains(lower)) {
      items.add(MenuItem(key: entry.key, label: entry.key));
    }
  }
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

/// The builtin slash commands, in help/menu order.
const builtinSlashCommands = <String, String>{
  '/exit': 'quit',
  '/reset': 'start a new session',
  '/compact': 'summarize history to free context',
  '/stats': 'show token and cost totals',
  '/tasks': '[cancel <id>] — list background agents',
  '/skills': 'list discovered skills (invoke with /skill:<name>)',
  '/model': '<provider/model> — select model (opens selector)',
  '/models': '[filter] | config | set <slot> <model> [baseUrl] | remove <slot>',
  '/model-edit':
      '[contextWindow|maxTokens <n>] — show or override token limits',
  '/provider':
      '[name] [baseUrl] [token] | add | custom — switch or add provider',
  // /provider-edit removed — edit/delete is now inline in /provider picker.
  '/mode': '[name] — show or switch the active mode',
  '/session': '[name] — show current or switch/create a named session',
  '/session-new': '<name> — create a new named session',
  '/sessions': 'list named sessions for the current directory',
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
/// templates, and the steer hint.
List<String> helpLines({
  String filter = '',
  required Map<String, SlashCommand> pluginSlashCommands,
  required List<PromptTemplate> templates,
  required TuiStyle style,
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
  // Plugin commands, prompt templates, and the steer hint are part of the
  // full listing only, never of a filtered one.
  if (filter.isNotEmpty) return lines;
  return [...lines, ..._helpExtrasLines(pluginSlashCommands, templates, style)];
}

/// The no-match line for a filtered `/help`.
String _helpEmptyLine(String filter) => filter.isNotEmpty
    ? 'unknown command: /$filter (try /help)'
    : 'no commands match "$filter"';

/// The full-listing appendix: plugin commands, prompt templates, and the
/// steer hint.
List<String> _helpExtrasLines(
  Map<String, SlashCommand> pluginSlashCommands,
  List<PromptTemplate> templates,
  TuiStyle style,
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
    '',
    style.dim('While a run streams, type to steer the agent; Ctrl-C aborts.'),
  ];
}

/// The numbered command list of the line-mode menu, as styled lines.
List<String> lineModeMenuLines(TuiStyle style) {
  final commands = builtinSlashCommands.entries.toList();
  return [
    '',
    style.bold('[Commands]'),
    for (var i = 0; i < commands.length; i++)
      '  ${i + 1}) ${style.cyan(commands[i].key)} ${commands[i].value}',
    '',
  ];
}
