/// flutter_agent_harness plugin seam, mirrored from upstream
/// `lib/src/plugins/plugin.dart`.
///
/// In the upstream PR this file is deleted; imports point at the real
/// `package:flutter_agent_harness/src/plugins/plugin.dart`. `PluginContext`
/// is mirrored as the subset this package consumes (config + io); upstream
/// also carries `env` and tool/slash registries.
library;

import 'messaging.dart';

/// A slash-command handler registered by a plugin (upstream shape).
typedef SlashCommand = Future<void> Function(List<String> args);

/// IO surface exposed to plugins for writing to the terminal.
abstract interface class PluginIO {
  /// Writes [text] without a trailing newline.
  void write(String text);

  /// Writes [text] followed by a newline.
  void writeln(String text);
}

/// Context passed to [FahPlugin.register].
final class PluginContext {
  PluginContext({this.io, this.config = const {}});

  /// Output channel for the plugin.
  final PluginIO? io;

  /// Plugin-specific configuration from `.fah/packages.yaml`.
  final Map<String, dynamic> config;
}

/// Base interface for a `fah` plugin / package extension.
abstract interface class FahPlugin {
  /// Unique plugin name (matches the key in `.fah/packages.yaml`).
  String get name;

  /// Called once when the CLI starts.
  void register(PluginContext context);
}

/// The `Agent.externalSteeringSource` seam: called at every turn boundary
/// (before the first turn and after each one); drained BEFORE the
/// in-process steering queue. Contract: must not throw; return an empty
/// list when nothing arrived.
///
/// Upstream's `QueuedMessagesSource` returns `List<Message>` (provider
/// messages); the PR maps each drained [AgentMessage] to a user `Message`
/// with a one-line adapter at the call site.
typedef ExternalSteeringSource = Future<List<AgentMessage>> Function();
