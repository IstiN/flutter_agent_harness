/// Plugin/extension API for `fah`.
///
/// Shaped after [pi packages](https://pi.dev/packages): third-party packages
/// can extend the CLI with extra tools, hooks, slash commands, and
/// configuration without forking the core agent code.
library;

import '../agent/agent_tool.dart';
import '../env/execution_env.dart';
import '../messaging/agent_message.dart';

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
  final List<ExternalInbox> _externalInboxes = [];

  /// Registers an [AgentTool] that will be available to the agent.
  void registerTool(AgentTool tool) => _tools.add(tool);

  /// Registers a `/name` slash command.
  void registerSlashCommand(String name, SlashCommand handler) {
    _slashCommands[name] = handler;
  }

  /// Registers an external inbox (e.g. a network hub mailbox) whose mail
  /// is drained into the agent loop as steering messages at every turn
  /// boundary.
  void registerExternalInbox(ExternalInbox inbox) =>
      _externalInboxes.add(inbox);

  /// Tools collected from plugins.
  List<AgentTool> get tools => List.unmodifiable(_tools);

  /// Slash commands collected from plugins.
  Map<String, SlashCommand> get slashCommands =>
      Map.unmodifiable(_slashCommands);

  /// External inboxes collected from plugins (unmodifiable).
  List<ExternalInbox> get externalInboxes =>
      List.unmodifiable(_externalInboxes);
}

/// A plugin-provided inbox drained into the agent loop as steering
/// messages, oldest first. Sources may be remote (a hub connection), so
/// both callbacks must be cheap and [drain] must never throw — a failing
/// drain returns an empty list instead.
final class ExternalInbox {
  const ExternalInbox({required this.drain, this.hasPending});

  /// Consumes the unread messages, oldest first. Never throws; an empty
  /// list means "nothing arrived".
  final Future<List<AgentMessage>> Function() drain;

  /// Non-draining probe: true when at least one unread message waits.
  /// Optional — inboxes without it cannot wake the idle loop or soften a
  /// long tool call, only deliver at turn boundaries.
  final Future<bool> Function()? hasPending;
}

/// Base interface for a `fah` plugin / package extension.
abstract interface class FahPlugin {
  /// Unique plugin name (matches the key in `.fah/packages.yaml`).
  String get name;

  /// Called once when the CLI starts. Use [context] to register tools,
  /// hooks, slash commands, and read plugin-specific [context.config].
  void register(PluginContext context);

  /// Releases plugin resources at CLI shutdown — sockets, processes,
  /// timers. Called once by the CLI after the REPL exits; the default is
  /// a no-op. One failing plugin must not block exit: the CLI swallows
  /// dispose errors.
  Future<void> dispose() async {}
}
