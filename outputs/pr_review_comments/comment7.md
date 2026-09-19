🔵 **SUGGESTION (still open from the previous review round): `kDefaultTuiTheme`'s "byte-identical" doc promise is stale**

The doc comment on `kDefaultTuiTheme` (line ~75) still claims *"Truecolor
output is byte-identical to the pre-theming CLI."* Adding an explicit
`toolOutput` foreground breaks that invariant on purpose — the regenerated
`tui_theme_default.ans` golden now emits `38;2;184;194;206` on every dim
detail segment. The change is right (it is the gh-671 fix), but the doc
should stop promising byte-identity.
