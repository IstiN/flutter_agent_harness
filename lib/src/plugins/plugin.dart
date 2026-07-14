/// Plugin/extension API for `fah`.
///
/// Shaped after [pi packages](https://pi.dev/packages): third-party packages
/// can extend the CLI with extra tools, hooks, slash commands, and
/// configuration without forking the core agent code.
library;

import '../agent/agent_tool.dart';
import '../env/execution_env.dart';

/// A slash-command handler registered by a plugin.
typedef SlashCommand = Future<void> Function(List<String> args);

/// IO surface exposed to plugins for writing to the terminal.
abstract interface class PluginIO {
  /// Writes [text] without a trailing newline.
  void write(String text);

  /// Writes [text] followed by a newline.
  void writeln(String text);
}

/// Context passed to [FahPlugin.register]. Plugins use it to contribute
/// capabilities to the running agent session.
final class PluginContext {
  /// Creates a plugin context.
  PluginContext({required this.env, required this.io, this.config = const {}});

  /// The execution environment backing the current CLI session.
  final ExecutionEnv env;

  /// Output channel for the plugin.
  final PluginIO io;

  /// Plugin-specific configuration from `.fah/packages.yaml`.
  final Map<String, dynamic> config;

  final List<AgentTool> _tools = [];
  final Map<String, SlashCommand> _slashCommands = {};

  /// Registers an [AgentTool] that will be available to the agent.
  void registerTool(AgentTool tool) => _tools.add(tool);

  /// Registers a `/name` slash command.
  void registerSlashCommand(String name, SlashCommand handler) {
    _slashCommands[name] = handler;
  }

  /// Tools collected from plugins.
  List<AgentTool> get tools => List.unmodifiable(_tools);

  /// Slash commands collected from plugins.
  Map<String, SlashCommand> get slashCommands =>
      Map.unmodifiable(_slashCommands);
}

/// Base interface for a `fah` plugin / package extension.
abstract interface class FahPlugin {
  /// Unique plugin name (matches the key in `.fah/packages.yaml`).
  String get name;

  /// Called once when the CLI starts. Use [context] to register tools,
  /// hooks, slash commands, and read plugin-specific [context.config].
  void register(PluginContext context);
}
