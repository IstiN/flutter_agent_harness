#!/bin/bash
# Run the Fa macOS app, signing with a local Apple Development certificate when
# available so TCC prompts (Calendar, Contacts, HealthKit, HomeKit) work.
set -euo pipefail

cd "$(dirname "$0")/.."

development_identity=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -m1 'Apple Development' \
  | sed -n 's/.*"\(.*\)".*/\1/p' || true)

if [[ -z "${FA_CODE_SIGN_IDENTITY:-}" ]]; then
  if [[ -n "$development_identity" ]]; then
    export FA_CODE_SIGN_IDENTITY="Apple Development"
  else
    export FA_CODE_SIGN_IDENTITY="-"
  fi
fi

if [[ "$FA_CODE_SIGN_IDENTITY" != "-" && -z "${FA_DEVELOPMENT_TEAM:-}" && -n "$development_identity" ]]; then
  team=$(security find-certificate -c "$development_identity" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | grep -oE 'OU=[A-Z0-9]+' \
    | cut -d= -f2 \
    | head -n1 || true)
  if [[ -n "$team" ]]; then
    export FA_DEVELOPMENT_TEAM="$team"
  fi
fi

export FA_CODE_SIGN_STYLE="${FA_CODE_SIGN_STYLE:-Automatic}"

flutter run -d macos "$@"
