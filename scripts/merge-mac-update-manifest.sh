#!/usr/bin/env bash
set -euo pipefail

# Merge per-arch macOS auto-update manifests into a single latest-mac.yml.
# Usage: merge-mac-update-manifest.sh <input-dir> <output-file>

INPUT_DIR="${1:?input dir required}"
OUTPUT="${2:?output file required}"

python3 - <<'PY' "$INPUT_DIR" "$OUTPUT"
import glob
import os
import sys
import yaml

input_dir, output = sys.argv[1], sys.argv[2]
manifests = []
for path in sorted(glob.glob(os.path.join(input_dir, 'latest-mac-*.yml'))):
    with open(path, 'r', encoding='utf-8') as f:
        manifests.append(yaml.safe_load(f))

if not manifests:
    raise SystemExit('no manifests found')

merged = manifests[0].copy()
merged['files'] = []
for m in manifests:
    merged['files'].extend(m.get('files', []))

# Prefer arm64 as the top-level default if present.
arm64 = next((m for m in manifests if any(f.get('arch') == 'arm64' for f in m.get('files', []))), manifests[0])
merged['path'] = arm64['path']
merged['sha512'] = arm64['sha512']

with open(output, 'w', encoding='utf-8') as f:
    yaml.safe_dump(merged, f, sort_keys=False)
PY
