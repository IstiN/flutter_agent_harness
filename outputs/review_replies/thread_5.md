# Re: 🔵 SUGGESTION: `kDefaultTuiTheme`'s "byte-identical" doc promise is now stale

Fixed — the doc comment on `kDefaultTuiTheme` no longer promises byte-identity:

> The boot default: the historical site palette (site/styles.css teal + indigo). Since gh-671 dim detail text carries an explicit `toolOutput` foreground (the old byte-identical-to-pre-theming invariant is deliberately broken — see `tui_theme_default.ans`).
