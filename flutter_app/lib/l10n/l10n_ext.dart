import 'package:flutter/widgets.dart';

import 'app_localizations.dart';
import 'app_localizations_en.dart';

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
