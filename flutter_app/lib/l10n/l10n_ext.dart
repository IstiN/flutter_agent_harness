import 'package:flutter/widgets.dart';

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/l10n/app_localizations_en.dart';

/// Shorthand accessor: `context.l10n.someKey`.
///
/// Falls back to English when no [AppLocalizations] delegate is in scope
/// (widget tests that pump a bare subtree, edge overlays), so copy lookup
/// never crashes — the runtime locale path always goes through the
/// MaterialApp delegates.
extension L10nX on BuildContext {
  AppLocalizations get l10n =>
      Localizations.of<AppLocalizations>(this, AppLocalizations) ??
      AppLocalizationsEn();
}

/// The boot-time handoff (`?lang=ru|en`, then the host's storage key) as
/// published by the app shell when it builds the [MaterialApp]. It exists
/// so context-free callers — the 429 rate-limit bubble — resolve the SAME
/// locale as the widget tree without a [BuildContext]: one locale decision
/// per process (issue #867 thread). Null on non-web builds and in tests
/// that do not pump the shell.
String? appLocaleOverride;

/// The app's ONE locale decision, shared by the [MaterialApp] resolution
/// and context-free surfaces (issue #867 thread: the 429 error bubble).
/// An absent or EMPTY device locale (CI containers, stripped webviews)
/// falls back to English instead of reaching intl; anything else resolves
/// against [AppLocalizations.supportedLocales], so an in-app override or
/// a changed supported set cannot drift between surfaces. An explicit
/// [localeOverride] wins; without one the published [appLocaleOverride]
/// applies.
Locale resolveAppLocale(Locale? deviceLocale, {String? localeOverride}) {
  final override = localeOverride ?? appLocaleOverride;
  if (override == 'ru' || override == 'en') {
    return Locale(override!);
  }
  if (deviceLocale == null || deviceLocale.languageCode.isEmpty) {
    return const Locale('en');
  }
  return basicLocaleListResolution([
    deviceLocale,
  ], AppLocalizations.supportedLocales);
}
