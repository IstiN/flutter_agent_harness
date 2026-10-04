/// The `output:` config section (gh-1198): console-output behavior flags.
/// Today only `streamThinking` — the opt-in live thinking stream for
/// line-mode/headless CLI runs (`output.streamThinking`, default false =
/// the byte-identical legacy output).
///
/// Pure Dart (no `dart:io`) so both the boot parser (`cli_config.dart`)
/// and the `config check`/`set` validators (`config_service.dart`) share
/// the SAME strict parser — no mirror to keep in sync.
library;

import 'package:yaml/yaml.dart';

import '../exceptions.dart';

/// The one `output:` key today.
const outputStreamThinkingKey = 'streamThinking';

/// Parses the `output:` section strictly: unknown keys and bad types
/// throw [ConfigException] (a typo must never silently keep the default).
void parseOutputSection(Object? node) {
  if (node == null) return;
  if (node is! YamlMap) {
    throw ConfigException('output must be a map, got: $node');
  }
  for (final key in node.keys) {
    if (key != outputStreamThinkingKey) {
      throw ConfigException('unknown "output" key: $key');
    }
    final value = node[key];
    if (value is! bool) {
      throw ConfigException(
        '"output.$outputStreamThinkingKey" must be a boolean',
      );
    }
  }
}

/// The `output.streamThinking` value of a parsed section: true only when
/// explicitly set (a validated section, absent = false).
bool outputStreamThinkingValue(Object? node) =>
    node is YamlMap && node[outputStreamThinkingKey] == true;
