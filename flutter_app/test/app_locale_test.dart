import 'package:fa/l10n/l10n_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Issue #867 thread: context-free surfaces (the 429 error bubble) share
/// the MaterialApp's ONE locale decision instead of reading the platform
/// locale raw — empty device locales and unsupported languages resolve
/// exactly like the app shell does.
void main() {
  test('an absent device locale falls back to English', () {
    expect(resolveAppLocale(null), const Locale('en'));
  });

  test('a supported device locale resolves to its language match', () {
    expect(resolveAppLocale(const Locale('ru')), const Locale('ru'));
    expect(resolveAppLocale(const Locale('ru', 'RU')).languageCode, 'ru');
  });

  test('an unsupported device locale resolves to English, not itself', () {
    expect(resolveAppLocale(const Locale('fr')).languageCode, 'en');
  });
}
