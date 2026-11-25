#!/usr/bin/env bash
# Sterile fa arm launcher (layer 1 of the agent sandbox design).
# Usage: run_arm.sh <arm-id> <prompt-file> [extra fa args...]
# Env knobs: ARM_ROOT (default /tmp/fa-arm-<id>), FIXTURE (repo to clone),
#            ARM_TOOLS_EXTRA (csv appended to the deny list, e.g. "task=on"),
#            ARM_UNSAFE=1 (positive control: drop session-root isolation).
set -euo pipefail

ARM="${1:?arm id}"; PROMPT_FILE="$(cd "$(dirname "${2:?prompt file}")" && pwd)/$(basename "$2")"; shift 2
HERE="$(cd "$(dirname "$0")" && pwd)"
ARM_ROOT="${ARM_ROOT:-/tmp/fa-arm-$ARM}"
FIXTURE="${FIXTURE:-$HERE/fixture}"
HOME_A="$ARM_ROOT/home"
WORK="$ARM_ROOT/work"
SESS="$HOME_A/sessions"

[[ "$ARM" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "refusing arm id '$ARM' (allowed: A-Za-z0-9_-)" >&2; exit 2; }
case "$ARM_ROOT" in
  *..*) echo "refusing ARM_ROOT=$ARM_ROOT (contains ..)" >&2; exit 2;;
  /tmp/fa-arm-*|/private/tmp/fa-arm-*) ;;
  *) echo "refusing ARM_ROOT=$ARM_ROOT" >&2; exit 2;;
esac
rm -rf "$ARM_ROOT"
mkdir -p "$HERE/out" "$HOME_A/.fah" "$SESS" "$ARM_ROOT/joblogs" "$ARM_ROOT/tmp"
chmod 700 "$ARM_ROOT"
# Fresh single-commit copy: no remote/origin path that points back to the fixture.
mkdir -p "$WORK"
tar -C "$FIXTURE" --exclude=__pycache__ -cf - . | tar -x -C "$WORK"
git -C "$WORK" init -q -b main
git -C "$WORK" -c user.email=arm@sandbox.invalid -c user.name=arm add -A
git -C "$WORK" -c user.email=arm@sandbox.invalid -c user.name=arm commit -qm "initial"

cp "$PROMPT_FILE" "$ARM_ROOT/prompt.md"; PROMPT_FILE="$ARM_ROOT/prompt.md"
printf 'approvalMode: yolo\n' > "$HOME_A/.fah/config.yaml"

# Denylist (fa has no allowlist): every non-core family is switched off.
# `task` family also carries agent_message/agent_directory/reply.
TOOLS="web_search=off,session_search=off,memory=off,mcp=off,lsp=off,task=off,\
schedule_message=off,dap=off,sqlite=off,browser=off,browser_eval=off,\
generate_image=off,generate_video=off,inspect_image=off,transcribe_audio=off,\
ask=off,request_secret=off"
[ -n "${ARM_TOOLS_EXTRA:-}" ] && TOOLS="$TOOLS,$ARM_TOOLS_EXTRA"

ZAI_KEY="$(security find-generic-password -s fah -a FA_KEY_API_Z_AI -w 2>/dev/null || true)"
[ -n "$ZAI_KEY" ] || { echo "no z.ai key in keychain" >&2; exit 3; }

SESSION_ARGS=(--session-root "$SESS")
[ "${ARM_UNSAFE:-0}" = 1 ] && SESSION_ARGS=()

# Hard FS isolation (seatbelt). Writes: denied everywhere except the arm root
# and /dev. Reads: allow-default minus the user-data trees below (system
# binaries/libs must stay readable); later rules win in seatbelt.
REAL_ROOT="$(cd "$ARM_ROOT" && pwd -P)"
# Execute the very binary the profile allows (env -i PATH may order differently).
FA_BIN="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$(command -v fa)")"
SBX=()
if [ "${ARM_NO_SBX:-0}" != 1 ]; then
  cat > "$HERE/out/arm-$ARM.sb" <<SB
(version 1)
(allow default)
(deny file-write*)
(allow file-write* (subpath "$REAL_ROOT") (subpath "/dev"))
(deny file-read* (subpath "/Users") (subpath "/private/tmp") (subpath "/private/var/tmp") (subpath "/private/var/folders") (subpath "/Volumes"))
(deny mach-lookup (global-name-prefix "com.apple.metadata") (global-name-prefix "com.apple.Spotlight"))
(allow file-read-metadata (subpath "/Users") (subpath "/private/tmp") (subpath "/private/var/tmp") (subpath "/private/var/folders"))
(allow file-read* (subpath "$REAL_ROOT"))
(allow file-read* (literal "$FA_BIN"))
SB
  SBX=(sandbox-exec -f "$HERE/out/arm-$ARM.sb")
fi

cd "$WORK"
# env -i: nothing inherited (no GH_TOKEN/GITHUB_TOKEN/SSH_AUTH_SOCK/*_TOKEN).
exec env -i \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$HOME/.local/bin" \
  HOME="$HOME_A" TMPDIR="$ARM_ROOT/tmp" LANG=en_US.UTF-8 TERM=dumb \
  FAH_JOB_LOG_DIR="$ARM_ROOT/joblogs" \
  FA_PROVIDER_TYPE=zai \
  FA_PROVIDER_CONFIG='{"baseUrl":"https://api.z.ai/api/coding/paas/v4","model":"glm-5.3-flash","apiKeyEnvVar":"ZAI_API_KEY"}' \
  ZAI_API_KEY="$ZAI_KEY" \
  ${SBX[@]+"${SBX[@]}"} "$FA_BIN" ${SESSION_ARGS[@]+"${SESSION_ARGS[@]}"} --cwd "$WORK" --tools "$TOOLS" \
     --prompt-file "$PROMPT_FILE" "$@"
