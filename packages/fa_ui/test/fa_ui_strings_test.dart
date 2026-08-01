// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

class _RebrandStrings extends FaUiStringsEn {
  const _RebrandStrings();

  @override
  String get settingsAddProvider => 'Hook up a brain';
}

Future<FaUiStrings> _resolve(
  WidgetTester tester, {
  Locale? locale,
  FaUiStrings? scoped,
}) async {
  late FaUiStrings strings;
  final app = MaterialApp(
    locale: locale,
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('en'), Locale('ru')],
    home: Builder(
      builder: (context) {
        strings = FaUiStrings.of(context);
        return const SizedBox.shrink();
      },
    ),
  );
  await tester.pumpWidget(
    scoped == null ? app : FaUiStringsScope(strings: scoped, child: app),
  );
  return strings;
}

void main() {
  test('forLocale resolves the built-in defaults', () {
    expect(FaUiStrings.forLocale(const Locale('en')), isA<FaUiStringsEn>());
    expect(FaUiStrings.forLocale(const Locale('ru')), isA<FaUiStringsRu>());
    // Unknown locales fall back to English.
    expect(FaUiStrings.forLocale(const Locale('de')), isA<FaUiStringsEn>());
  });

  testWidgets('of(context) follows the ambient locale', (tester) async {
    final en = await _resolve(tester, locale: const Locale('en'));
    expect(en.settingsAddProvider, 'Add provider');
    final ru = await _resolve(tester, locale: const Locale('ru'));
    expect(ru.settingsAddProvider, 'Добавить провайдера');
  });

  testWidgets('a scope overrides the locale defaults', (tester) async {
    final strings = await _resolve(
      tester,
      locale: const Locale('ru'),
      scoped: const _RebrandStrings(),
    );
    expect(strings.settingsAddProvider, 'Hook up a brain');
  });

  test('parameterized strings interpolate', () {
    const strings = FaUiStringsEn();
    expect(strings.settingsDeleteProviderTitle('Acme'), 'Delete Acme?');
    expect(
      strings.settingsProviderModelSummary('gpt-4o', 'OpenRouter'),
      'gpt-4o · OpenRouter',
    );
    expect(
      strings.mediaModelsOverrideSummary('openai.com', 'gpt-image-1'),
      'gpt-image-1 · openai.com',
    );
  });
}
