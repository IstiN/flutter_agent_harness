/// The strict `.fah/bootstrap.yaml` extensions section and its idempotent
/// apply loop.
///
/// Config shape (only the `extensions` top key; entries only `source`+`pin`;
/// any violation throws [ConfigException] naming the offending key):
///
/// ```yaml
/// extensions:
///   - source: gh:owner/repo
///     pin: <sha256>
///   - source: catalog:crap-guard
///   - source: /abs/or/rel/path
/// ```
///
/// [applyExtBootstrap] runs every entry through the caller's planner and
/// [applyInstall]: same-hash installs report up-to-date, drift reports one
/// summary line, and failures are NAMED but non-fatal (the session proceeds,
/// E15) unless [applyExtBootstrap] `strict` rethrows.
library;

import 'package:yaml/yaml.dart' as yaml;

import '../exceptions.dart';
import 'ext_install.dart';
import 'extension_store.dart';
import 'trust.dart';

/// One `extensions:` entry of the bootstrap config.
final class ExtBootstrapEntry {
  /// Source string (`gh:owner/repo`, `catalog:<id>`, or a path).
  final String source;

  /// Optional pinned content hash; mismatch rejects the install loudly.
  final String? pin;

  /// Creates an entry.
  const ExtBootstrapEntry({required this.source, this.pin});
}

/// The parsed `extensions:` section of `.fah/bootstrap.yaml`.
final class ExtBootstrapConfig {
  /// Entries in file order.
  final List<ExtBootstrapEntry> extensions;

  /// Creates a config.
  const ExtBootstrapConfig({required this.extensions});

  /// STRICT parse of the yaml text: only the `extensions` top key is known,
  /// entries accept only `source`+`pin`, and every violation throws
  /// [ConfigException] naming the key.
  factory ExtBootstrapConfig.fromYaml(String source) {
    final Object? doc;
    try {
      doc = yaml.loadYaml(source);
    } on Object catch (error) {
      throw ConfigException('failed to parse bootstrap.yaml: $error');
    }
    if (doc == null) return const ExtBootstrapConfig(extensions: []);
    if (doc is! yaml.YamlMap) {
      throw ConfigException('bootstrap.yaml must be a mapping');
    }
    final map = {
      for (final entry in doc.entries) '${entry.key}': _plain(entry.value),
    };
    for (final key in map.keys) {
      if (key != 'extensions') {
        throw ConfigException('unknown bootstrap.yaml key: $key');
      }
    }
    final rawList = map['extensions'];
    if (rawList == null) return const ExtBootstrapConfig(extensions: []);
    if (rawList is! List) {
      throw ConfigException('bootstrap.yaml "extensions" must be a list');
    }
    final entries = <ExtBootstrapEntry>[];
    for (final raw in rawList) {
      if (raw is! Map) {
        throw ConfigException(
          'bootstrap.yaml extensions entries must be mappings',
        );
      }
      String? sourceName;
      String? pin;
      for (final field in raw.entries) {
        final key = '${field.key}';
        switch (key) {
          case 'source':
            if (field.value is! String) {
              throw ConfigException('"extensions.source" must be a string');
            }
            sourceName = field.value as String;
          case 'pin':
            if (field.value is! String) {
              throw ConfigException('"extensions.pin" must be a string');
            }
            pin = field.value as String;
          default:
            throw ConfigException('unknown bootstrap.yaml extension key: $key');
        }
      }
      if (sourceName == null || sourceName.isEmpty) {
        throw ConfigException(
          'bootstrap.yaml extensions entry missing "source"',
        );
      }
      entries.add(ExtBootstrapEntry(source: sourceName, pin: pin));
    }
    return ExtBootstrapConfig(extensions: entries);
  }
}

/// Resolves one config entry into a plan; `null` => the entry does not apply
/// (planner-level skip). Throwing names the failure (E15 reports it).
typedef ExtBootstrapPlanner =
    Future<ExtInstallPlan?> Function(ExtBootstrapEntry entry);

/// Applies every entry idempotently, returning one summary line per entry:
///
/// - `ext <name> installed` — first grant (or first trusted install);
/// - `ext <name> updated (hash changed)` — content drift re-granted;
/// - `ext <name> up-to-date` — installed at the same hash, nothing done;
/// - `ext <src> FAILED: <err> (skipped)` — planner/apply failure or a denied
///   trust decision; the session proceeds (E15) unless [strict], which
///   rethrows instead.
Future<List<String>> applyExtBootstrap({
  required ExtBootstrapConfig config,
  required ExtensionStore store,
  required ExtBootstrapPlanner planner,
  ExtTrustPrompt? prompt,
  bool strict = false,
}) async {
  final lines = <String>[];
  for (final entry in config.extensions) {
    try {
      final plan = await planner(entry);
      if (plan == null) {
        lines.add('ext ${entry.source} skipped');
        continue;
      }
      final hadHash = (await store.find(plan.name))?.trust?.contentSha256;
      final outcome = await applyInstall(
        plan,
        store,
        prompt: prompt,
        pinSha256: entry.pin,
      );
      if (outcome.installed) {
        lines.add(
          hadHash == null
              ? 'ext ${plan.name} installed'
              : 'ext ${plan.name} updated (hash changed)',
        );
      } else if (outcome.reason == 'up-to-date') {
        lines.add('ext ${plan.name} up-to-date');
      } else {
        lines.add('ext ${entry.source} FAILED: ${outcome.reason} (skipped)');
      }
    } on Object catch (error) {
      if (strict) rethrow;
      lines.add('ext ${entry.source} FAILED: $error (skipped)');
    }
  }
  return lines;
}

/// Converts a parsed yaml node into plain Dart values, recursively (same
/// shape as `packages_config.dart`: yaml 3.x reifies dynamic-keyed maps, and
/// nested YamlMap/YamlScalar wrappers fail `is Map<String, dynamic>` checks).
Object? _plain(Object? node) => switch (node) {
  yaml.YamlMap() => {
    for (final entry in node.entries) entry.key.toString(): _plain(entry.value),
  },
  yaml.YamlList() => [for (final item in node) _plain(item)],
  yaml.YamlScalar() => node.value,
  _ => node,
};
