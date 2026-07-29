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
