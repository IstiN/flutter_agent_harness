**Fixed.** `kDefaultTuiTheme`'s doc comment no longer promises byte-identity. It now states the deliberate gh-671 change explicitly:

> Since gh-671 dim detail text carries an explicit `toolOutput` foreground (the old byte-identical-to-pre-theming invariant is gone) …

The golden `tui_theme_default.ans` matches the new rendering.
