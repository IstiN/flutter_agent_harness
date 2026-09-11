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
| TestFlight | `build-mobile.yml` (`ios_content=all`, `android_content=none`) | iOS IPA → TestFlight + release asset. Android stays excluded (standing owner decision). |
| pub.dev | in-job | Verifies pub.dev serves the pubspec version; if behind, runs the same dry-run gate as PR quality (#122/#128) and publishes via OIDC. Primary path stays the ci.yml tag publish job. |
| CLI + desktop | `build-macos.yml` (`create_release=true`) | macOS DMG/ZIP (signed + notarized), macOS CLI bundles, `fa-extension.zip` → GitHub Release. |
| Website | `pages.yml` | fa1.dev: landing + web demo + `/extension/` + `/outlook/` slice. |
| Outlook add-in | `office-addin.yml` | Acceptance suite (manifest validation, dart2js taskpane, Node + Playwright e2e). The fa1.dev `/outlook` deploy itself rides the Website leg — `pages.yml` assembles the same add-in into the Pages artifact. |

`workflow_dispatch` input `legs` selects a single leg (`all` by default) —
the safe way to smoke one channel.

## Versioning

The existing scheme is unchanged: `scripts/auto_release.sh` patch-bumps
`pubspec.yaml`, tags and pushes on every push to `main` (2h coalesce), and
the tag drives the ci.yml `publish`/`binaries` jobs. The daily:

- passes the **next patch tag** explicitly to `build-mobile.yml` /
  `build-macos.yml` (computed once in the `plan` job) so the mobile and
  desktop legs attach to the **same** release instead of racing two
  `version=auto` derivations into diverging tags;
- publishes to pub.dev **only when `pubspec.yaml` version > the version on
  pub.dev** (no dev/prerelease scheme — it would fight the 2h auto-release
  cadence and the ~12 publishes/day pub.dev cap).

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

No new secrets. Legs reuse each child workflow's own secrets and OIDC
(`id-token: write` for pub.dev); the orchestrator itself only needs
`github.token` with `actions`/`issues` write. Failed-step log excerpts are
taken verbatim from the child run's log — the child workflows never echo
secret values.
