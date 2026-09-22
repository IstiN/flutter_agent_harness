#!/usr/bin/env bash
# check_action_pins.sh — SEC-08 (#796) AC1/AC4: mutable references to
# executable code are lint errors. Fails on any third-party GitHub Actions
# `uses:` ref that is not pinned to a full commit SHA.
#
#   bash scripts/check_action_pins.sh            # scan the repo (CI gate)
#   bash scripts/check_action_pins.sh --path DIR # scan DIR/*.yml (fixtures)
#
# Exempt:
#   - ./...          first-party repo-relative actions/workflows
#   - @<40-hex>      full commit SHA (the only accepted third-party form)
# Everything else (tags, branches, latest, main, master, short SHAs) fails.

set -eu

dir=".github/workflows"
if [ "${1:-}" = "--path" ]; then
  [ -n "${2:-}" ] || { echo "usage: $0 [--path DIR]" >&2; exit 2; }
  dir="$2"
fi

shopt -s nullglob
if [ "$dir" = ".github/workflows" ]; then
  files=("$dir"/*.yml "$dir"/*.yaml .github/actions/*/action.yml)
else
  files=("$dir"/*.yml "$dir"/*.yaml)
fi

if [ ${#files[@]} -eq 0 ]; then
  echo "no workflow files found under $dir" >&2
  exit 2
fi

violations=0
for file in "${files[@]}"; do
  refs=$(grep -hoE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[^[:space:]]+' "$file" 2>/dev/null | sed -E 's/.*uses:[[:space:]]*//') || true
  [ -n "$refs" ] || continue
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case "$ref" in
      ./*) ;; # first-party repo-relative action/workflow
      docker://*)
        case "$ref" in
          *@sha256:*) ;; # digest-pinned container image
          *)
            echo "::error file=$file::unpinned container image ref: $ref"
            violations=$((violations + 1))
            ;;
        esac
        ;;
      *)
        sha="${ref##*@}"
        case "$sha" in
          ????????????????????????????????????????) ;; # 40-hex commit SHA
          *)
            echo "::error file=$file::third-party action not SHA-pinned: $ref"
            violations=$((violations + 1))
            ;;
        esac
        ;;
    esac
  done <<EOF
$refs
EOF
done

if [ "$violations" -gt 0 ]; then
  echo "check_action_pins: $violations mutable third-party action ref(s)" >&2
  exit 1
fi
echo "check_action_pins: OK (all third-party actions SHA-pinned)"
