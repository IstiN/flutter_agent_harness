# CI: daily auto-publish

`daily-publish.yml` is a thin orchestrator that runs the five publish
channels once a day as isolated **legs**: one leg failing never kills the
others, and every failure self-files a GitHub issue. It duplicates no build
logic — each leg dispatches an existing workflow via `gh workflow run` and
watches the run.

## Schedule and change detection

- Cron `17 5 * * *` (daily, 05:17 UTC), plus manual `workflow_dispatch`.
- Legs run only when `main` moved since the last **green** daily run
  (compared by head SHA). No movement → every leg skips → the run stays
  **green** (the #159 lesson: a no-op must never be red). A dispatch can
  override with `force: true`.
- One daily at a time (`concurrency: daily-publish`, queued, never
  cancelled).

## Legs

| Leg | Runs | Publishes |
| --- | --- | --- |
| TestFlight | `build-mobile.yml` (`ios_content=all`, `android_content=none`) | iOS IPA → TestFlight, distributed straight to the EXTERNAL group (`TESTFLIGHT_EXTERNAL_GROUP` repo variable + Beta App Review contact variables — lanes fail loudly without them). Android stays excluded (standing owner decision). |
| pub.dev | in-job | **Verifier + recovery**, never publishes directly: pub.dev trusted publishing only accepts OIDC from tag-push runs, which a schedule/dispatch run can never be. When behind, it re-runs the failed ci.yml tag-publish run (a rerun keeps the original tag-push event/OIDC claims); unrecoverable states fail loudly → issue with a manual-publish instruction. |
| CLI + desktop | `build-macos.yml` (`create_release=true`) | macOS DMG/ZIP (signed + notarized), macOS CLI bundles, `fa-extension.zip` → GitHub Release. |
| Website | `pages.yml` | fa1.dev: landing + web demo + `/extension/` + `/outlook/` slice. |
| Outlook add-in | `office-addin.yml` | Acceptance suite (manifest validation, dart2js taskpane, Node + Playwright e2e). The fa1.dev `/outlook` deploy itself rides the Website leg — `pages.yml` assembles the same add-in into the Pages artifact. |

Manual, version-by-version: `release-appstore.yml` (workflow_dispatch) submits the
version's latest processed TestFlight build straight to App Store review (iOS and/or
macOS). Pre-flight fails before any mutation — version must exist (create it via
`store-metadata.yml`), a processed build must exist, an already-submitted version is a
green no-op — and `confirm` must repeat `version` exactly. Release-after-approval stays
a manual ASC click (`APP_STORE_AUTOMATIC_RELEASE` repo variable flips it).

`workflow_dispatch` input `legs` selects a single leg (`all` by default) —
the safe way to smoke one channel.

## Versioning

The existing scheme is unchanged: `scripts/auto_release.sh` patch-bumps
`pubspec.yaml`, tags and pushes on every push to `main` (2h coalesce), and
the tag drives the ci.yml `publish`/`binaries` jobs. The daily:

- lets `build-mobile.yml` / `build-macos.yml` derive their version
  themselves (`latest tag + 1` at the child's own dispatch moment). A tag
  pinned once in the orchestrator would race `auto_release.sh` — the daily
  could attach assets to a tag minted at a different commit than the built
  code. Self-derivation keeps tag and code consistent; the two children
  derive within minutes of each other and converge on the same tag
  (`gh release create` attaches to an existing tag rather than moving it);
- never publishes to pub.dev itself (see the pub.dev row above) — pub.dev
  movement stays 100% in the auto_release → ci.yml tag job path, with the
  daily as verifier and rerun-recovery.

**Change baseline**: legs run only when `main` moved since the last green
daily **that ran all legs** (schedule runs, or `legs=all` dispatches). A
single-leg green dispatch never advances the baseline, so a partial smoke
can't make the next scheduled run skip the legs it never exercised.
A failing `plan` job (not just legs) files its own
`[daily-publish] plan leg failed` issue — nothing escapes the loop.

## Self-healing issues

On a failing (or timed-out) leg the `report` job files an issue:

- title `[daily-publish] <leg> leg failed`, label `bug` + `daily-publish`,
  assigned to `vabhzw17eg2qu4m9-bit`;
- body: daily run link, leg run link, failing job/step names, the last ~50
  lines of the failed step's log;
- **dedup**: an open issue with the same signature gets a comment instead
  of a duplicate;
- **auto-close**: when the leg goes green in a later daily run, the open
  issue is closed with a comment.

Each run also writes a single job-summary table (leg → version → status →
links) and exits red itself when any leg failed.

## Pausing

```sh
gh workflow disable daily-publish.yml -R IstiN/flutter_agent_harness
```

`enable` to resume. (Deleting the `schedule:` block from the workflow works
too.) Legs can also be paused per channel by not passing them — scheduled
runs always run all legs.

## Testing the failure path

`workflow_dispatch` input `inject_failure` fails one leg synthetically
**before anything is dispatched** — it exercises the issue-filing, dedup
and auto-close cycle with zero publish side effects:

1. dispatch `legs=pubdev force=true inject_failure=pubdev` → red, issue
   filed;
2. dispatch the same again → the existing issue gets a comment (no
   duplicate);
3. dispatch `legs=pubdev force=true` (no inject) → green up-to-date check,
   issue auto-closed.

## Secrets

No new secrets. The orchestrator never publishes anywhere itself — each
child workflow uses its own secrets/OIDC (`id-token: write` lives only in
the tag-triggered ci.yml publish job). The daily needs `github.token` with
`actions`/`issues` write (dispatch + rerun + issue filing). Failed-step
log excerpts are taken verbatim from the child run's log — the child
workflows never echo secret values.
