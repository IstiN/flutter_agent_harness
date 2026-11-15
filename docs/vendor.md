# vendor/ — patched dependency forks (KEEP)

`vendor/` holds **deliberate patched forks** of upstream packages. This note
is the written rationale the gh-2185 root-hygiene pass requires, so future
hygiene sweeps keep the directory instead of "cleaning" it away.

| Fork | Why it exists |
| --- | --- |
| `vendor/dart_tui` | keyboard-protocol fixes pending/absent upstream |
| `vendor/flutter_inappwebview_*` (linux/macos/windows stubs) | platform stubs so desktop builds compile without the heavy plugin on hosts that don't need it |
| `vendor/quickjs_runtime` | JS-apps runtime pin |
| `vendor/wasm_run` + `vendor/wasm_run_flutter` | wasm runtime fork (the iOS framework download path upstream is gone — the jniLibs are committed, see `.gitignore`) |
| `vendor/xterm` | terminal widget pin |

## The switch: `pubspec_overrides.yaml`

The tracked `pubspec_overrides.yaml` (237 B) points `dart_tui` at
`vendor/dart_tui`. Local + CI builds use the fork; the published
`flutter_agent_harness` package keeps the hosted dependency — **this file
never ships to pub.dev** (it is excluded from the publish payload). Do not
delete it as "leftover config": local and CI builds resolve `dart_tui`
through it.

## Publishing

`pub.dev` ships the hosted packages; the forks ride the repo checkout only
(`stage_publish_package.sh` prunes `/vendor` from the staged payload).
