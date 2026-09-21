/// The `links:` config section (issue #691): the single source of truth
/// for product/store links. Every consumer — the app's Get banners, the
/// CLI (`fa config get links.…`), and the fa1.dev site generator —
/// resolves the SAME value from this section, so a link changes in one
/// place and propagates everywhere.
///
/// Parse contract (owner requirement): strict on bad shape — a non-map
/// section or a mistyped known value throws [ConfigException]; tolerant
/// notes for unknown keys — a future key (`docs`, `socials`, …) is noted
/// and ignored, never a boot failure (AC7).
library;

import 'package:yaml/yaml.dart';

import '../exceptions.dart';

/// Baked-in defaults for our own products; user-overridable like any
/// config key.
const defaultAppStoreUrl =
    'https://apps.apple.com/us/app/fa-ai-agent/id6793815163';
const defaultTestFlightUrl = 'https://testflight.apple.com/join/En1eC9UK';
const defaultSiteUrl = 'https://fa1.dev';

/// The `links:` config section.
final class LinksConfig {
  /// Creates a configuration; see each field for its default.
  const LinksConfig({
    this.appstore = defaultAppStoreUrl,
    this.testflight = defaultTestFlightUrl,
    this.play,
    this.site = defaultSiteUrl,
    this.banner = true,
    this.notes = const [],
  });

  /// The App Store release (paid).
  final String appstore;

  /// The public TestFlight beta (free forever).
  final String testflight;

  /// The Google Play release; null until live — surfaces render the
  /// Android slot as "coming soon" while unset.
  final String? play;

  /// The product site.
  final String site;

  /// Master switch for the in-app App Store banner (AC7): `false` = no
  /// banner mounts anywhere, byte-identical legacy UI.
  final bool banner;

  /// Tolerant-parse notes (unknown keys) surfaced at boot / by `fa links`
  /// consumers.
  final List<String> notes;

  /// Whether the section's VALUES are byte-equivalent to the defaults
  /// (the save then omits it — defaults are never written, the file stays
  /// minimal, and an on-disk block with future keys survives via the
  /// disk-preserved set). Notes do not count: a future key noted but no
  /// value overridden is still "default".
  bool get isDefault =>
      appstore == defaultAppStoreUrl &&
      testflight == defaultTestFlightUrl &&
      play == null &&
      site == defaultSiteUrl &&
      banner;

  /// Parses the `links:` yaml section. Strict on bad shape: a non-map
  /// section, a non-string link value, or an empty link throws
  /// [ConfigException]. Unknown keys are noted and ignored (AC7).
  factory LinksConfig.fromYaml(Object? node) {
    if (node == null) return const LinksConfig();
    if (node is! YamlMap) {
      throw ConfigException(
        '"links" must be a map of product links, got: $node',
      );
    }
    final notes = <String>[];
    String appstore = defaultAppStoreUrl;
    String testflight = defaultTestFlightUrl;
    String? play;
    String site = defaultSiteUrl;
    bool banner = true;
    node.forEach((key, value) {
      switch ('$key') {
        case 'appstore':
          appstore = _link('$key', value);
        case 'testflight':
          testflight = _link('$key', value);
        case 'play':
          play = value == null ? null : _link('$key', value);
        case 'site':
          site = _link('$key', value);
        case 'banner':
          if (value is! bool) {
            throw ConfigException('"links.banner" must be a boolean');
          }
          banner = value;
        default:
          notes.add('links.$key: unknown key (ignored)');
      }
    });
    return LinksConfig(
      appstore: appstore,
      testflight: testflight,
      play: play,
      site: site,
      banner: banner,
      notes: List.unmodifiable(notes),
    );
  }

  /// Known link keys must be non-empty http(s) URLs.
  static String _link(String key, Object? value) {
    if (value is! String || value.trim().isEmpty) {
      throw ConfigException('"links.$key" must be a non-empty URL string');
    }
    if (!value.startsWith('https://') && !value.startsWith('http://')) {
      throw ConfigException('"links.$key" must be an http(s) URL, got: $value');
    }
    return value.trim();
  }

  /// Renders the section, only the non-default keys (defaults are never
  /// written — the file stays minimal).
  String toYaml() {
    final buffer = StringBuffer('links:\n');
    // URLs are double-quoted: a value like "https://ex/app #frag" (space
    // before the fragment) parses back truncated if written bare — the
    // quote keeps the strict round-trip safe for every accepted value.
    if (appstore != defaultAppStoreUrl) {
      buffer.write('  appstore: "$appstore"\n');
    }
    if (testflight != defaultTestFlightUrl) {
      buffer.write('  testflight: "$testflight"\n');
    }
    if (play != null) buffer.write('  play: "$play"\n');
    if (site != defaultSiteUrl) buffer.write('  site: "$site"\n');
    if (!banner) buffer.write('  banner: false\n');
    return buffer.toString();
  }
}
