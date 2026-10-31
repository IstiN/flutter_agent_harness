// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// UT coverage for the per-provider proxy config (issue #1921, AC1):
/// `network:` block parsing/validation, the route decision table, the
/// fail-closed error text, the password-env resolution, and the
/// `providers:` config section (parse + toYaml round-trip). Pure Dart —
/// no IO.
library;

import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/cli/cli_config.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:flutter_agent_harness/src/providers/proxy_connector.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

ProviderNetworkConfig parse(Object? node, {String label = 'network'}) =>
    ProviderNetworkConfig.fromYaml(node, configLabel: label);

Object? yamlOf(String text) => loadYaml(text);

void main() {
  group('ProviderNetworkConfig.fromYaml', () {
    test('accepts http/https/socks5 URLs with optional fields', () {
      for (final url in [
        'http://proxy.corp:3128',
        'https://proxy.corp:8443',
        'socks5://127.0.0.1:1080',
      ]) {
        final config = parse(
          yamlOf('proxy: $url\nproxyUsername: user\nproxyPasswordEnv: PW'),
        );
        expect(config.proxy.toString(), url);
        expect(config.proxyUsername, 'user');
        expect(config.proxyPasswordEnv, 'PW');
      }
    });

    test('rejects inline credentials in the URL (secrets by env only)', () {
      expect(
        () => parse(yamlOf('proxy: http://user:secret@proxy.corp:3128')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('inline proxy credentials are not allowed'),
          ),
        ),
      );
      // Even credentials-only userinfo (no password) is rejected.
      expect(
        () => parse(yamlOf('proxy: http://token@proxy.corp:3128')),
        throwsA(isA<ConfigException>()),
      );
    });

    test('rejects unknown fields', () {
      expect(
        () => parse(yamlOf('proxy: socks5://h:1080\nproxyTtl: 5')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('unknown key "proxyTtl"'),
          ),
        ),
      );
    });

    test('rejects unsupported schemes and empty proxies', () {
      expect(
        () => parse(yamlOf('proxy: ftp://h:21')),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => parse(yamlOf('proxy: socks4://h:1080')),
        throwsA(isA<ConfigException>()),
      );
      expect(() => parse(yamlOf('proxy: ""')), throwsA(isA<ConfigException>()));
      expect(
        () => parse(yamlOf('proxy: socks5://')),
        throwsA(isA<ConfigException>()),
      );
    });

    test('rejects non-map nodes and bad scalar fields', () {
      expect(() => parse('nope'), throwsA(isA<ConfigException>()));
      expect(
        () => parse(yamlOf('proxy: h\nproxyUsername: 42')),
        throwsA(isA<ConfigException>()),
      );
    });

    test('proxyUsername without proxyPasswordEnv is rejected', () {
      expect(
        () => parse(yamlOf('proxy: http://h:3128\nproxyUsername: user')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('proxyPasswordEnv'),
          ),
        ),
      );
    });

    test('error text carries the owning provider label', () {
      expect(
        () =>
            parse(yamlOf('proxy: ftp://h'), label: 'providers.kimi_me.network'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            startsWith('providers.kimi_me.network'),
          ),
        ),
      );
    });
  });

  group('port range', () {
    test('out-of-range port is rejected with a named config error', () {
      expect(
        () => parse(yamlOf('proxy: http://proxy.corp:99999')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('proxy port 99999 out of range 1..65535'),
          ),
        ),
      );
    });
  });

  group('credential half-validation', () {
    test('proxyUsername without proxyPasswordEnv is rejected', () {
      expect(
        () => parse(yamlOf('proxy: socks5://h:1080\nproxyUsername: kimi')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('"proxyUsername" without "proxyPasswordEnv"'),
          ),
        ),
      );
    });

    test(
      'proxyPasswordEnv without proxyUsername is rejected (dead config)',
      () {
        expect(
          () => parse(
            yamlOf('proxy: socks5://h:1080\nproxyPasswordEnv: KIMI_PW'),
          ),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('"proxyPasswordEnv" without "proxyUsername"'),
                contains('set proxyUsername next to proxyPasswordEnv'),
              ),
            ),
          ),
        );
      },
    );
  });

  group('proxyPasswordEnv resolution', () {
    test('resolves via the lookup when set', () {
      final config = parse(
        yamlOf(
          'proxy: socks5://h:1080\n'
          'proxyUsername: kimi\n'
          'proxyPasswordEnv: KIMI_PW',
        ),
      );
      expect(config.resolvePasswordVia((name) => 's3cret'), 's3cret');
    });

    test('null when no env name configured', () {
      final config = parse(yamlOf('proxy: socks5://h:1080'));
      expect(config.resolvePasswordVia((_) => 'ignored'), isNull);
    });

    test(
      'missing env → actionable error naming proxyPasswordEnv + request_secret',
      () {
        final config = parse(
          yamlOf(
            'proxy: socks5://h:1080\n'
            'proxyUsername: kimi\n'
            'proxyPasswordEnv: KIMI_PW',
          ),
          label: 'providers.kimi_me.network',
        );
        expect(
          () => config.resolvePasswordVia((_) => null),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('KIMI_PW'),
                contains('proxyPasswordEnv'),
                contains('request_secret'),
                contains('fail-closed'),
              ),
            ),
          ),
        );
      },
    );
  });

  group('proxyRoute decision table', () {
    test('explicit ports win', () {
      final route = proxyRoute(parse(yamlOf('proxy: http://proxy.corp:3128')));
      expect(route, (host: 'proxy.corp', port: 3128));
    });

    test('default ports: http 80, https 443, socks5 1080', () {
      expect(proxyRoute(parse(yamlOf('proxy: http://p'))), (
        host: 'p',
        port: 80,
      ));
      expect(proxyRoute(parse(yamlOf('proxy: https://p'))), (
        host: 'p',
        port: 443,
      ));
      expect(proxyRoute(parse(yamlOf('proxy: socks5://p'))), (
        host: 'p',
        port: 1080,
      ));
    });

    test('IPv6 literal host keeps its address (brackets re-added by io)', () {
      final route = proxyRoute(parse(yamlOf('proxy: socks5://[::1]:1080')));
      expect(route.host, '::1');
      expect(route.port, 1080);
    });
  });

  group('fail-closed error text', () {
    test('proxyFailureText carries the card contract', () {
      final text = proxyFailureText('kimi_me', 'connection refused');
      expect(
        text,
        "Proxy for provider 'kimi_me' failed: connection refused. Direct "
        'egress is disabled (fail-closed). Check network.proxy / '
        'proxyPasswordEnv.',
      );
    });

    test('proxyReasonOf collapses multi-line socket errors to one line', () {
      final reason = proxyReasonOf(Exception('line1\nline2'));
      expect(reason, contains('line1 line2'));
      expect(reason, isNot(contains('\n')));
    });
  });

  group('providers: config section', () {
    test('parses blocks keyed by provider name', () {
      final config = CliConfig.fromYaml(
        loadYaml(
              'providers:\n'
              '  kimi_me:\n'
              '    network:\n'
              '      proxy: socks5://127.0.0.1:1080\n'
              '      proxyUsername: user\n'
              '      proxyPasswordEnv: KIMI_PROXY_PASSWORD\n',
            )
            as YamlMap,
      );
      final network = config.providerNetworks['kimi_me'];
      expect(network, isNotNull);
      expect(network!.proxy.scheme, 'socks5');
      expect(network.proxyUsername, 'user');
      expect(network.proxyPasswordEnv, 'KIMI_PROXY_PASSWORD');
      expect(config.providerNetworks.length, 1);
    });

    test('a null-valued entry is rejected, not silently dropped', () {
      expect(
        () =>
            CliConfig.fromYaml(loadYaml('providers:\n  kimi_me:\n') as YamlMap),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('providers.kimi_me has no value'),
              contains('or remove the entry'),
            ),
          ),
        ),
      );
    });

    test('absent section parses to an empty map', () {
      final config = CliConfig.fromYaml(loadYaml('mode: code\n') as YamlMap);
      expect(config.providerNetworks, isEmpty);
    });

    test('rejects unknown per-provider keys', () {
      expect(
        () => CliConfig.fromYaml(
          loadYaml('providers:\n  kimi_me:\n    timeout: 5\n') as YamlMap,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('providers.kimi_me'),
          ),
        ),
      );
    });

    test('rejects non-map sections and entries', () {
      expect(
        () => CliConfig.fromYaml(loadYaml('providers: [a, b]\n') as YamlMap),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => CliConfig.fromYaml(
          loadYaml('providers:\n  kimi_me: socks5://h:1080\n') as YamlMap,
        ),
        throwsA(isA<ConfigException>()),
      );
    });

    test('toYaml writes the section back verbatim (config edits never '
        'drop the binding)', () {
      final config = CliConfig.fromYaml(
        loadYaml(
              'providers:\n'
              '  kimi_me:\n'
              '    network:\n'
              '      proxy: socks5://127.0.0.1:1080\n'
              '      proxyUsername: user\n'
              '      proxyPasswordEnv: KIMI_PROXY_PASSWORD\n',
            )
            as YamlMap,
      );
      final rewritten = config.toYaml();
      expect(rewritten, contains('providers:'));
      final reparsed = CliConfig.fromYaml(loadYaml(rewritten) as YamlMap);
      expect(reparsed.providerNetworks.length, 1);
      final network = reparsed.providerNetworks['kimi_me']!;
      expect(network.proxy.toString(), 'socks5://127.0.0.1:1080');
      expect(network.proxyUsername, 'user');
      expect(network.proxyPasswordEnv, 'KIMI_PROXY_PASSWORD');
    });

    test('toYaml omits the section entirely when unbound', () {
      final rewritten = CliConfig().toYaml();
      expect(rewritten, isNot(contains('providers:')));
    });
  });
}
