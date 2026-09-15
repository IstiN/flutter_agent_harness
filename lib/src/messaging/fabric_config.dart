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
  const FabricConfig({this.capabilities = const [], this.hub = true});

  /// Capabilities peers see in `agent_directory`.
  final List<AgentCapability> capabilities;

  /// Kill switch for the hub-backed fabric layer (issue #304 E6,
  /// `fabric.hub: false` — mirrors `images.registry: false`): when off,
  /// the CLI wires NO hub primary into the messaging fabric even with
  /// the hub plugin enabled and `DAP_MASTER_SECRET` set — the fabric is
  /// the bare file layer and `agent_directory` reproduces the legacy
  /// listing byte-for-byte.
  final bool hub;

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
      if (key != 'capabilities' && key != 'hub') {
        throw ConfigException('unknown "fabric" key: $key');
      }
    }
    final rawHub = node['hub'];
    if (rawHub != null && rawHub is! bool) {
      throw ConfigException('"fabric.hub" must be a boolean');
    }
    final caps = node['capabilities'];
    if (caps == null) {
      // Canonical const instances keep identity equality with
      // `const FabricConfig()` (the pinned default-config expectation).
      return rawHub == false
          ? const FabricConfig(hub: false)
          : const FabricConfig();
    }
    if (caps is! YamlList) {
      throw ConfigException('fabric.capabilities must be a list, got: $caps');
    }
    return FabricConfig(
      capabilities: [for (final entry in caps) _parseCapability(entry)],
      hub: rawHub ?? true,
    );
  }

  /// Parses one `fabric.capabilities` entry.
  static AgentCapability _parseCapability(Object? entry) {
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
    return AgentCapability(
      name: name,
      description: entry['description'] == null
          ? null
          : '${entry['description']}',
      payload: entry['payload'] == null ? null : '${entry['payload']}',
    );
  }

  /// The `fabric:` yaml fragment; only emitted when something deviates
  /// from the defaults (capabilities exist or the hub layer is off) so
  /// default configs stay minimal.
  String toYaml() {
    if (capabilities.isEmpty && hub) return '';
    final buffer = StringBuffer('fabric:\n');
    if (!hub) buffer.write('  hub: false\n');
    if (capabilities.isEmpty) return buffer.toString();
    buffer.write('  capabilities:\n');
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
