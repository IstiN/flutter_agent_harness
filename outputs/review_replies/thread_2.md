# Re: 🔵 SUGGESTION: 3:1 label floor is only checked on `toolErrorBg`, not `toolSuccessBg`

Done, exactly as suggested: the floor matrix in `test/cli/tui_theme_test.dart` ("tool-row labels and state rails clear 3:1 over their tints") now checks `toolTitle` against **both** tints per palette:

```dart
for (final (tintName, tint) in [
  ('toolSuccessBg', bgOf(t.toolSuccessBg)),
  ('toolErrorBg', bgOf(t.toolErrorBg)),
]) {
  expect(
    themeColorContrast(fgOf(t.toolTitle)!, tint!),
    greaterThanOrEqualTo(kThemeSecondaryTextFloor),
    reason: '${entry.key}: toolTitle on $tintName',
  );
}
```

All 7 built-ins already clear 3:1 on the success tint, so no palette value changed — the enforcement gap is closed. Suite: `test/cli/tui_theme_test.dart` 41 tests green.
