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
# Both modes share one shape: the root's workflows (either a
# .github/workflows layout or loose *.yml/*.yaml fixtures) plus EVERY
# composite action manifest at any depth — composite action steps can
# carry remote uses: refs, so they are part of AC1's threat surface.
files=("$dir"/.github/workflows/*.yml "$dir"/.github/workflows/*.yaml \
       "$dir"/*.yml "$dir"/*.yaml)
while IFS= read -r -d '' f; do
  files+=("$f")
done < <(find "$dir" -name .git -prune -o -type f \( -name 'action.yml' -o -name 'action.yaml' \) -print0 2>/dev/null)

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
        # A mutable ref whose NAME is exactly 40 chars would pass a pure
        # length glob — require hex digits (a commit SHA), nothing else.
        if [[ "$sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
          : # full 40-hex commit SHA — the only accepted third-party form
        else
          echo "::error file=$file::third-party action not SHA-pinned: $ref"
          violations=$((violations + 1))
        fi
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
