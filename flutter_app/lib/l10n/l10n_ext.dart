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

/// The app's ONE locale decision, shared by the [MaterialApp] resolution
/// and context-free surfaces (issue #867 thread: the 429 error bubble).
/// An absent or EMPTY device locale (CI containers, stripped webviews)
/// falls back to English instead of reaching intl; anything else resolves
/// against [AppLocalizations.supportedLocales], so an in-app override or
/// a changed supported set cannot drift between surfaces.
Locale resolveAppLocale(Locale? deviceLocale) {
  if (deviceLocale == null || deviceLocale.languageCode.isEmpty) {
    return const Locale('en');
  }
  return basicLocaleListResolution(
    [deviceLocale],
    AppLocalizations.supportedLocales,
  );
}
