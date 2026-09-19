**Fixed** in `lib/src/cli/fa_tui_rows.dart` — the truncated branch of `_menuItemRow` now applies the accent wrap after `_fitWidth`:

```dart
final fitted = _fitWidth(plain, termWidth - 2);
if (selected) return '$prefix${_rearmSelection(fitted)}';
```

The stale comment ("`plain` carries no `\x1b[0m`, so `_rearmSelection` would be a no-op here") is removed — it described exactly the behavior this change introduces.

Regression test added RED-first in `test/cli/fa_tui_fuzzy_roles_test.dart`: *"gh-671: a TRUNCATED selected label wears the accent too"* — a generic picker at `termWidth: 20` with a 22-cell label asserts the accent SGR opens immediately before the fitted cells (failed before the fix, passes after; verified it fails against the pre-fix renderer).
