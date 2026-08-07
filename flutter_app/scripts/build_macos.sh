#!/bin/bash
# Build the Fa macOS app.
#
# By default this builds ad-hoc so it works without an Apple Developer cert.
# To sign with a real Apple Development identity, export FA_CODE_SIGN_IDENTITY
# and FA_DEVELOPMENT_TEAM, or run without those variables to get an ad-hoc
# signed build.
set -euo pipefail

cd "$(dirname "$0")/.."

# If a local Apple Development certificate is available, default to real signing
# so macOS TCC prompts (Calendar, Contacts, HealthKit, HomeKit) appear
# reliably. Otherwise fall back to ad-hoc signing so the app still builds for
# contributors without a certificate.
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

# When real signing is requested and no team is provided, extract the team
# identifier from the matching certificate's subject.
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

flutter build macos "$@"
