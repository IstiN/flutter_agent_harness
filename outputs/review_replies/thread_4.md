**Fixed.** The `loadUserThemes` home-dir guard uses the braced form:

```dart
if (homeDir == null || homeDir.isEmpty) {
  return (themes: themes, errors: errors);
}
```

`dart analyze` over the touched files (`tui_theme.dart`, `fa_tui_rows.dart`, and the three test files) reports only the 2 pre-existing `implementation_imports` infos — parity with `main`; the `curly_braces_in_flow_control_structures` info introduced by the reformat is gone.
