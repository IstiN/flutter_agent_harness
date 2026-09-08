/// The `fabric:` config section (issue #27 phase 2): the host's discovery
/// announcements — the CLI-side form of `fabric.enable(name, capabilities)`.
/// Parsed strictly: a bad schema throws [ConfigException] instead of
/// silently dropping the announcements.
library;

import 'package:yaml/yaml.dart';

import '../exceptions.dart';
import 'messaging_repository.dart';

/// The host's announced identity metadata for the messaging fabric.
final class FabricConfig {
  const FabricConfig({this.capabilities = const []});

  /// Capabilities peers see in `agent_directory`.
  final List<AgentCapability> capabilities;

  /// Parses the `fabric:` section:
  ///
  /// ```yaml
  /// fabric:
  ///   capabilities:
  ///     - name: yoclip.render
  ///       description: Render the open project to MP4
  ///       payload: scene=<id>
  /// ```
  static FabricConfig fromYaml(Object? node) {
    if (node is! YamlMap) {
      throw ConfigException('fabric must be a map, got: $node');
    }
    for (final key in node.keys) {
      if (key != 'capabilities') {
        throw ConfigException('unknown "fabric" key: $key');
      }
    }
    final caps = node['capabilities'];
    if (caps == null) return const FabricConfig();
    if (caps is! YamlList) {
      throw ConfigException('fabric.capabilities must be a list, got: $caps');
    }
    final parsed = <AgentCapability>[];
    for (final entry in caps) {
      if (entry is! YamlMap) {
        throw ConfigException(
          'fabric.capabilities entries must be maps, got: $entry',
        );
      }
      for (final key in entry.keys) {
        if (key != 'name' && key != 'description' && key != 'payload') {
          throw ConfigException('unknown "fabric.capabilities" key: $key');
        }
      }
      final name = '${entry['name'] ?? ''}'.trim();
      if (name.isEmpty) {
        throw ConfigException(
          'fabric.capabilities entries need a non-empty "name"',
        );
      }
      parsed.add(
        AgentCapability(
          name: name,
          description: entry['description'] == null
              ? null
              : '${entry['description']}',
          payload: entry['payload'] == null ? null : '${entry['payload']}',
        ),
      );
    }
    return FabricConfig(capabilities: parsed);
  }

  /// The `fabric:` yaml fragment; only emitted when capabilities exist so
  /// default configs stay minimal.
  String toYaml() {
    if (capabilities.isEmpty) return '';
    final buffer = StringBuffer('fabric:\n  capabilities:\n');
    for (final capability in capabilities) {
      buffer
        ..write('    - name: ${capability.name}\n')
        ..write(
          '      description: ${capability.description ?? capability.name}\n',
        );
      if (capability.payload != null) {
        buffer.write('      payload: ${capability.payload}\n');
      }
    }
    return buffer.toString();
  }
}
