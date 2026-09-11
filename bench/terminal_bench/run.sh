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
#
# tb needs the docker socket; run via sudo with the user env preserved:
#   sudo -n env HOME=$HOME PATH=$PATH bench/terminal_bench/run.sh -t hello-world
set -e

REPO=$(cd "$(dirname "$0")/../.." && pwd)
DATASET=${DATASET:-terminal-bench-core==0.1.1}
OUT=${OUT:-/tmp/tb-runs}
BUNDLE=$(mktemp -d)/fa-bundle

echo "==> building fa bundle"
(cd "$REPO" && dart build cli --target=bin/fah.dart --output="$BUNDLE")

echo "==> packing bundle"
tar -czf /tmp/fa-bundle.tar.gz -C "$BUNDLE/bundle" .

echo "==> running terminal-bench"
export FA_BUNDLE_TARBALL=/tmp/fa-bundle.tar.gz
export PYTHONPATH="$REPO/bench/terminal_bench${PYTHONPATH:+:$PYTHONPATH}"

# shellcheck disable=SC2086
exec tb run -d "$DATASET" --agent-import-path fa_agent:FaAgent \
    --output-path "$OUT" --no-cleanup "$@"
