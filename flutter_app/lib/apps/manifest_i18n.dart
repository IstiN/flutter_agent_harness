// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/app_log.dart';

/// Localized manifest text — backward-compatible i18n for the widget
/// manifest `name`/`description` fields.
///
/// JSR-COMPATIBILITY RULE (hard constraint): the JSR runtime parses
/// manifests with strict casts (`raw['name'] as String?`); changing the
/// TYPE of an existing key makes the whole manifest fall back to
/// defaults (folder-name title, wrench icon, network=true). i18n is
/// therefore purely ADDITIVE — the legacy keys stay scalar strings and
/// localization lives in two new keys the JSR core ignores as unknown:
///
/// ```jsonc
/// {
///   // Legacy scalar — unchanged; this is the default-locale value:
///   "name": "Calculator",
///   "description": "A calculator.",
///
///   // NEW: per-locale overrides. Each locale maps to either an inline
///   // string or a {"file": ...} reference to a text file inside the
///   // widget package (existence is validated at install; content is
///   // read at display-listing time):
///   "nameI18n": { "ru": "Калькулятор" },
///   "descriptionI18n": {
///     "en": "A calculator.",
///     "ru": { "file": "./i18n/description.ru.md" }
///   }
/// }
/// ```
///
/// Resolution order for a device locale: exact tag (`pt-BR`) → language
/// only (`pt`) → `en` entry → the scalar (default-locale) value → first
/// declared entry. Ref entries whose content was not loaded fall through
/// to the next candidate.
///
/// Parsing here is deliberately LENIENT (never throws): malformed locale
/// keys, non-string values and unsafe ref paths are skipped with a log
/// note, because the host must keep rendering third-party widgets. The
/// strict side lives in the fa_widgets validator / the install-time
/// ref-existence check — unknown keys elsewhere in the manifest schema
/// keep their existing rejection/warning behavior.
class LocalizedText {
  const LocalizedText._(
    this.fallback,
    this.inline,
    this.refs,
    this.contents,
  );

  /// Parses a manifest value pair: the legacy [scalar] (default-locale
  /// fallback) plus the additive [i18n] locale map (`nameI18n` /
  /// `descriptionI18n`). A non-String [scalar] is ignored — notably a
  /// Map under the legacy key is NOT treated as localization, because
  /// that type change is exactly what the JSR runtime cannot tolerate.
  factory LocalizedText.parse(Object? scalar, [Object? i18n]) {
    final fallback = scalar is String ? scalar : '';
    if (i18n is! Map) {
      return LocalizedText._(fallback, const {}, const {}, const {});
    }
    final inline = <String, String>{};
    final refs = <String, String>{};
    for (final entry in i18n.entries) {
      final locale = entry.key.toString();
      if (!isValidLocaleKey(locale)) {
        AppLog.i('apps', "i18n: skipping invalid locale key '$locale'");
        continue;
      }
      final entryValue = entry.value;
      if (entryValue is String) {
        if (entryValue.trim().isNotEmpty) inline[locale] = entryValue;
      } else if (entryValue is Map) {
        final file = entryValue['file'];
        final path = file is String ? normalizeRefPath(file) : null;
        if (path == null) {
          AppLog.i(
            'apps',
            "i18n: skipping unsafe/invalid file ref for locale '$locale'",
          );
          continue;
        }
        refs[locale] = path;
      } else {
        AppLog.i(
          'apps',
          "i18n: skipping non-string value for locale '$locale'",
        );
      }
    }
    return LocalizedText._(fallback, inline, refs, const {});
  }

  /// The scalar (default-locale) value from the legacy manifest key;
  /// empty when absent or not a string.
  final String fallback;

  /// Inline per-locale values (locale tag → text).
  final Map<String, String> inline;

  /// Per-locale file references (locale tag → normalized widget-relative
  /// path, leading `./` stripped).
  final Map<String, String> refs;

  /// Ref file contents loaded at display-listing time (path → content).
  final Map<String, String> contents;

  /// Every referenced file path (normalized).
  Set<String> get refPaths => refs.values.toSet();

  /// Attaches loaded ref file contents (path → content).
  LocalizedText withContents(Map<String, String> contents) =>
      LocalizedText._(fallback, inline, refs, contents);

  /// Resolves the best value for [locale] (a BCP-47-ish tag like `en` or
  /// `pt-BR`; null/empty = no preference). Order: exact tag → language →
  /// `en` entry → the scalar [fallback] → first declared entry. Ref
  /// entries whose content was not loaded fall through to the next
  /// candidate.
  String resolve(String? locale) {
    final candidates = <String>[];
    if (locale != null && locale.isNotEmpty) {
      candidates.add(locale);
      final dash = locale.indexOf('-');
      if (dash > 0) candidates.add(locale.substring(0, dash));
    }
    candidates.add('en');
    String? valueFor(String tag) {
      for (final entry in inline.entries) {
        if (entry.key.toLowerCase() == tag) return entry.value;
      }
      for (final entry in refs.entries) {
        if (entry.key.toLowerCase() == tag) {
          final content = contents[entry.value];
          if (content != null) return content;
        }
      }
      return null;
    }

    for (final candidate in candidates) {
      final value = valueFor(candidate.toLowerCase());
      if (value != null) return value;
    }
    if (fallback.isNotEmpty) return fallback;
    // Last resort: the first declared entry (inline first, then a
    // loaded ref).
    if (inline.isNotEmpty) return inline.values.first;
    for (final entry in refs.entries) {
      final content = contents[entry.value];
      if (content != null) return content;
    }
    return fallback;
  }

  static final _localeKeyPattern = RegExp(
    r'^[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})*$',
  );

  /// Whether [key] is a well-formed locale tag (`en`, `ru`, `pt-BR`,
  /// `zh-Hans`): 2–3 letters, optional `-subtag` segments.
  static bool isValidLocaleKey(String key) => _localeKeyPattern.hasMatch(key);

  /// Normalizes a ref path (`./i18n/ru.md` → `i18n/ru.md`), or returns
  /// null when the path is unsafe: absolute, empty, a parent escape
  /// (`..`) or a backslash path.
  static String? normalizeRefPath(String raw) {
    var path = raw.trim();
    while (path.startsWith('./')) {
      path = path.substring(2);
    }
    if (path.isEmpty || path.startsWith('/') || path.contains('\\')) {
      return null;
    }
    if (path.split('/').contains('..')) return null;
    return path;
  }
}
