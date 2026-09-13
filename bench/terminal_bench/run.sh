#!/bin/sh
# Builds the fa CLI bundle and runs it against terminal-bench.
#
# Usage:
#   ./run.sh -t hello-world                     # specific task ids / globs
#   TASKS="-t chess-best-move -t fix-git" ./run.sh
#   ./run.sh -t 'crack-7z-hash*'                # glob supported by tb
#
# Environment:
#   FA_PROVIDER_TYPE / FA_PROVIDER_CONFIG / <apiKeyEnvVar> — fa provider
#   preconfig passed through to the container (see env_provider_preconfig).
#   DATASET (default terminal-bench-core==0.1.1), OUT (default /tmp/tb-runs).
#   TIMEOUT_MULTIPLIER (default 2) — tb --global-timeout-multiplier; the
#   dataset's declared task timeouts (median 360s agent / 60s test) assume a
#   fast model and a warm container network. The 0.1.1 baseline run
#   (issue #142) lost trials to agents killed mid-progress and to test
#   phases still apt-installing their own deps when the 60s cap hit.
#
# tb needs the docker socket; run via sudo with the user env preserved:
#   sudo -n env HOME=$HOME PATH=$PATH bench/terminal_bench/run.sh -t hello-world
set -e

REPO=$(cd "$(dirname "$0")/../.." && pwd)
DATASET=${DATASET:-terminal-bench-core==0.1.1}
case "$DATASET" in *==*) ;; *) echo "DATASET must be name==version, got: $DATASET" >&2; exit 1;; esac
OUT=${OUT:-/tmp/tb-runs}
TIMEOUT_MULTIPLIER=${TIMEOUT_MULTIPLIER:-2}
BUNDLE=$(mktemp -d)/fa-bundle

echo "==> building fa bundle"
(cd "$REPO" && dart build cli --target=bin/fah.dart --output="$BUNDLE")

echo "==> packing bundle"
tar -czf /tmp/fa-bundle.tar.gz -C "$BUNDLE/bundle" .

echo "==> fetching dataset into tb cache (skipped when present)"
tb datasets download -d "$DATASET"
DS_CACHE="$HOME/.cache/terminal-bench/${DATASET%%==*}/${DATASET##*==}"
python3 "$REPO/bench/terminal_bench/patch_dataset.py" "$DS_CACHE"

echo "==> running terminal-bench"
export FA_BUNDLE_TARBALL=/tmp/fa-bundle.tar.gz
export PYTHONPATH="$REPO/bench/terminal_bench${PYTHONPATH:+:$PYTHONPATH}"

# shellcheck disable=SC2086
exec tb run -d "$DATASET" --agent-import-path fa_agent:FaAgent \
    --output-path "$OUT" --no-cleanup --global-timeout-multiplier "$TIMEOUT_MULTIPLIER" "$@"
