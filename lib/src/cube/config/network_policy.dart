/// Network egress policy for a cube (`spec.network:`): which host/port pairs
/// a sandboxed run may reach.
///
/// ```yaml
/// spec:
///   network:
///     allow:
///       - {host: "*.example.com", ports: [80, 443]}
///       - {host: api.github.com}
///     deny:
///       - {host: "*", ports: [22, 3389]}
/// ```
///
/// Host matching ([CubeNetworkRule]): exact (case-insensitive), or a single
/// leading-label wildcard — `*.example.com` matches the apex `example.com`
/// and any subdomain `a.example.com` / `a.b.example.com`, but never
/// `notexample.com`. IP literals only ever match exactly. `ports` null or
/// empty means any port.
///
/// Semantics: `deny` wins over `allow`; an empty `allow` denies all network
/// access ([CubeNetworkPolicy.allowsAnyNetwork] is then `false`).
///
/// Parsing is strict: any schema problem throws [ConfigException] naming the
/// YAML path.
library;

import 'package:yaml/yaml.dart';

import '../../exceptions.dart';

/// One network rule: a host pattern plus an optional port set.
final class CubeNetworkRule {
  /// Creates a rule; [ports] `null` or empty means "any port".
  const CubeNetworkRule({required this.host, this.ports});

  /// Host pattern: exact name, `*` for any host, or `*.domain` wildcard.
  final String host;

  /// Allowed ports; `null` or empty = any port.
  final Set<int>? ports;

  /// Whether [host] (lowercased, any port) matches this rule.
  bool matchesHost(String host) => _hostMatches(this.host, host);

  /// Whether this rule matches the host/port pair.
  bool matches(String host, int port) {
    if (!matchesHost(host)) return false;
    final ports = this.ports;
    return ports == null || ports.isEmpty || ports.contains(port);
  }

  static bool _hostMatches(String pattern, String host) {
    final p = pattern.toLowerCase();
    final h = host.toLowerCase();
    if (p == '*') return true;
    if (p.startsWith('*.')) {
      final base = p.substring(2);
      return h == base || h.endsWith('.$base');
    }
    return p == h; // IP literals and plain names: exact only
  }
}

/// The `spec.network:` section: ordered allow/deny rule lists.
final class CubeNetworkPolicy {
  /// Creates a policy; `allow` empty means "no network at all".
  const CubeNetworkPolicy({this.allow = const [], this.deny = const []});

  /// Allow rules; an empty list denies all network access.
  final List<CubeNetworkRule> allow;

  /// Deny rules; they win over [allow].
  final List<CubeNetworkRule> deny;

  /// Parses the `spec.network:` section. `null` (section absent) yields the
  /// safe default: deny all network access.
  factory CubeNetworkPolicy.fromYaml(Object? node) {
    if (node == null) return const CubeNetworkPolicy();
    if (node is! YamlMap) {
      throw ConfigException(
        'cube.spec.network: must be a map with optional "allow"/"deny", '
        'got ${node.runtimeType}',
      );
    }
    for (final key in node.keys) {
      if (key is! String || (key != 'allow' && key != 'deny')) {
        throw ConfigException(
          'cube.spec.network: unknown key "$key" — supported: allow, deny',
        );
      }
    }
    return CubeNetworkPolicy(
      allow: _parseRules(node['allow'], 'cube.spec.network.allow'),
      deny: _parseRules(node['deny'], 'cube.spec.network.deny'),
    );
  }

  /// Whether [host]:[port] may be reached: not denied and allowed by some
  /// rule. An empty `allow` always returns `false`.
  bool permits(String host, int port) {
    if (deny.any((rule) => rule.matches(host, port))) return false;
    if (allow.isEmpty) return false;
    return allow.any((rule) => rule.matches(host, port));
  }

  /// Whether any network destination is allowed at all.
  bool get allowsAnyNetwork => allow.isNotEmpty;

  static List<CubeNetworkRule> _parseRules(Object? node, String where) {
    if (node == null) return const [];
    if (node is! YamlList) {
      throw ConfigException('$where: must be a list of rules');
    }
    final rules = <CubeNetworkRule>[];
    for (final (index, entry) in node.indexed) {
      rules.add(_parseRule(entry, '$where[$index]'));
    }
    return List.unmodifiable(rules);
  }

  static CubeNetworkRule _parseRule(Object? node, String where) {
    // Shorthand: a bare string is a host with any port.
    if (node is String) {
      return CubeNetworkRule(host: _parseHostString(node, where));
    }
    if (node is! YamlMap) {
      throw ConfigException(
        '$where: must be a string host or a map with "host"',
      );
    }
    _checkRuleKeys(node, where);
    final host = node['host'];
    if (host is! String || host.trim().isEmpty) {
      throw ConfigException('$where.host: must be a non-empty string');
    }
    return CubeNetworkRule(
      host: host.trim(),
      ports: _parsePorts(node['ports'], where),
    );
  }

  /// Trims a shorthand bare-string host; empty is rejected.
  static String _parseHostString(String node, String where) {
    final host = node.trim();
    if (host.isEmpty) {
      throw ConfigException('$where: host must be a non-empty string');
    }
    return host;
  }

  /// Rejects keys outside the `{host, ports}` schema.
  static void _checkRuleKeys(YamlMap node, String where) {
    for (final key in node.keys) {
      if (key is! String || (key != 'host' && key != 'ports')) {
        throw ConfigException(
          '$where: unknown key "$key" — supported: host, ports',
        );
      }
    }
  }

  /// Parses the optional `ports:` list of integers; null means any port.
  static Set<int>? _parsePorts(Object? node, String where) {
    if (node == null) return null;
    if (node is! YamlList) {
      throw ConfigException('$where.ports: must be a list of integers');
    }
    return {
      for (final port in node)
        port is int
            ? port
            : throw ConfigException(
                '$where.ports: entries must be integers, got $port',
              ),
    };
  }
}
