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

## python.wasm

- Source: https://github.com/brettcannon/cpython-wasi-build (official CPython
  WASI builds, Python 3.14.6, wasi-sdk 24)
- License: PSF-2.0 (see `LICENSE.python`)
- Target: `wasm32-wasip1`
- Notes: CPython interpreter. The standard library ships separately as
  `python_stdlib.zip` (contents of `lib/python3.14` from the same release)
  and is extracted to `/usr/local/lib` inside the sandbox on first use.
  The `pip` builtin (pure Dart, see `lib/sandbox_pip.dart`) installs
  pure-Python wheels from PyPI into
  `/usr/local/lib/python3.14/site-packages`, which is exported to the
  interpreter as `PYTHONPATH`.

## python_stdlib.zip

- Source: `lib/python3.14` from the same cpython-wasi-build release
- License: PSF-2.0 (see `LICENSE.python`)

## qjs.wasm

- Source: https://github.com/quickjs-ng/quickjs (v0.15.1, official
  `qjs-wasi.wasm` release artifact)
- License: MIT (see `LICENSE.quickjs`)
- Target: `wasm32-wasip1`
- Notes: QuickJS JavaScript engine (ES2023) with `qjs:std`/`qjs:os`
  builtin modules. Mapped to the `qjs` and `js` shell commands.

## sqlite3.wasm

- Source: https://sqlite.org (SQLite 3.53.3 amalgamation), built locally
  with wasi-sdk 33 (clang --target=wasm32-wasip1, THREADSAFE=0,
  OMIT_LOAD_EXTENSION, ENABLE_MATH_FUNCTIONS)
- License: public domain (SQLite is not licensed)
- Target: `wasm32-wasip1`
- Notes: sqlite3 CLI; `system()` stubbed (no process spawning under WASI).

## lua.wasm

- Source: https://github.com/yuin/gopher-lua (v1.1.1), built locally with
  Go 1.25 (`GOOS=wasip1 GOARCH=wasm go build -ldflags="-s -w"`) plus a small
  CLI wrapper mirroring the PUC lua standalone (`-v`, `-e`, `--`, script file
  with the `arg` table, `-` = stdin, `lua: <err>` on stderr with exit 1).
- License: MIT (see `LICENSE.lua`)
- Target: `wasm32-wasip1`
- Notes: Lua 5.1-compatible interpreter (`_VERSION` is `Lua 5.1`). This is
  NOT the stock PUC-Rio C implementation: stock Lua handles errors
  (pcall/error) with setjmp/longjmp, which wasi-sdk 33 can only lower to
  WebAssembly exception-handling instructions (`-mllvm -wasm-enable-sjlj`
  + libsetjmp.a). The runtime embedded in the app (wasmi 0.31, see
  `vendor/wasm_run_flutter`) rejects such modules ("exceptions proposal not
  enabled"), so a C build was verified to compile but cannot run in-app.
  gopher-lua implements the VM in pure Go — no setjmp — and runs under the
  sandbox unchanged. Under WASI `os.execute` reports failure (1) and
  `io.popen` returns nil plus "Not implemented on wasip1" — process
  spawning is impossible, but neither call crashes the runtime.

## Browser interpreters (web build, loaded from CDN at runtime)

- quickjs-emscripten 0.31.0 (MIT) — https://github.com/justjavac/quickjs-emscripten
  Loaded from jsdelivr on first `qjs`/`js` invocation in the browser.
- pyodide 0.26.4 (MPL-2.0) — https://pyodide.org
  Loaded from jsdelivr on first `python`/`python3` invocation in the browser.
- sql.js 1.14.1 (MIT) — https://github.com/sql-js/sql.js
  SQLite compiled to WebAssembly. Loaded from jsdelivr (`sql-wasm.js` +
  `sql-wasm.wasm`) on first `sqlite3` invocation in the browser; the
  database is exported back into the sandbox filesystem after each run.

## On-device LLM runtime (web build, loaded from CDN at runtime)

- @mlc-ai/web-llm 0.2.81 (Apache-2.0) — https://github.com/mlc-ai/web-llm
  Imported as an ES module from jsdelivr by `web/index.html` (exposed as
  `window.webllm`) when the "On-device (WebLLM)" provider is selected.
  Model weights download from HuggingFace (`mlc-ai/` org) into the
  browser's CacheStorage on first use; model libraries come from
  https://github.com/mlc-ai/binary-mlc-llm-libs. Nothing is bundled into
  the app; the stream helper is `web/webllm_helpers.js`.

## Pure-Dart packages (web sandbox shell)

- package:archive (MIT) — https://pub.dev/packages/archive
  Backs the `tar`/`gzip`/`gunzip`/`zip`/`unzip` commands of the pure-Dart
  web shell (`MemoryShell`). Fetched by pub as a normal dependency; nothing
  is bundled as an asset.
