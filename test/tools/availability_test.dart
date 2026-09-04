// Contract tests for capability-gated tool availability (issue #19).
//
// Covers the pure resolution layer: per-scope `tools:` intent parsing
// (yaml + CSV spec), shallow→deep merge precedence, and
// [resolveToolAvailability]'s capability/intent rules.
//
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

ToolsConfig _fromYamlDoc(String yaml) {
  final doc = loadYaml(yaml);
  return ToolsConfig.fromYaml((doc as YamlMap)['tools']);
}

/// A scope entry for [resolveToolAvailability], shallow→deep order.
(ToolScope, ToolsConfig) _scope(ToolScope scope, Map<String, bool> tools) =>
    (scope, ToolsConfig(tools: tools));

/// All-known tool ids marked available, for intent-only resolution tests.
Map<String, ToolCapability> get _allAvailable => {
  for (final id in knownToolIds) id: const ToolCapability.available(),
};

ToolAvailabilityResolution _resolve({
  Map<String, ToolCapability> capabilities = const {},
  List<(ToolScope, ToolsConfig)> scopes = const [],
}) {
  return resolveToolAvailability(capabilities: capabilities, scopes: scopes);
}

void main() {
  group('ToolsConfig.fromYaml', () {
    test('null yields an empty config', () {
      final config = ToolsConfig.fromYaml(null);
      expect(config.isEmpty, isTrue);
      expect(config.tools, isEmpty);
    });

    test('non-map node throws ConfigException', () {
      expect(
        () => ToolsConfig.fromYaml(loadYaml('- a\n- b')),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => ToolsConfig.fromYaml('nope'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('non-boolean value throws ConfigException naming the key', () {
      expect(
        () => _fromYamlDoc('tools:\n  web_search: yes-please\n'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            '"tools.web_search" must be a boolean',
          ),
        ),
      );
    });

    test('nested mcp map flattens to mcp:<server> keys', () {
      final config = _fromYamlDoc(
        'tools:\n'
        '  web_search: false\n'
        '  mcp:\n'
        '    my-server: false\n'
        '    other: true\n',
      );
      expect(config.tools, {
        'web_search': false,
        'mcp:my-server': false,
        'mcp:other': true,
      });
    });

    test('non-boolean mcp server value throws naming it', () {
      expect(
        () => _fromYamlDoc('tools:\n  mcp:\n    srv: 7\n'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            '"tools.mcp.srv" must be a boolean',
          ),
        ),
      );
    });

    test('non-string mcp server key throws', () {
      expect(
        () => ToolsConfig.fromJson(<String, dynamic>{
          'tools': <String, dynamic>{
            'mcp': <int, bool>{1: true},
          },
        }),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            '"tools.mcp" keys must be strings, got: int',
          ),
        ),
      );
    });

    test('unknown top-level ids are accepted at parse time', () {
      final config = _fromYamlDoc('tools:\n  not_a_real_tool: true\n');
      expect(config.tools, {'not_a_real_tool': true});
    });

    test('flat mcp boolean parses as the mcp id', () {
      final config = _fromYamlDoc('tools:\n  mcp: false\n');
      expect(config.tools, {'mcp': false});
    });

    test('non-string key throws ConfigException', () {
      expect(
        () => ToolsConfig.fromJson(<String, dynamic>{
          'tools': <int, bool>{1: true},
        }),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('ToolsConfig.mergedOver', () {
    test('receiver (deeper) wins per key', () {
      const global = ToolsConfig(tools: {'web_search': false, 'bash': true});
      const runtime = ToolsConfig(tools: {'web_search': true});
      final merged = runtime.mergedOver(global);
      expect(merged.tools, {'web_search': true, 'bash': true});
    });

    test('key absent at the deeper scope falls back to the shallower', () {
      const global = ToolsConfig(tools: {'web_search': false});
      const session = ToolsConfig(tools: {'ask': false});
      final merged = session.mergedOver(global);
      expect(merged.tools, {'web_search': false, 'ask': false});
      expect(merged.isEmpty, isFalse);
    });

    test('empty receiver keeps the shallower map intact', () {
      const global = ToolsConfig(tools: {'bash': false});
      final merged = const ToolsConfig().mergedOver(global);
      expect(merged.tools, {'bash': false});
    });
  });

  group('ToolsConfig.toYaml', () {
    test('empty config serializes to an empty string', () {
      expect(const ToolsConfig().toYaml(), '');
    });

    test('flat keys sort; nested mcp renders as an indented map', () {
      final config = _fromYamlDoc(
        'tools:\n'
        '  zeta: true\n'
        '  alpha: false\n'
        '  mcp:\n'
        '    zeta: false\n'
        '    alpha: true\n',
      );
      expect(
        config.toYaml(),
        'tools:\n'
        '  alpha: false\n'
        '  zeta: true\n'
        '  mcp:\n'
        '    alpha: true\n'
        '    zeta: false',
      );
    });

    test('round trip through yaml preserves the tool map', () {
      final config = _fromYamlDoc(
        'tools:\n'
        '  web_search: false\n'
        '  bash: true\n'
        '  mcp:\n'
        '    my-server: false\n',
      );
      final reparsed = _fromYamlDoc(config.toYaml());
      expect(reparsed.tools, config.tools);
    });
  });

  group('ToolsConfig JSON envelope', () {
    test('round trip preserves the tool map', () {
      const config = ToolsConfig(tools: {'web_search': false, 'mcp:x': true});
      final restored = ToolsConfig.fromJson(config.toJson());
      expect(restored.tools, config.tools);
    });

    test('non-map envelope throws ConfigException', () {
      expect(
        () => ToolsConfig.fromJson('corrupt'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('non-map tools section throws ConfigException', () {
      expect(
        () => ToolsConfig.fromJson({'tools': 'corrupt'}),
        throwsA(isA<ConfigException>()),
      );
    });

    test('non-boolean tool value throws ConfigException', () {
      expect(
        () => ToolsConfig.fromJson({
          'tools': {'web_search': 'off'},
        }),
        throwsA(isA<ConfigException>()),
      );
    });

    test('missing tools section yields an empty config', () {
      expect(ToolsConfig.fromJson(<String, dynamic>{}).isEmpty, isTrue);
    });
  });

  group('resolveToolAvailability', () {
    test('capability absent: force-enable cannot win', () {
      final resolution = _resolve(
        capabilities: {
          'web_search': const ToolCapability.absent(
            'no network sandbox on this platform',
          ),
        },
        scopes: [
          _scope(ToolScope.runtime, {'web_search': true}),
        ],
      );
      final resolved = resolution.byId['web_search']!;
      expect(resolved.enabled, isFalse);
      expect(resolved.scope, ToolScope.builtin);
      expect(resolved.capabilityPresent, isFalse);
      expect(resolved.reason, 'no network sandbox on this platform');
    });

    test('id without a capability entry is "not wired by this host"', () {
      final resolution = _resolve(
        capabilities: {'bash': const ToolCapability.available()},
      );
      expect(resolution.byId['bash']!.enabled, isTrue);
      final unwired = resolution.byId['generate_video']!;
      expect(unwired.enabled, isFalse);
      expect(unwired.capabilityPresent, isFalse);
      expect(unwired.reason, 'not wired by this host');
    });

    test('present capability, no intent: enabled at builtin scope', () {
      final resolution = _resolve(
        capabilities: {'bash': const ToolCapability.available()},
      );
      final resolved = resolution.byId['bash']!;
      expect(resolved.enabled, isTrue);
      expect(resolved.scope, ToolScope.builtin);
      expect(resolved.capabilityPresent, isTrue);
      expect(resolved.reason, isNull);
    });

    test('merge precedence global < project < session < runtime per key', () {
      final resolution = _resolve(
        capabilities: _allAvailable,
        scopes: [
          _scope(ToolScope.global, {'web_search': false, 'bash': false}),
          _scope(ToolScope.project, {'web_search': true}),
          _scope(ToolScope.session, {'web_search': false}),
          _scope(ToolScope.runtime, {'web_search': true}),
        ],
      );
      final search = resolution.byId['web_search']!;
      expect(search.enabled, isTrue);
      expect(search.scope, ToolScope.runtime);
      expect(search.reason, isNull);

      // Only mentioned at the shallowest scope: falls back there.
      final bash = resolution.byId['bash']!;
      expect(bash.enabled, isFalse);
      expect(bash.scope, ToolScope.global);
      expect(bash.reason, 'disabled by global');
    });

    test('deeper true overrides shallower false', () {
      final resolution = _resolve(
        capabilities: {'web_search': const ToolCapability.available()},
        scopes: [
          _scope(ToolScope.global, {'web_search': false}),
          _scope(ToolScope.project, {'web_search': true}),
        ],
      );
      final resolved = resolution.byId['web_search']!;
      expect(resolved.enabled, isTrue);
      expect(resolved.scope, ToolScope.project);
      expect(resolved.reason, isNull);
    });

    test('deepest false wins with scope and reason', () {
      final resolution = _resolve(
        capabilities: {'dap': const ToolCapability.available()},
        scopes: [
          _scope(ToolScope.global, {'dap': true}),
          _scope(ToolScope.session, {'dap': false}),
        ],
      );
      final resolved = resolution.byId['dap']!;
      expect(resolved.enabled, isFalse);
      expect(resolved.scope, ToolScope.session);
      expect(resolved.reason, 'disabled by session');
    });

    test('byId covers every known tool id', () {
      final resolution = _resolve(capabilities: _allAvailable);
      expect(resolution.byId.keys.toSet(), knownToolIds);
    });

    test('unknown config ids land in unknownIds without failing', () {
      final resolution = _resolve(
        capabilities: {'bash': const ToolCapability.available()},
        scopes: [
          _scope(ToolScope.global, {'bash': true}),
          _scope(ToolScope.runtime, {'bogus_tool': false}),
        ],
      );
      expect(resolution.unknownIds, {'bogus_tool'});
      expect(resolution.byId['bash']!.enabled, isTrue);
    });

    test('mcp:<server> keys never leak into unknownIds', () {
      final resolution = _resolve(
        scopes: [
          _scope(ToolScope.project, {'mcp:my-server': false}),
        ],
      );
      expect(resolution.unknownIds, isEmpty);
      expect(resolution.mcpServers, {'my-server': false});
    });

    test('per-server mcp keys merge across scopes, deepest wins', () {
      final resolution = _resolve(
        capabilities: {'mcp': const ToolCapability.available()},
        scopes: [
          _scope(ToolScope.global, {'mcp:alpha': false}),
          _scope(ToolScope.session, {'mcp:alpha': true, 'mcp:beta': false}),
        ],
      );
      expect(resolution.mcpServers, {'alpha': true, 'beta': false});
      expect(resolution.byId['mcp']!.enabled, isTrue);
    });

    test('mcp:false kill-switch forces every declared server off', () {
      final resolution = _resolve(
        capabilities: {'mcp': const ToolCapability.available()},
        scopes: [
          _scope(ToolScope.global, {'mcp:alpha': true}),
          _scope(ToolScope.runtime, {'mcp': false}),
        ],
      );
      expect(resolution.mcpServers, {'alpha': false});
      final mcp = resolution.byId['mcp']!;
      expect(mcp.enabled, isFalse);
      expect(mcp.reason, 'disabled by runtime');
    });
  });

  group('parseToolsSpec', () {
    test('parses ids, on/off values, and mcp:<server> keys', () {
      final config = parseToolsSpec('web_search=off,dap=off,mcp:my-server=on');
      expect(config.tools, {
        'web_search': false,
        'dap': false,
        'mcp:my-server': true,
      });
    });

    test('values are case-insensitive and tokens are trimmed', () {
      final config = parseToolsSpec(' bash = OFF , web_search = True ,');
      expect(config.tools, {'bash': false, 'web_search': true});
    });

    test('empty string yields an empty config', () {
      expect(parseToolsSpec('').isEmpty, isTrue);
      expect(parseToolsSpec('   ').isEmpty, isTrue);
    });

    test('malformed token throws ConfigException naming it', () {
      expect(
        () => parseToolsSpec('web_search=off,garbage'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('garbage'),
          ),
        ),
      );
    });

    test('unknown value throws ConfigException naming the token', () {
      expect(
        () => parseToolsSpec('web_search=maybe'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('web_search=maybe'),
          ),
        ),
      );
    });
  });
  group('coreToolFamilies', () {
    test('every member tool name appears in exactly ONE family', () {
      final owner = <String, String>{};
      coreToolFamilies.forEach((id, names) {
        for (final name in names) {
          expect(
            owner.containsKey(name),
            isFalse,
            reason: '$name assigned to both $id and ${owner[name]}',
          );
          owner[name] = id;
        }
      });
    });

    test('family ids stay inside knownToolIds; host-wired ids stay out', () {
      expect(coreToolFamilies.keys.toSet().difference(knownToolIds), isEmpty);
      expect(knownToolIds.difference(coreToolFamilies.keys.toSet()), {
        'lsp',
        'sqlite',
        'mcp',
        'dap',
      });
    });

    test('toolAvailabilityIdOf spot checks', () {
      expect(toolAvailabilityIdOf('web_fetch'), 'web_search');
      expect(toolAvailabilityIdOf('task_send'), 'task');
      expect(toolAvailabilityIdOf('read'), 'read');
      expect(toolAvailabilityIdOf('no_such_tool'), isNull);
    });
  });

  group('toolScopeStack', () {
    test('is shallow→deep without the builtin floor', () {
      expect(toolScopeStack, [
        ToolScope.global,
        ToolScope.project,
        ToolScope.session,
        ToolScope.runtime,
      ]);
    });
  });
}
