# Asset attribution

## `busybox.wasm`

This directory contains a precompiled WebAssembly build of BusyBox, used by the
example Flutter app to provide a sandboxed POSIX shell on iOS, Android, and web.

- Source repository: https://github.com/mayflower/busybox-wasm
- Downloaded release: v1.37.1
- File: `busybox.wasm`
- SHA-256: `7fc7e424188eb9edf966a74c87390b3652b726f1edec9c0e120a957127284012`

BusyBox itself is licensed under the GNU General Public License v2. The
prebuilt `.wasm` file is a separate executable asset; the surrounding
`flutter_agent_harness` package remains under the MIT license.
