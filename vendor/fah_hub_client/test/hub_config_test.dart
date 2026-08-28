import 'package:fah_hub_client/fah_hub_client.dart';
import 'package:test/test.dart';

const packagesYaml = '''
# .fah/packages.yaml
tools:
  something: else

hub:
  url: ws://127.0.0.1:8080/ws   # inline comment
  keyPath: /tmp/agent-key
  name: "quoted name"
  channels:
    general: Q2hhbm5lbFB1Yg==
    random: UkFuZG9tUHVi
  channelSecrets:
    general: Q2hhbm5lbFByaXY=
''';

void main() {
  test('parseYaml reads the hub: section with nesting and comments', () {
    final hub = HubConfig.parseYaml(packagesYaml)['hub'] as Map;
    expect(hub['url'], 'ws://127.0.0.1:8080/ws');
    expect(hub['keyPath'], '/tmp/agent-key');
    expect(hub['name'], 'quoted name');
    expect(hub['tools'], isNull); // sibling section not inside hub
    expect(
      HubConfig.parseYaml(packagesYaml).keys,
      containsAll(['tools', 'hub']),
    );
    expect((hub['channels'] as Map)['general'], 'Q2hhbm5lbFB1Yg==');
  });

  test('HubConfig.fromYaml builds channel maps', () {
    final config = HubConfig.fromYaml(packagesYaml);
    expect(config.url, 'ws://127.0.0.1:8080/ws');
    expect(config.name, 'quoted name');
    expect(config.channels['random'], 'UkFuZG9tUHVi');
    expect(config.channelSecrets['general'], 'Q2hhbm5lbFByaXY=');
  });

  test('environment overrides win: DAP_HUB_URL / DAP_KEY_PATH / DAP_AGENT_NAME',
      () {
    final config = HubConfig.fromYaml(packagesYaml, const {
      HubConfig.envUrl: 'ws://override:9/ws',
      HubConfig.envName: 'env-agent',
    });
    expect(config.url, 'ws://override:9/ws');
    expect(config.name, 'env-agent');
    expect(config.keyPath, '/tmp/agent-key'); // unchanged
  });

  test('HubConfig.fromMap reads PluginContext-shaped maps', () {
    final config = HubConfig.fromMap(const {
      'url': 'ws://h:1/ws',
      'keyPath': '/k',
    }, const {
      HubConfig.envKeyPath: '/env-key',
    });
    expect(config.url, 'ws://h:1/ws');
    expect(config.keyPath, '/env-key');
    expect(config.name, isNull);
  });

  test('missing hub section yields empty config', () {
    final config = HubConfig.fromYaml('other:\n  x: 1\n');
    expect(config.url, isNull);
    expect(config.channels, isEmpty);
  });
}
