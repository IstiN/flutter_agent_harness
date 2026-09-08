import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/slash_menu.dart';
import 'package:test/test.dart';

void main() {
  group('PluginContext interactive surface', () {
    test('registerSlashCommand stores the optional description', () {
      final context = PluginContext(
        env: MemoryExecutionEnv(),
        io: _FakePluginIO(),
      );
      context.registerSlashCommand(
        '/dap',
        (_) async {},
        description: 'DAP hub messaging',
      );
      context.registerSlashCommand('/plain', (_) async {});

      expect(context.slashCommandDescriptions['/dap'], 'DAP hub messaging');
      expect(context.slashCommandDescriptions.containsKey('/plain'), isFalse);
    });

    test('pickOption/askLine callbacks are exposed to the plugin', () {
      Future<String?> pick(
        String title,
        List<PluginMenuOption> options, {
        String? initialKey,
      }) async => 'k';
      Future<String?> ask(String question, {bool secret = false}) async => 'a';
      final context = PluginContext(
        env: MemoryExecutionEnv(),
        io: _FakePluginIO(),
        pickOption: pick,
        askLine: ask,
      );

      expect(context.pickOption, same(pick));
      expect(context.askLine, same(ask));
    });

    test('pickOption/askLine default to null (non-interactive host)', () {
      final context = PluginContext(
        env: MemoryExecutionEnv(),
        io: _FakePluginIO(),
      );
      expect(context.pickOption, isNull);
      expect(context.askLine, isNull);
    });
  });

  group('slash menu plugin items', () {
    test('plugin commands carry their description as the menu hint', () {
      final items = buildSlashMenuItems(
        'dap',
        slashCommands: const {},
        pluginSlashCommands: {'/dap': (_) async {}},
        pluginSlashDescriptions: const {'/dap': 'DAP hub messaging'},
        templates: const [],
      );
      final dap = items.singleWhere((item) => item.key == '/dap');
      expect(dap.description, 'DAP hub messaging');
    });

    test('a plugin command shadows the same ext command (no duplicates)', () {
      final items = buildSlashMenuItems(
        'dap',
        slashCommands: const {},
        pluginSlashCommands: {'/dap': (_) async {}},
        extSlashCommands: {'/dap': (_) async {}},
        templates: const [],
      );
      expect(items.where((item) => item.key == '/dap'), hasLength(1));
    });
  });
}

class _FakePluginIO implements PluginIO {
  @override
  void write(String text) {}

  @override
  void writeln(String text) {}
}
