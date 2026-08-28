/// `hub:` configuration section of `.fah/packages.yaml`, with environment
/// overrides `DAP_HUB_URL`, `DAP_KEY_PATH`, `DAP_AGENT_NAME` (env wins).
///
/// ```yaml
/// hub:
///   url: wss://hub.internal:8443/ws
///   keyPath: ~/.fah/hub-key
///   name: my-agent
///   channels:            # channel name -> X25519 pubkey b64 (encrypt-to)
///     general: Agh...
///   channelSecrets:      # channel name -> X25519 privkey b64 (decrypt-with)
///     general: GhI...
/// ```
library;

class HubConfig {
  const HubConfig({
    this.url,
    this.keyPath,
    this.name,
    this.channels = const {},
    this.channelSecrets = const {},
  });

  final String? url;
  final String? keyPath;
  final String? name;
  final Map<String, String> channels;
  final Map<String, String> channelSecrets;

  static const envUrl = 'DAP_HUB_URL';
  static const envKeyPath = 'DAP_KEY_PATH';
  static const envName = 'DAP_AGENT_NAME';

  /// Builds the config from an already-parsed `hub:` section map (as
  /// `PluginContext.config['hub']` provides upstream).
  factory HubConfig.fromMap(
    Map<String, dynamic> section, [
    Map<String, String> environment = const {},
  ]) {
    String? scalar(String key) => switch (section[key]) {
      String s => s,
      _ => null,
    };
    Map<String, String> stringMap(String key) =>
        (section[key] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, v is String ? v : v.toString()));
    return HubConfig(
      url: environment[envUrl] ?? scalar('url'),
      keyPath: environment[envKeyPath] ?? scalar('keyPath'),
      name: environment[envName] ?? scalar('name'),
      channels: stringMap('channels'),
      channelSecrets: stringMap('channelSecrets'),
    );
  }

  /// Extracts the `hub:` section from raw `.fah/packages.yaml` text and
  /// builds the config. See [parseYaml].
  factory HubConfig.fromYaml(
    String yaml, [
    Map<String, String> environment = const {},
  ]) {
    final section = parseYaml(yaml)['hub'];
    return HubConfig.fromMap(
      section is Map<String, dynamic> ? section : const {},
      environment,
    );
  }

  /// Parses the flat YAML subset this config needs: nested maps of scalar
  /// `key: value` pairs, indentation-based, `#` comments, optional single
  /// or double quotes around values.
  // ponytail: hand parser for the flat subset; swap for package:yaml if
  // arbitrary YAML ever needs to round-trip here
  static Map<String, dynamic> parseYaml(String yaml) {
    final root = <String, dynamic>{};
    final stack = <_YamlLevel>[_YamlLevel(0, root)];
    for (final raw in yaml.split('\n')) {
      final line = _stripComment(raw);
      if (line.trim().isEmpty) continue;
      final indent = line.length - line.trimLeft().length;
      final content = line.trim();
      final sep = content.indexOf(':');
      if (sep <= 0) continue;
      final key = content.substring(0, sep).trim();
      final value = _unquote(content.substring(sep + 1).trim());
      while (stack.length > 1 && indent <= stack.last.indent) {
        stack.removeLast();
      }
      final parent = stack.last.map;
      if (value.isEmpty) {
        final nested = <String, dynamic>{};
        parent[key] = nested;
        stack.add(_YamlLevel(indent, nested));
      } else {
        parent[key] = value;
      }
    }
    return root;
  }

  static String _stripComment(String line) {
    var inSingle = false;
    var inDouble = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == "'" && !inDouble) inSingle = !inSingle;
      if (ch == '"' && !inSingle) inDouble = !inDouble;
      if (ch == '#' && !inSingle && !inDouble && (i == 0 || line[i - 1] == ' ')) {
        return line.substring(0, i);
      }
    }
    return line;
  }

  static String _unquote(String value) {
    if (value.length >= 2 &&
        ((value.startsWith("'") && value.endsWith("'")) ||
            (value.startsWith('"') && value.endsWith('"')))) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }
}

class _YamlLevel {
  _YamlLevel(this.indent, this.map);

  final int indent;
  final Map<String, dynamic> map;
}
