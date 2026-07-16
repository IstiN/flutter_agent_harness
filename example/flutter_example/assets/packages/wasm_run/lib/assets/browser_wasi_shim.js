// Entry point injected by package:wasm_run on web.
// Mirrors vendor/wasm_run/lib/assets/browser_wasi_shim.js but imports a
// locally bundled copy of @bjorn3/browser_wasi_shim@0.2.9 so the app does
// not depend on a CDN at runtime.
import { WASI, Fd, File, Directory, OpenFile, OpenDirectory, PreopenDirectory, strace } from "./browser_wasi_shim_dist.js";
window.browser_wasi_shim = { WASI, Fd, File, Directory, OpenFile, OpenDirectory, PreopenDirectory, strace };
