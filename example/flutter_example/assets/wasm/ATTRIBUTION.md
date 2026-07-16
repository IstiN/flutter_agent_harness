# WASM Binary Attribution

This directory contains WebAssembly binaries shipped as assets with the
Flutter Agent Harness example app. They are all built from permissive
open-source code and linked against WASI Preview 1 so that the in-app
shell works on iOS, Android, and web without spawning host processes.

## coreutils.wasm

- Source: https://github.com/uutils/coreutils
- Version: 0.9.0
- License: MIT (see `LICENSE.coreutils`)
- Target: `wasm32-wasip1`
- Notes: Multicall binary. The applet is selected via `argv[0]`.

## rg.wasm

- Source: https://github.com/BurntSushi/ripgrep
- Version: built from main at the time of packaging
- License: MIT (see `LICENSE.rg`)
- Target: `wasm32-wasip1`
- Notes: Single-call `rg` binary.

## find.wasm

- Source: https://github.com/uutils/findutils
- Version: 0.9.1
- License: MIT (see `LICENSE.findutils`)
- Target: `wasm32-wasip1`
- Notes: Single-call `find` binary.
