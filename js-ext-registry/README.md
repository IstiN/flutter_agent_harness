# js-ext-registry

Publishable copies of the first-party JS extensions. Each directory holds a
`manifest.json` + `main.js` pair that MUST stay byte-equal to the Dart
consts compiled into the binary — `test/js_ext/registry_sync_test.dart`
fails the moment they drift. Nothing here is served from this repo: the
copies are the source for the catalog zips and the standalone GitHub repos
described below.

- `crap-guard/` — the bundled reference extension (issue #32): post-edit
  CRAP + file-size guard wired to `crap4dart` and the repo 2800-line cap.
  Source of truth: `lib/src/js_ext/bundled/crap_guard.dart`
  (`kCrapGuardManifestJson`, `kCrapGuardMainJs`). Edit the CONST first,
  then mirror the bytes here — the sync test is the gate.

## Layout rules per target

| Target | Shape |
| --- | --- |
| `gh:owner/repo` install | `manifest.json` + `main.js` at the REPO ROOT (the v1 layout the installer reads via raw.githubusercontent.com); extra text files allowed |
| Catalog zip | ONE root folder `<id>/` inside the zip holding `manifest.json` + `main.js` (zip-slip-safe, matches the fa_widgets contract) |
| `fa ext install ./dir` | Same as the gh layout — a plain directory on disk |

## Publish crap-guard to the fa_widgets catalog

The catalog repo (`IstiN/fa_widgets`) is the single source consumers fetch:
`https://github.com/IstiN/fa_widgets/releases/latest/download/catalog.json`.
Publishing means a PR there (CI builds + uploads the release assets).

1. Build the zip with the single-root layout:

   ```
   stage=$(mktemp -d)/crap-guard-1.0.0
   mkdir -p "$stage/crap-guard"
   cp js-ext-registry/crap-guard/manifest.json \
      js-ext-registry/crap-guard/main.js "$stage/crap-guard/"
   (cd "$stage" && zip -r "$OLDPWD/crap-guard-1.0.0.zip" crap-guard)
   ```

2. Hash the EXACT published bytes:

   ```
   shasum -a 256 crap-guard-1.0.0.zip    # → zipSha256 (hex)
   ```

3. Add the entry under the new `extensions` key of `catalog.json`
   (alongside — never inside — the existing `widgets` array):

   ```json
   {
     "id": "crap-guard",
     "kind": "cli-extension",
     "version": "1.0.0",
     "description": "Post-edit CRAP + file-size guard wired to crap4dart and the repo line cap",
     "author": "Fa",
     "tags": ["quality", "hooks"],
     "platforms": ["cli", "macos", "linux", "windows"],
     "zipFile": "crap-guard-1.0.0.zip",
     "zipSha256": "<hex from step 2>"
   }
   ```

   Flat `zipFile`/`zipSha256` (no nested `zip:{}` object) is what the
   extension catalog client reads; the v1 widget entries keep their nested
   shape untouched. `platforms` values: `cli`, `macos`, `ios`, `android`,
   `web`, `linux`, `windows` — omit for "all".

4. PR to `IstiN/fa_widgets`. CI re-runs the validator, rebuilds zips,
   creates the immutable tag `crap-guard-v1.0.0` and refreshes the rolling
   `catalog` release (`--clobber`). Verify:

   ```
   curl -Ls https://github.com/IstiN/fa_widgets/releases/latest/download/catalog.json | jq .extensions
   ```

5. Consumers install with `fa ext install catalog:crap-guard` (sha256
   verified before unpack; the TOFU prompt shows the capability snapshot).

### schemaVersion compatibility

`schemaVersion` STAYS `1`. Per `docs/widgets/GOAL.md` the contract is
"additive changes only within schemaVersion 1; bump the number when
breaking" — adding the `extensions` key and new entries is additive:
existing app clients read `widgets[]` only and treat unknown top-level keys
as forward-compatible warnings, never errors. The extension-aware client
tolerates any schemaVersion value and unions `widgets` + `extensions`, so
old clients keep working and no version bump is needed.

## Publish as a standalone GitHub repo

For `gh:owner/repo` installs, copy the two files to a fresh repo ROOT —
no subfolder, no zip:

```
git init crap-guard && cd crap-guard
cp ../js-ext-registry/crap-guard/manifest.json .
cp ../js-ext-registry/crap-guard/main.js .
git add . && git commit -m "crap-guard 1.0.0" && git tag v1.0.0
```

Then: `fa ext install gh:you/crap-guard` (or pin:
`fa ext install gh:you/crap-guard --pin <sha256 of the content>`).
