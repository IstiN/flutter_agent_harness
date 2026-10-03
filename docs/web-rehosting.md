# Rehosting the web SPA (`fa-web-spa.zip`)

Every [release](https://github.com/IstiN/flutter_agent_harness/releases) ships
**`fa-web-spa.zip`** — the release Flutter web build with `<base href>`
rewritten to `./`, so it runs from **any static host with zero edits**,
including path-prefixed hosts (`https://host/some/prefix/`) and sandboxed
iframes. The bundle is built with the same command and the same pinned
Flutter SDK as the deploy that powers [fa1.dev](https://fa1.dev/app/)
(`--release --base-href /app/` on Flutter 3.47.x in both workflows; a static
guard asserts both invocations keep these, so the bundle's only edit stays
the base tag). The release pipeline enforces the deeper
invariant too: `scripts/package_web_spa.sh` fails the release unless the
four entry files (`index.html`, `flutter_service_worker.js`,
`flutter_bootstrap.js`, `manifest.json`) contain zero absolute `/app/`
references after the patch.

## Upload (read this first)

**Upload ALL files from the zip, preserving the directory structure.**
Partial uploads are the #1 failure mode: hosts that auth-redirect missing
paths to an SSO page (observed on onehub) surface the missing file as a
misleading CORS error instead of a 404, and the app dies at boot. The bundle
is self-contained — `index.html`, `flutter_bootstrap.js`, `main.dart.js`,
`manifest.json`, `canvaskit/`, `assets/` — and every file is fetched relative
to the page URL, so the directory you upload to IS the app root.

### Hosting requirements

| Type | Required MIME | Symptom when wrong |
|------|---------------|--------------------|
| `.js`  | `application/javascript` | Script refused / blocked by nosniff |
| `.wasm` | `application/wasm` | CanvasKit fails to instantiate — blank page |
| `.json` | `application/json` | Asset fetch errors |

If your host guesses MIME by extension, verify `.wasm` specifically — several
default configs serve it as `application/octet-stream`, which fails the
CanvasKit bootstrap.

### Routing (pinned fact)

This build uses Flutter's default **path** URL strategy (the app only swaps to
a no-op strategy inside sandboxed iframes / the Office pane — see
`flutter_app/lib/services/web/sandbox_url_strategy.dart`). Consequences:

- Serving the bundle at a mount point and using the app from there works on
  plain static hosting with no extra config.
- **Deep links** (`<mount>/session/123`) require a SPA rewrite to
  `index.html`. nginx:

  ```nginx
  location /your/prefix/ {
      try_files $uri $uri/ /your/prefix/index.html;
  }
  ```

  Caddy: `try_files {path} /index.html` inside the site block. If your host
  cannot rewrite, every route other than the mount point will 404.

### Embedding in an iframe

Verified-working minimal attribute set (2026-09-30, path-prefixed corporate
host) — use verbatim:

```html
<iframe
    src="https://your.host/prefix/index.html"
    sandbox="allow-scripts allow-same-origin allow-forms allow-modals allow-popups allow-downloads"
    allow="clipboard-write; clipboard-read; geolocation; fullscreen">
</iframe>
```

In stricter sandboxes (`allow-same-origin` dropped) the app auto-detects the
stripped History API and falls back to a no-op URL strategy, but storage and
some APIs degrade — the set above is the tested contract.

## How the bundle is built

The release pipeline (`.github/workflows/ci.yml`, `web-spa` job) runs the same
`flutter build web --release --base-href /app/` as the Pages deploy, then
`scripts/package_web_spa.sh` copies the output, rewrites `<base href="/app/">`
to `<base href="./">`, asserts no absolute `/app/` references remain in
`index.html` / `flutter_service_worker.js` / `flutter_bootstrap.js` /
`manifest.json`, and zips. The Pages deploy itself is untouched.
