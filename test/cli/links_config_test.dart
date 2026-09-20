/// The `links:` config section (issue #691) — the single source of truth
/// for product/store links. These tests pin the parse contract (AC1):
/// strict on bad shape (ConfigException), defaults baked in, overrides
/// work, unknown keys become notes (AC7), and the section round-trips
/// through `toYaml` with defaults never written. The one-change
/// propagation pin (AC1) lives here too: flip the link in the config →
/// every surface (site block renderer, in-app banner view) renders the
/// new URL.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Parses [text] and hands back its `links:` NODE (the section, not the
/// whole document — mirroring how `CliConfig.fromYaml` sees it).
Object? _section(String text) => loadYaml(text)['links'];

void main() {
  group('defaults', () {
    test('the baked-in product links are present', () {
      const links = LinksConfig();
      expect(links.appstore, defaultAppStoreUrl);
      expect(
        links.appstore,
        'https://apps.apple.com/us/app/fa-ai-agent/id6793815163',
      );
      expect(links.testflight, defaultTestFlightUrl);
      expect(links.testflight, 'https://testflight.apple.com/join/En1eC9UK');
      expect(links.play, isNull);
      expect(links.site, defaultSiteUrl);
      expect(links.site, 'https://fa1.dev');
      expect(links.banner, isTrue);
      expect(links.notes, isEmpty);
      expect(links.isDefault, isTrue);
    });

    test('a null section parses to the defaults', () {
      expect(LinksConfig.fromYaml(null).isDefault, isTrue);
    });
  });

  group('strict parse', () {
    test('a non-map section throws ConfigException', () {
      expect(
        () => LinksConfig.fromYaml(_section('links: 42')),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => LinksConfig.fromYaml(_section('links: [a, b]')),
        throwsA(isA<ConfigException>()),
      );
    });

    test('a non-string link value throws', () {
      expect(
        () => LinksConfig.fromYaml(_section('links:\n  appstore: 42')),
        throwsA(isA<ConfigException>()),
      );
    });

    test('an empty link value throws', () {
      expect(
        () => LinksConfig.fromYaml(_section('links:\n  site: ""')),
        throwsA(isA<ConfigException>()),
      );
    });

    test('a non-http(s) link value throws', () {
      expect(
        () => LinksConfig.fromYaml(_section('links:\n  appstore: banana')),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => LinksConfig.fromYaml(
          _section('links:\n  play: ftp://example.com/apk'),
        ),
        throwsA(isA<ConfigException>()),
      );
    });

    test('a non-boolean banner throws', () {
      expect(
        () => LinksConfig.fromYaml(_section('links:\n  banner: "no"')),
        throwsA(isA<ConfigException>()),
      );
    });

    test('a bad section fails the whole CliConfig parse (boot-strict)', () {
      expect(
        () => CliConfig.fromYaml(
          loadYaml(
                'provider: openai-completions\n'
                'links:\n'
                '  appstore: not-a-url\n',
              )
              as YamlMap,
        ),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('tolerant parse', () {
    test('unknown keys become notes, never errors (AC7)', () {
      final links = LinksConfig.fromYaml(
        _section('links:\n  docs: https://fa1.dev/docs\n  socials: mastodon\n'),
      );
      expect(links.appstore, defaultAppStoreUrl);
      expect(links.notes, hasLength(2));
      expect(links.notes.first, contains('links.docs'));
      expect(links.notes.any((n) => n.contains('links.socials')), isTrue);
    });

    test('explicit null play stays unset', () {
      final links = LinksConfig.fromYaml(_section('links:\n  play:'));
      expect(links.play, isNull);
      expect(links.isDefault, isTrue);
    });

    test('banner: false parses and un-defaults the section', () {
      final links = LinksConfig.fromYaml(_section('links:\n  banner: false'));
      expect(links.banner, isFalse);
      expect(links.isDefault, isFalse);
    });
  });

  group('override', () {
    test('every known key overrides its default', () {
      final links = LinksConfig.fromYaml(
        _section(
          'links:\n'
          '  appstore: https://apps.apple.com/us/app/fa/id1\n'
          '  testflight: https://testflight.apple.com/join/XX\n'
          '  play: https://play.google.com/store/apps/details?id=dev.fa1.app\n'
          '  site: https://example.com\n',
        ),
      );
      expect(links.appstore, 'https://apps.apple.com/us/app/fa/id1');
      expect(links.testflight, 'https://testflight.apple.com/join/XX');
      expect(
        links.play,
        'https://play.google.com/store/apps/details?id=dev.fa1.app',
      );
      expect(links.site, 'https://example.com');
    });

    test('CliConfig.fromYaml carries the section through', () {
      final config = CliConfig.fromYaml(
        loadYaml('links:\n  appstore: https://apps.apple.com/us/app/fa/id2\n')
            as YamlMap,
      );
      expect(config.links.appstore, 'https://apps.apple.com/us/app/fa/id2');
      expect(config.links.testflight, defaultTestFlightUrl);
    });

    test('CliConfig defaults to the baked-in section when absent', () {
      final config = CliConfig.fromYaml(
        loadYaml('provider: openai-completions') as YamlMap,
      );
      expect(config.links.isDefault, isTrue);
    });
  });

  group('toYaml round-trip', () {
    test('defaults are never written (file stays minimal)', () {
      expect(const LinksConfig().toYaml(), 'links:\n');
    });

    test('only the overridden keys are written', () {
      final links = LinksConfig.fromYaml(
        _section(
          'links:\n'
          '  appstore: https://apps.apple.com/us/app/fa/id3\n'
          '  banner: false\n',
        ),
      );
      expect(
        links.toYaml(),
        'links:\n'
        '  appstore: "https://apps.apple.com/us/app/fa/id3"\n'
        '  banner: false\n',
      );
    });

    test('a written section parses back to the same values', () {
      final original = LinksConfig.fromYaml(
        _section(
          'links:\n'
          '  appstore: https://apps.apple.com/us/app/fa/id4\n'
          '  play: https://play.google.com/store/apps/details?id=dev.fa1.app\n'
          '  site: https://example.org\n'
          '  banner: false\n',
        ),
      );
      final roundTripped = LinksConfig.fromYaml(
        loadYaml(original.toYaml())['links'],
      );
      expect(roundTripped.appstore, original.appstore);
      expect(roundTripped.testflight, original.testflight);
      expect(roundTripped.play, original.play);
      expect(roundTripped.site, original.site);
      expect(roundTripped.banner, original.banner);
      expect(roundTripped.isDefault, isFalse);
    });

    test('a URL with a space-before-fragment survives the round-trip', () {
      // Written quoted (a bare ` #` starts a YAML comment — the file
      // author must quote it too); toYaml must then re-emit it quoted so
      // the strict round-trip parses back the same string.
      const url = 'https://ex.com/app #frag';
      final links = LinksConfig.fromYaml(
        _section('links:\n  appstore: "$url"\n'),
      );
      expect(links.appstore, url);
      final roundTripped = LinksConfig.fromYaml(
        loadYaml(links.toYaml())['links'],
      );
      expect(roundTripped.appstore, url);
    });
  });

  group('one-change propagation (AC1)', () {
    const flipped = LinksConfig(
      appstore: 'https://apps.apple.com/us/app/fa/id999',
      testflight: 'https://testflight.apple.com/join/ZZ',
      play: 'https://play.google.com/store/apps/details?id=dev.fa1.app',
      site: 'https://flip.example',
    );

    test('the site App Store block renders the flipped links', () {
      final html = renderAppStoreBlockHtml(flipped);
      expect(html, contains('href="https://apps.apple.com/us/app/fa/id999"'));
      expect(html, contains('href="https://testflight.apple.com/join/ZZ"'));
      expect(
        html,
        contains(
          'href="https://play.google.com/store/apps/details?id=dev.fa1.app"',
        ),
      );
      expect(html, contains('Get it on Google Play'));
      expect(html, isNot(contains('coming soon')));
    });

    test('the in-app banner view renders the flipped links', () {
      final view = StoreBannerView.from(flipped);
      expect(view.appstoreUrl, 'https://apps.apple.com/us/app/fa/id999');
      expect(view.testflightUrl, 'https://testflight.apple.com/join/ZZ');
      expect(view.androidLabel, 'Also on Google Play');
    });

    test('the default block keeps the coming-soon Android slot (AC2)', () {
      final html = renderAppStoreBlockHtml(const LinksConfig());
      expect(html, contains(defaultAppStoreUrl));
      expect(html, contains('coming soon'));
      expect(html, isNot(contains('Get it on Google Play')));
      expect(
        StoreBannerView.from(const LinksConfig()).androidLabel,
        'Android: coming soon',
      );
    });
  });

  group('store copy compliance (AC6, issue #643 list)', () {
    final compound = RegExp(r'[A-Za-zА-Яа-яЁё0-9]+(?:-[A-Za-zА-Яа-яЁё0-9]+)+');
    final banned = RegExp(
      '(?<![A-Za-zА-Яа-яЁё0-9])(first|best|top|leading|most|#1|№1|'
      'первый|лучший|самый)(?![A-Za-zА-Яа-яЁё0-9])',
      caseSensitive: false,
    );

    test('no superlative claims on the rendered site block', () {
      expect(
        banned.allMatches(
          renderAppStoreBlockHtml(
            const LinksConfig(),
          ).replaceAll(compound, ' '),
        ),
        isEmpty,
      );
    });
  });
}
