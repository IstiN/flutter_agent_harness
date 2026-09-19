# Re: 🔵 SUGGESTION: truncated selected rows lose the new accent wrap (and the comment above is now stale)

Fixed in `lib/src/cli/fa_tui_rows.dart` (`_menuItemRow`, truncated branch):

```dart
final fitted = _fitWidth(plain, termWidth - 2);
if (selected) return '$prefix${_rearmSelection(fitted)}';
return '$prefix$fitted';
```

The fitted plain text carries no embedded SGR, so `_rearmSelection` now wraps it in the selection accent (the stale "would be a no-op here" comment is replaced — it documents the gh-671 wrap instead).

**TDD:** new test `gh-671: a TRUNCATED selected label wears the accent too` in `test/cli/fa_tui_fuzzy_roles_test.dart` builds the model with `termWidth: 20` and a 22-cell label, then asserts the accent SGR opens *after* the `▸` glyph and *immediately before* the fitted label cells. It failed against the old truncated branch (only the glyph was accented) and passes with the fix.
