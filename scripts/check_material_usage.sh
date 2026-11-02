#!/usr/bin/env bash
# check_material_usage.sh — Material-usage ratchet baseline generator for
# flutter_app (see flutter_app/test/ui/styleguide_guard_test.dart).
#
# Prints the CURRENT Material-usage counts for flutter_app/lib in the exact
# allowlist format the guard test parses. The five sections:
#   [icons]            material icon glyphs (`Icons.*`)
#   [material_colors]  hardcoded Material palette swatches (`Colors.blue`,
#                      `Colors.white54`, `Colors.green.shade400`, ...;
#                      `Colors.transparent` is exempt — a plain constant,
#                      not a style decision)
#   [material_widgets] raw Material widgets with fa_ui styleguide
#                      equivalents (buttons -> FaButton, IconButton ->
#                      FaIconButton, TextField -> FaTextField)
#   [material_app]     `MaterialApp(` outside the app root lib/main.dart
#   [theme_data]       raw `ThemeData(` constructors anywhere in lib
#                      (the theme comes from fa_ui's buildFaTheme)
#
# Usage:
#   bash scripts/check_material_usage.sh
#     Allowlist-format sections go to stdout; a human summary goes to
#     stderr. Run this to inspect the current ratchet counts.
#
#   Regenerate the ratchet baseline AFTER a deliberate cleanup (removing
#   Material usages) so the ceilings can never grow back:
#     scripts/check_material_usage.sh \
#       > flutter_app/test/ui/styleguide_material_allowlist.txt
#
#   CI ratchet check (fails when the baseline would grow):
#     scripts/check_material_usage.sh > /tmp/material_allowlist.txt
#     diff -u flutter_app/test/ui/styleguide_material_allowlist.txt \
#             /tmp/material_allowlist.txt
#
# NOTE: the counting rules here MUST stay in sync with the Dart guard
# (flutter_app/test/ui/styleguide_guard_test.dart); that test is the
# authority, this script only (re)generates its baseline.
set -euo pipefail
cd "$(dirname "$0")/../flutter_app"

readonly COLOR_SET='^(amber|black|blue|blueGrey|brown|cyan|deepOrange|deepPurple|green|grey|indigo|lightBlue|lightGreen|lime|orange|pink|purple|red|teal|violet|white|yellow)$'

# lib/l10n is generated localizations; *.g.dart is generated code — skipped.
readonly SKIP='^lib/l10n/|\.g\.dart:'

# [icons] — material icon glyphs.
count_icons() {
  { grep -arEo "\bIcons\.[a-zA-Z_][a-zA-Z0-9_]*" lib --include='*.dart' \
      | grep -Ev "$SKIP" | cut -d: -f1 || true; }
}

# [material_colors] — hardcoded Material palette swatches.
# Normalizes `white54` -> `white`, `redAccent` -> `red` before the set check.
count_material_colors() {
  { grep -arEo "\bColors\.[a-zA-Z_][a-zA-Z0-9_]*" lib --include='*.dart' \
      | grep -Ev "$SKIP" | awk -F: -v known="$COLOR_SET" '
        {
          t = $2
          sub(/^Colors\./, "", t)
          sub(/[0-9]+$/, "", t)
          sub(/Accent$/, "", t)
          if (t ~ known) print $1
        }' || true; }
}

# [material_widgets] — raw Material widgets with styleguide equivalents.
count_material_widgets() {
  { grep -arEo \
      "\b(ElevatedButton|FilledButton|TextButton|OutlinedButton|IconButton|TextField)(\.[a-zA-Z_][a-zA-Z0-9_]*)?[[:space:]]*\(" \
      lib --include='*.dart' \
      | grep -Ev "$SKIP" | cut -d: -f1 || true; }
}

# [material_app] — MaterialApp outside the app root (lib/main.dart).
count_material_app() {
  { grep -arEo "\bMaterialApp(\.[a-zA-Z_][a-zA-Z0-9_]*)?[[:space:]]*\(" \
      lib --include='*.dart' \
      | grep -Ev "$SKIP" | grep -v '^lib/main.dart:' | cut -d: -f1 || true; }
}

# [theme_data] — raw ThemeData( constructors in lib.
count_theme_data() {
  { grep -arEo "\bThemeData[[:space:]]*\(" lib --include='*.dart' \
      | grep -Ev "$SKIP" | cut -d: -f1 || true; }
}

# count_x | per_file  ->  "<lib path> <count>" lines, sorted by path.
per_file() {
  sort | uniq -c | sort -k2 | awk '{print $2, $1}'
}

summary() { # summary <label> <body>
  local label="$1" body="$2"
  if [ -n "$body" ]; then
    printf '%s: %s occurrences in %s files\n' "$label" \
      "$(printf '%s\n' "$body" | awk '{s+=$2} END{print s+0}')" \
      "$(printf '%s\n' "$body" | wc -l | tr -d ' ')" >&2
  else
    printf '%s: 0 occurrences\n' "$label" >&2
  fi
}

main() {
  local icons colors widgets material_app theme_data
  icons="$(count_icons | per_file)"
  colors="$(count_material_colors | per_file)"
  widgets="$(count_material_widgets | per_file)"
  material_app="$(count_material_app | per_file)"
  theme_data="$(count_theme_data | per_file)"

  # stdout: the allowlist format consumed by the guard test. Regenerate
  # with `scripts/check_material_usage.sh > <allowlist>` after cleanups.
  cat <<'HEADER'
# Material-usage ratchet allowlist — parsed by
# flutter_app/test/ui/styleguide_guard_test.dart.
# Format: `[section]` header, then one `<lib path> <max count>` per line.
# This file only ever SHRINKS: regenerate it with
#   scripts/check_material_usage.sh \
#     > flutter_app/test/ui/styleguide_material_allowlist.txt
# after removing Material usages from lib/. Never raise a ceiling to
# silence the guard.
HEADER
  printf '[icons]\n%s\n' "$icons"
  printf '[material_colors]\n%s\n' "$colors"
  printf '[material_widgets]\n%s\n' "$widgets"
  printf '[material_app]\n%s\n' "$material_app"
  printf '[theme_data]\n%s\n' "$theme_data"

  # stderr: human summary.
  summary icons "$icons"
  summary material_colors "$colors"
  summary material_widgets "$widgets"
  summary material_app "$material_app"
  summary theme_data "$theme_data"
}

main "$@"
