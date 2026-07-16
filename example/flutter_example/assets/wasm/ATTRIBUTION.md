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

## sed.wasm

- Source: https://github.com/uutils/sed
- Version: 0.1.1
- License: MIT (see `LICENSE.sed`)
- Target: `wasm32-wasip1`
- Notes: Single-call `sed` binary.

## awk.wasm

- Source: https://github.com/benhoyt/goawk
- Version: built from main at the time of packaging
- License: MIT (see `LICENSE.awk`)
- Target: `wasm32-wasip1` via TinyGo
- Notes: Single-call `awk` binary.

## tar.wasm

- Source: generated helper in this repository (`wasm_utils/tar_util`)
- License: MIT (see `LICENSE.tar`)
- Target: `wasm32-wasip1`
- Notes: Single-call `tar` binary built from the Rust `tar` crate.

## gzip.wasm

- Source: generated helper in this repository (`wasm_utils/gzip_util`)
- License: MIT (see `LICENSE.gzip`)
- Target: `wasm32-wasip1`
- Notes: Single-call `gzip` binary built from the Rust `flate2` crate.

## zip.wasm

- Source: generated helper in this repository (`wasm_utils/zip_util`)
- License: MIT (see `LICENSE.zip`)
- Target: `wasm32-wasip1`
- Notes: Handles both `zip` creation and `unzip` extraction (the shell
  maps `unzip` to this module with the `-d` flag).
