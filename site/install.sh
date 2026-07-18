#!/bin/sh
# install.sh — one-line installer for the fah CLI (flutter_agent_harness).
#
# What it does:
#   1. Checks that the Dart SDK (`dart`) is on PATH — fah is distributed
#      through pub.dev, so the SDK is required. If missing, it points you to
#      the install docs and exits.
#   2. Runs `dart pub global activate flutter_agent_harness`, which installs
#      (or updates to) the latest published version. The package provides the
#      `fah` and `fa` executables in ~/.pub-cache/bin.
#   3. Verifies `fah` ended up on PATH; if not, prints the PATH line to add
#      for your shell.
#   4. Prints next steps: set a provider API key, then run `fah`.
#
# Safe to re-run: `pub global activate` is idempotent — re-running simply
# reinstalls the latest version. The script uses no sudo, touches nothing
# outside the Dart pub cache, and never reads or writes your API keys.
#
# Run it:
#   curl -fsSL https://istin.github.io/flutter_agent_harness/install.sh | sh
#
# Or inspect it first:
#   curl -fsSL https://istin.github.io/flutter_agent_harness/install.sh -o install.sh
#   less install.sh
#   sh install.sh

set -eu

PACKAGE="flutter_agent_harness"
PUB_CACHE_BIN="${PUB_CACHE_BIN:-$HOME/.pub-cache/bin}"

say() {
  printf '%s\n' "$*"
}

say ""
say "fah installer — flutter_agent_harness CLI"
say "------------------------------------------"

# ── 1. Dart SDK ─────────────────────────────────────────────────────────────
if ! command -v dart >/dev/null 2>&1; then
  say ""
  say "Error: the Dart SDK ('dart') is not on your PATH."
  say ""
  say "fah is distributed via pub.dev and needs the Dart SDK, which is bundled"
  say "with Flutter. Install it from:"
  say ""
  say "    https://docs.flutter.dev/get-started/install"
  say ""
  say "Then re-run this installer:"
  say ""
  say "    curl -fsSL https://istin.github.io/flutter_agent_harness/install.sh | sh"
  say ""
  exit 1
fi

say "Found $(dart --version 2>&1)"

# ── 2. Activate the package (idempotent — re-run updates to latest) ─────────
if dart pub global list 2>/dev/null | grep -q "^${PACKAGE} "; then
  say "Updating ${PACKAGE} to the latest version from pub.dev..."
else
  say "Installing ${PACKAGE} from pub.dev..."
fi
dart pub global activate "${PACKAGE}"

# ── 3. PATH check ───────────────────────────────────────────────────────────
say ""
if command -v fah >/dev/null 2>&1; then
  say "OK: 'fah' is on your PATH ($(command -v fah))."
else
  say "Note: 'fah' is not on your PATH yet. The executables live in:"
  say ""
  say "    ${PUB_CACHE_BIN}"
  say ""
  case "${SHELL:-}" in
    */fish)
      say "Add it with (fish persists this automatically):"
      say ""
      say "    fish_add_path ${PUB_CACHE_BIN}"
      ;;
    *)
      say "Add this line to your shell's startup file, or run it now:"
      say ""
      say "    export PATH=\"\$PATH:${PUB_CACHE_BIN}\""
      say ""
      case "${SHELL:-}" in
        */zsh)  say "(startup file: ~/.zshrc)" ;;
        */bash) say "(startup file: ~/.bashrc, or ~/.bash_profile on macOS)" ;;
        *)      ;;
      esac
      ;;
  esac
fi

# ── 4. Next steps ───────────────────────────────────────────────────────────
say ""
say "Next steps:"
say ""
say "  1. Give fah a provider API key, e.g. OpenRouter:"
say ""
say "       export OPENROUTER_API_KEY=<your-key>"
say ""
say "     (OpenAI-compatible, Anthropic, and Google keys work too —"
say "      see the README for the variable names.)"
say ""
say "  2. Start the agent:"
say ""
say "       fah"
say ""
say "Docs:    https://github.com/IstiN/flutter_agent_harness"
say "Package: https://pub.dev/packages/flutter_agent_harness"
say ""
