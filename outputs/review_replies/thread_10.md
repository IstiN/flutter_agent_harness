**Fixed.** `lib/src/cli/fa_tui_rows.dart`, truncated branch of `_menuItemRow`:

```dart
final fitted = _fitWidth(plain, termWidth - 2);
if (selected) return '$prefix${_rearmSelection(fitted)}';
```

The stale comment is removed. Regression test (RED→GREEN) in `test/cli/fa_tui_fuzzy_roles_test.dart`: *"gh-671: a TRUNCATED selected label wears the accent too"* — generic picker at `termWidth: 20` with a 22-cell label; it asserts the accent SGR opens immediately before the fitted cells and failed against the pre-fix renderer.
