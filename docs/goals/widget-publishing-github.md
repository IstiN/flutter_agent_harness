## Goal — Widget publishing to the fa_widgets catalog via GitHub (v1)

One sentence: **a widget the user built in Fa becomes a published catalog widget through a one-tap "Publish" flow** — connect GitHub once, the app pushes the widget to the user's own repo and opens a PR in `IstiN/fa_widgets`; the PR's status and review comments stay visible in the app until merge.

Today widgets made in Fa live only in the local sandbox (`apps/<id>/`); sharing means copying files by hand. This card automates the entire path the user described: the app drives the GitHub API (no CLI, works in the iOS sandbox), creates a public repo under the connected account, commits the widget sources, forks `fa_widgets`, pins the user's repo as an external submodule, opens the PR, and tracks it to publication. Maintainer review/merge stays the gate to the rolling release; after merge the catalog auto-update flows already carry the widget to everyone's board.

## Why this framing

- The subject of every action is **the widget's source files** (`manifest.json`, `widget.js`, `icon.svg`, assets) in the app sandbox — not the agent session, not the storage, not the tile layout. Nothing else is published.
- The user-visible repo belongs to the USER's account: their token, their repo, their PR authorship. The app never touches `IstiN/fa_widgets` directly with a bot token — the fork-and-PR flow is the only write path, keeping the maintainer's merge as the single publication gate.
- The Copilot connect mechanism (GitHub device flow, RFC 8628) is reused as the AUTHENTICATION pattern, but the token for publishing needs `public_repo` scope — a separate connection, stored separately (see Secrets).

## Architecture

Named components (all new code is pure Dart; `package:http` behind an injectable client — no `gh` CLI, works in the App-Store sandbox):

```
Fa app
 ├─ GithubConnectFlow        device-flow sheet (reuses copilot_device_flow
 │                            requestCopilotDeviceCode/pollCopilotAccessToken/
 │                            fetchGithubLogin with a Fa-specific clientId)
 │                            + PAT paste fallback
 ├─ GithubAccountStore       token+login persistence (Keychain → saved-keys
 │                            fallback), connect/disconnect, redactor
 │                            registration
 ├─ GithubApiClient          REST v3: /user, repos (create), git
 │                            blobs/trees/commits/refs, forks, pulls,
 │                            PR state + issue/review comments
 ├─ WidgetPublishService     publish orchestration: pre-flight validation →
 │                            user repo (create-or-update) → commit sources →
 │                            fork fa_widgets → branch + external submodule
 │                            pin + overlay → open PR → record submission
 └─ WidgetPublicationStore   submissions ledger (widget_publications.json in
                             the env), status poller, comments surfacing

fa_widgets repo (tooling change)
 └─ validator/catalog: EXTERNAL widget kind — widgets/<id>/overlay.json with
    source {repo, commit} + gitlink vendor/external/<id> @ <user repo sha>
    (same single-source-of-truth rule as the CORE submodule, generalized to
    N user repos)
```

Invariants:

- **Zero GitHub tokens outside the app process.** The token is read from Keychain into memory, sent only to `api.github.com` over HTTPS, never written into any file, log, session, or agent context (registered in the session `SecretRedactor` on connect).
- **The app writes only to the user's own repositories and their fork.** Publication into the catalog happens exclusively via a merged PR reviewed by the maintainer; no release/trigger credentials exist in the app.
- **User widget repos are PUBLIC** — a hard requirement: the catalog CI clones external submodules anonymously. The publish flow creates repos with `private: false` and pre-flight-fails on a private existing repo.
- **CI never executes widget JS.** Validation/packaging is static (schema + size + structure); the JS engine runs only inside the app's pre-flight smoke test.
- Boot never blocks on GitHub: all network happens on explicit user action or background status polling (5 min cadence while the publications view is open, otherwise on app resume).

## Capability surface (what GitHub + the app allow → our shape)

| Platform capability | Our use | Tier |
|---|---|---|
| OAuth device flow (RFC 8628) | Primary connect path — "Fa Widgets" OAuth App client id, scope `public_repo` | core |
| PAT paste (classic, `public_repo`) | Fallback connect path — works day one, before the OAuth App exists | core |
| `GET /user` | login/avatar for the settings row + pre-flight sanity | core |
| `POST /user/repos` | create the widget repo (public) | core |
| git data API (blobs/trees/commits/refs) | commit widget sources; create the gitlink (mode 160000) + `.gitmodules` + overlay in the fa_widgets fork | core |
| `POST /repos/IstiN/fa_widgets/forks` | user's fork (idempotent — reuse existing) | core |
| `POST /repos/IstiN/fa_widgets/pulls` | the publication PR | core |
| `GET .../pulls/<n>`, issue comments, review comments | status + reviewer feedback surfaced in-app | core |
| Repo update/delete, collaborators, releases on the user's repo | **future** "work with my repositories" — out of scope here | second tier |
| Private user repos, `repo` scope, GHE endpoints | excluded — public-only by design (submodule anonymity); GHE has no catalog to publish into | excluded |
| Publishing from the CLI (`fa`) | excluded in v1 — the app is the surface; the same service classes are host-agnostic so a CLI front can come later | second tier |

### Connect GitHub (settings)

Settings gains a "GitHub account" section: connected login + avatar, Connect/Disconnect. The device-flow sheet shows the user code, opens `github.com/login/device`, polls until granted; PAT paste is the explicit fallback tab. Web build: device flow is impossible (github.com serves no CORS headers) and PAT paste still works — the sheet says so plainly instead of failing mid-flow. Disconnect removes the Keychain entry, the saved-keys fallback, and the redactor registration; in-flight submissions keep their PRs (server-side) but lose status polling until reconnect.

### Publish flow (long-press a widget → Publish)

Entry points: the launcher tile menu and the apps-panel long-press menu gain "Publish…" for **user-created widgets only** (bundled demos and catalog downloads are excluded — they are already in the catalog). The flow:

1. Pre-flight: manifest schema (id == folder name, semver, permissions declared), `widget.js` boots in a sandboxed engine smoke test, icon present, size within catalog limits. Failures are listed in the sheet with the fix hint — no half-published widgets.
2. Repo step: the user names the repo (default `fa-widget-<id>`); create-or-update under the connected account; sources committed to `main`.
3. PR step: fork `IstiN/fa_widgets` (reuse if it exists), branch `publish/<id>-<version>`, commit adding `widgets/<id>/overlay.json` (meta + `source: {repo, commit}`) and the gitlink `vendor/external/<id>` pinned to the pushed commit, open the PR with the widget's description/screenshots reference.
4. The submission lands in the publications ledger.

### Status & comments

A "My publications" view (from the widgets catalog sheet and the settings GitHub section) lists each submission: PR state (open / merged = **published** / closed = **rejected**), labels, CI check rollup, and the latest review/issue comments with author + timestamp. Pull-to-refresh + timed polling; deep link opens the PR in the browser.

## Sharing & secrets design

- Token at rest: Keychain entry `FA_KEY_GITHUB` (iOS/macOS, `AfterFirstUnlockThisDeviceOnly`) → fallback: saved-keys store (same file store the agent keys use). Never in `storage.json`, never in sessions, never in analytics.
- Token in flight: `Authorization: Bearer` to `api.github.com` only; the host allowlist is literal, not suffix-matched.
- Redaction: on connect the token registers in the session `SecretRedactor`, so any accidental appearance in agent transcripts is masked.
- Rotation: connect-again overwrites the same entry; every surface reads through `GithubAccountStore`, so the new value propagates without restart.
- Tests assert ABSENCE: serialized session files, analytics events, and AppLog lines are byte-scanned for the token in IT-*.

## Security (external-content threat model)

Attacker-controlled inputs: the widget's own JS (user-authored, but executed ONLY in the app's sandboxed engine during pre-flight — never in CI), GitHub API responses (login names, PR titles, comment bodies rendered as text), and repo names the user types.

- Repo names are sanitized to GitHub's rules (`[A-Za-z0-9._-]`, ≤100) client-side AND validated against the API error path; no shell anywhere in the pipeline (pure REST), so injection has no sink.
- Comment bodies render as plain text (no markdown image loading) — an attacker comment cannot exfiltrate via remote resources.
- The PR body is fixed-template + widget metadata; free-text user input is escaped into code blocks.
- Instruction hierarchy: PR comments NEVER drive app behavior — they are display-only data. The agent must not read them as commands (they never enter agent context).
- The maintainer's merge is the boundary: **app-side automation is plumbing; review is the gate.**

## Acceptance criteria (testable)

- **AC1** — Connect persists the GitHub account (login visible in Settings after restart); disconnect removes it everywhere (`GithubAccountStore` + Keychain + redactor). *(IT-1, REG-1)*
- **AC2** — Device flow works end-to-end against a fake GitHub: code shown, polling respects `interval` + `slow_down`, token lands in the store. *(IT-2)*
- **AC3** — PAT path stores and validates the token (`GET /user`), with an actionable error on a bad/expired token. *(IT-3)*
- **AC4** — Publish from the tile menu creates/updates the user repo with exactly the sandbox widget files (byte-for-byte, assets included), public visibility enforced. *(IT-4, UT-1)*
- **AC5** — Publish opens ONE PR in `IstiN/fa_widgets`: fork reused when present, branch `publish/<id>-<version>`, gitlink pinned to the pushed commit, overlay schema valid per the extended validator. *(IT-5, IT-6, fa_widgets UT)*
- **AC6** — Re-publishing a widget updates the same repo and the open PR (no duplicate PRs); a closed-but-unmerged PR forces a fresh branch. *(IT-7)*
- **AC7** — The publications view shows state transitions open → merged/closed plus reviewer comments, from the ledger + live polling. *(IT-8, UT-2)*
- **AC8** — Offline/disconnected flows degrade cleanly: publish requires a connected account (sheet opens connect), status polling shows last-known + "offline". *(IT-9)*
- **AC9** — The token never appears in session files, logs, or analytics payloads (byte-scan). *(IT-10)*
- **AC10** — Web build: device flow disabled with a clear message, PAT path works; iOS/desktop device flow works without any callback server. *(REG-2, manual)*
- **AC11** — fa_widgets validator accepts the EXTERNAL kind (overlay `source` + gitlink pinned commit) and rejects drift (overlay source ≠ gitlink sha). *(fa_widgets UT + validator)*
- **AC12** — A published widget (merged PR) appears in the rolling release catalog and auto-updates onto boards (existing auto-update path; verified manually on a test PR).

## Test plan

### Test matrix

- **UT-1** widget-file packaging (manifest normalization, asset enumeration, path safety — no `..`, no absolute paths). Pure Dart, MemoryExecutionEnv. *(AC4)*
- **UT-2** `WidgetPublicationStore` ledger round-trip + status projection. *(AC7)*
- **IT-1..10** against `http.testing.MockClient` scripted GitHub API (device-flow poll sequences incl. `authorization_pending`/`slow_down`/`expired_token`; fork-already-exists 422; PR-number capture; comments pagination; 401 → re-auth prompt). Deterministic clocks for the poller. *(AC1–AC9)*
- **fa_widgets UT** — validator/catalog-builder cases for the EXTERNAL kind + drift rejection. *(AC11)*
- **E2E-1** (manual, token-scoped): real publish of a scratch widget into a test account, PR visible, merge → catalog → board auto-update. *(AC12)*
- **REG-1** flutter_app suite: settings/panel/launcher goldens unchanged except the two menu additions; the existing Copilot connect flow untouched (its tests run through the same device-flow code with the Copilot client id). *(AC1)*
- **REG-2** web build compiles and runs the PAT path (CI web build job). *(AC10)*
- **REG-3** fa_widgets CI: existing VENDORED/LOCAL widgets still validate identically (the EXTERNAL kind is additive; the CORE submodule pin behavior unchanged). A red REG job blocks merge even when IT/E2E are green.

### Edge / border cases

- **E1** — Token revoked mid-session: next API call gets 401 → the account row flips to "reconnect required", in-flight publish aborts before any repo write.
- **E2** — Rate limit (403 + `X-RateLimit-Remaining: 0`): status polling backs off to the reset timestamp; publish surfaces the wait.
- **E3** — Repo name taken by an unrelated repo (not ours): the flow asks for a different name instead of pushing into a foreign repo (provenance check: repo description marker `fa-widget:<id>` + empty-or-ours tree).
- **E4** — Widget folder >5 MiB or >100 files: pre-flight fails with the catalog limits (same numbers the fa_widgets validator enforces).
- **E5** — Duplicate `id` already in the catalog (published by someone else): pre-flight fails naming the conflict; the user renames the widget id.
- **E6** — `slow_down` storm / device code expired: poller honors penalties and stops at `expires_in` with a restart affordance.
- **E7** — App killed mid-publish: the ledger records the step reached (repo-pushed / PR-opened) so the next launch resumes at the PR step instead of duplicating work.
- **E8** — User deletes their repo after the PR opened: the publications view marks the PR "source deleted" (404 on the repo) and offers re-publish.
- **E9** — PR merged → repo deletion is OFFERED (not automatic): the catalog no longer needs the user repo after merge (sources were zipped at merge time), but deleting is the user's call.
- **E10** — Two widgets with the same id in different sandboxes: the ledger is user-scoped; the second publish warns and requires explicit overwrite of the repo content.

## Non-goals

- No bot/maintainer token, no auto-merge, no direct writes to `IstiN/fa_widgets` — review stays human.
- No generic "browse my GitHub repos" UI (the stated future direction; the `GithubApiClient` is shaped so it drops in later).
- No CLI publish path in v1; no GitHub Actions authoring in the user's repo.
- No changes to how widgets run, render, or sync (the state-sync protocol is orthogonal and already shipped).
- The hardcoded "Focus Timer" demo in the apps panel stays out of this card.

## Open questions

None blocking. Owner action required outside the code: **register the "Fa Widgets" OAuth App** (GitHub → Developer settings → OAuth Apps, enable Device Flow) and hand the client id into the build config (`FA_GITHUB_CLIENT_ID` dart-define / settings entry). Until it exists, the PAT path (AC3) is the primary connect flow — the device flow lights up the moment the id is configured.

## References

- Device flow reuse: `lib/src/providers/copilot_device_flow.dart` (parametrized `clientId`/`scope`), `flutter_app/lib/services/copilot_connect_flow.dart`, `packages/fa_ui/lib/src/providers/copilot_connect_sheet.dart`.
- Token persistence pattern: `FA_KEY_COPILOT_<NAME>` in `KeychainStore` (`packages/fa_ui/lib/src/stores/keychain_store.dart`) + `SessionKeysStore` fallback.
- Entry points: `_showTileMenu` (`flutter_app/lib/ui/screens/app_launcher_screen.dart`), `_showAppMenu` (`flutter_app/lib/ui/widgets/apps_panel.dart`).
- Catalog rules: `fa_widgets` repo — `lib/src/validator.dart` (LOCAL vs VENDORED), `docs/schema.md`, `CONTRIBUTING.md`.
- Widget state-sync (shipped): `fa_widgets/docs/state-sync.md`, flutter_agent_harness `d9c7f2b4`/`f4159fad`.
