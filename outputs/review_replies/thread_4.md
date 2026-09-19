# Re: 🔵 SUGGESTION: this reformat introduces a new analyzer info

Fixed with braces (`lib/src/cli/tui_theme.dart`, `loadUserThemes`):

```dart
if (homeDir == null || homeDir.isEmpty) {
  return (themes: themes, errors: errors);
}
```

`dart analyze lib/src/cli/tui_theme.dart` is back to the 2 pre-existing `implementation_imports` infos — same as `main`, the `curly_braces_in_flow_control_structures` info is gone.
