**Fixed.** The 3:1 label-floor matrix in `test/cli/tui_theme_test.dart` now loops `toolTitle` over **both** tints per palette, mirroring the per-tint glyph-rail checks:

```dart
for (final (name, tint) in [
  ('toolSuccessBg', bgOf(t.toolSuccessBg)),
  ('toolErrorBg', bgOf(t.toolErrorBg)),
]) {
  expect(
    themeColorContrast(fgOf(t.toolTitle)!, tint!),
    greaterThanOrEqualTo(kThemeSecondaryTextFloor),
    reason: '${entry.key}: toolTitle on $name',
  );
}
```

All 7 built-in palettes clear 3:1 on both tints — the enforcement gap (a palette that passes on the error tint but fails on the success tint) is closed.
