# Commits and releases

> Moved verbatim from `AGENTS.md` (gh-2181 — the slim-AGENTS.md card). Canonical reference; the slim AGENTS.md carries the one-line summary and points here.

## Commits and releases

- Commit identity: human/AI contributors commit as `ai.teammate
  <agent.ai.native@gmail.com>` (history was rewritten to it — set
  `git config user.name ai.teammate` + `git config user.email
  agent.ai.native@gmail.com` repo-locally). Release TAGS from
  `scripts/auto_release.sh` are authored `fa-release-bot[bot]
  <fa-release-bot[bot]@users.noreply.github.com>` — the gh-1172 App pushes
  the annotated tag, so the App identity is what auditability hangs on.
  gh-1402 rule: ANY automation that commits/pushes release-path changes
  (store metadata fixes, release tags/releases) MUST use the fa-release-bot
  GitHub App token — never a PAT, never the default `GITHUB_TOKEN`
  (main's required status checks reject both, #1098).
- Commit subjects: `type(scope): ...` (`feat:`, `fix:`, `fix(example):`,
  `ci:`, `test(providers):`, `refactor(prompts):`).
- Every push to `main` cuts an annotated TAG (`scripts/auto_release.sh`
  via `ci.yml`) — ZERO commits land on main (gh-1522: the retired flow
  pushed a 4-file `chore(release):` bot commit per release). gh-1801: NO
  GitHub Release is created at tag-cut time (an asset-less create
  published an empty `latest` that broke `fa update`): the tag-run
  `binaries` job creates the release DRAFT-first via
  `scripts/release_lazy_draft.sh` (curated CHANGELOG notes via
  `release_notes.sh` + a `release-draft-owner` marker), every leg attaches
  into it, and `release-provenance` publishes + flags `latest` ONLY after
  the signed SHA256SUMS(.sig) is attached — `latest` never points at a
  release that cannot serve `fa update`. The git TAG is the single source
  of truth for versions:
  both pubspecs carry the FIXED `0.0.0-dev` placeholder (a hand-bump fails
  the Static `Version placeholder guard`), `pubspec.lock` never churns, and
  CI stamps the version at the edges: the `publish` job stamps the STAGED
  publish tree (pubspec version + generated changelog section prepend via
  `scripts/stamp_staged_release.sh`, staged version == tag guarded
  pre-upload), store/mobile builds stamp `--build-name/--build-number` from
  the derived tag version, `install_local.sh` stamps `version.txt` from
  `git describe`. CHANGELOG.md is curated-only: PRs add lines under
  `## Unreleased`; the release folds it into the tag's section AT STAGE
  TIME (`scripts/release_notes.sh` preference order: curated `## <version>`
  section → curated `## Unreleased` body → conventional commits since the
  previous tag). The version scheme is `1.0.<counter>` (gh-785: App Store
  Connect approved 1.0.0 and enforces a monotonic
  `CFBundleShortVersionString`, so the pre-promotion `0.1.<counter>`
  train can never upload again). Release checklist: push to main (or the
  `releaseDispatch` dispatch) → watch the ci.yml `release` job cut the tag
  → watch the tag-scoped `publish` + `binaries` + `release-provenance`
  jobs (the release publishes at the provenance step). `fa --version` reads
  the stamped `version.txt` first, the placeholder pubspec second.
- `packages/fa_llm` publishes per `fa_llm-v*` tag via
  `.github/workflows/publish-fa-llm.yml` (OIDC, no secrets). First
  publish of a NEW package is manual — pub.dev OIDC only uploads new
  versions of an existing package (issue #1511): owner runs
  `cd packages/fa_llm && dart pub publish` once, adds the OIDC publisher
  entry on pub.dev, then the workflow takes over. The workflow
  pre-flights the package-exists probe and exits 10 with the
  instructions on 404; see `packages/fa_llm/README.md` §Publishing.
- CLI binaries build per tag (`ci.yml` `binaries` job), attach to the
  GitHub Release (`fa-<os>-<arch>[.exe]`); `installer-smoke` verifies
  installers.
- App builds (`build-mobile.yml`, `build-macos.yml`, manual dispatch):
  Android AAB + iOS IPA on `[self-hosted, macOS, ARM64]`, macOS DMG/ZIP
  signed + notarized, TestFlight via `flutter_app/fastlane`. build-macos.yml
  also packages a NON-sandboxed Fa.app DMG/ZIP per arch
  (`fa-macos-nosandbox-<arch>-<version>.dmg`, #2132): hardened-runtime-only
  entitlements pinned in `flutter_app/macos/Runner/ReleaseNoSandbox.entitlements`
  (+ Debug twin, exactly {cs.allow-jit, network.client, network.server} —
  test-pinned) and wired as the `ReleaseNoSandbox` Xcode configuration;
  `build_macos_nosandbox.sh` prunes before its re-sign (sealed tree) and
  asserts the signed entitlement set; the DMG is notarized + stapled by the
  same signed-path-gated step shape as the sandboxed DMG and rides the
  release attach path with the other DMGs (excluded from the auto-update
  stable names — the sandboxed build stays the default update feed).
  Optional
  secrets: `APP_STORE_CONNECT_KEY_ID/_ISSUER_ID/_KEY_CONTENT`,
  `MACOS_INSTALLER_P12_BASE64/_PASSWORD/MACOS_INSTALLER_CERT_ID`,
  `GOOGLE_SERVICE_INFO_PLIST_BASE64`. Both workflows hard-gate the binary
  on wasm_run FFI exports (`xcrun dyld_info -exports` must list
  `_wire_compile_wasm` — Podfiles force-load + `-exported_symbol` +
  `STRIP_STYLE=non-global`, else white screen on TestFlight). Pods cached
  keyed by `Podfile.lock`. The gate proves FFI exports ONLY — a Dart boot
  crash before the first frame white-screens TestFlight with a green gate
  (issue #544: build 160, boot refactor created the platform env before
  `WidgetsFlutterBinding.ensureInitialized`); boot stage order is pinned by
  `flutter_app/test/boot/app_boot_test.dart`.
- Lockfile policy (gh-1296 NG1): EVERY lockfile is committed and enforced —
  one inventory list in `scripts/check_lockfiles.sh` (7 files:
  `flutter_app/pubspec.lock`, `ios/Podfile.lock`, `macos/Podfile.lock`,
  the vendored `flutter_inappwebview_macos` `Package.resolved`, both e2e
  `package-lock.json`s, and `vendor/wasm_run/native/Cargo.lock`); a listed
  lockfile that is missing/untracked/gitignored fails the Static gates, and
  pod-sync (flutter-analyze + nightly build legs, after `pub get`) fails
  when a native iOS/macOS plugin resolved by pubspec.lock has no pod in the
  platform's `Podfile.lock` (the gh-1274 class), or its pod is pinned at a
  stale version vs the resolved plugin podspec's `s.version` (the
  historical flutter_gemma 1.8.0-vs-1.11.3 skew; the podspec is the comparison target,
  not the pubspec version — vendored/beta pods legitimately differ from the
  Dart package version). The inventory also enforces the gh-1303 path-pin
  sync: `flutter_app/pubspec.lock` pins this repo as a path dependency, so
  its `flutter_agent_harness` pin must EXIST and equal the root
  `pubspec.yaml` version — a stale OR MISSING pin (e.g. a merge conflict
  resolved by dropping the entry) makes every
  `flutter pub get --enforce-lockfile` consumer red — the pins are
  `0.0.0-dev` on both sides and NEVER churn across releases (gh-1522: the
  tag is the version; the release flow mutates zero files), and the Static
  gate catches any other path to the drift at PR time. After ANY pubspec.yaml
  dependency change that adds/updates a darwin-native plugin: `cd
  flutter_app/ios && pod install --repo-update` and the same in `macos/`,
  commit both `Podfile.lock`s (CocoaPods runs fine on Linux for
  regeneration; the wasm_run `nm` step needs an llvm-nm shim + the
  XCFramework staged via `scripts/setup_vendor_ios.sh` or the upstream zip).
  Guard red exits are fixture-self-tested (`scripts/
  check_lockfiles_selftest.sh`, Static gates).
- TestFlight external distribution (issue #239): the `submit_only` lanes
  (driven by build-mobile.yml / build-macos.yml) distribute every build
  straight to the EXTERNAL group — REQUIRED repo variables
  `TESTFLIGHT_EXTERNAL_GROUP`, `BETA_REVIEW_CONTACT_EMAIL`,
  `BETA_REVIEW_CONTACT_PHONE`, `BETA_APP_FEEDBACK_EMAIL` (lanes fail loudly
  at start without them). Pilot must WAIT for processing (skipping the wait
  silently skips distribution); `verify_external_distribution!` asserts
  group membership bounded — beta-review-pending is a neutral notice, a
  build never reaching the group fails the leg (self-filed issue).
- Manual App Store review: `release-appstore.yml` (workflow_dispatch:
  `version` + `platforms` ios/macos/both + `confirm` repeating the version)
  runs the `submit_for_review` lanes — pure pre-flight in
  `flutter_app/fastlane/appstore_preflight.rb` (plain-ruby tested) fails
  BEFORE any mutation; already-submitted versions are a green no-op;
  release-after-approval stays a manual ASC click
  (`APP_STORE_AUTOMATIC_RELEASE` repo variable flips it, E5). Grep-guards:
  `test/store_automation_guard_test.dart`.
- App Store content pipeline (no binary): store screenshots are COMMITTED
  goldens from `flutter_app/test/golden/store_screenshots_test.dart` (frame +
  inline en/ru copy in `store_marketing_frame.dart`) at
  `flutter_app/test/goldens/store/{en,ru}/{ios,ipad,mac}/` — regenerate with
  `flutter test test/golden/store_screenshots_test.dart --update-goldens`,
  then open every PNG. Store copy lives in
  `flutter_app/fastlane/metadata/{ios,macos}/{en-US,ru-RU}/` (the lanes strip
  name.txt/subtitle.txt — App Info is not editable post-release); release
  notes come from the latest `## […]` section of
  `store_artefacts/metadata/{en,ru}/changelog.md`. Upload: `fastlane ios
  app_store` / `fastlane mac app_store` in `flutter_app` (env gates
  `IOS_DEPLOY_METADATA`/`IOS_DEPLOY_SCREENSHOTS`/`MACOS_DEPLOY_*`; ASC API key
  env secrets) or the `store-metadata.yml` workflow (`ios_content`/
  `macos_content` inputs: none/metadata_only/screenshots_only/all).
- Google Play listing pipeline (issue #289, no binary): the Play Console
  image rules are repo tests. Listing screenshots are the same story frames
  as COMMITTED GOLDENS straight into the supply tree
  (`fastlane/metadata/android/{en-US,ru-RU}/images/`): phone 1080×1920
  (exact 9:16, en+ru), 10-inch 1440×2560 (exact 9:16 — 1600×2560 is 10:16
  and Play rejects it; en only, ru falls back to phone shots), regenerated
  with `flutter test test/golden/store_screenshots_test.dart
  --update-goldens` then `git checkout -- test/goldens/store` (the run also
  refreshes the App Store goldens on a non-canonical host — restore them);
  the feature graphic (1024×500) is a widget golden in
  `test/golden/play_store_assets_test.dart`; the icon is the iOS master
  resized by `tool/generate_android_adaptive_icons.dart` (512×512, mirrored
  byte-identical to ru-RU). Sizes/aspects/file caps are enforced by
  `flutter_app/test/play_store_listing_guard_test.dart`. Listing texts
  (title ≤30, short_description ≤80, full_description) live in
  `fastlane/metadata/android/{en-US,ru-RU}/`. Upload: `fastlane android
  play_store` in `flutter_app` (env gates `PLAY_DEPLOY_METADATA`/
  `PLAY_DEPLOY_IMAGES`, `PLAY_VALIDATE_ONLY=1` dry-run; Play service-account
  secret `PLAY_STORE_SERVICE_ACCOUNT_JSON`) or the `store-metadata.yml`
  android leg (`android_content`: none/metadata_only/images_only/all). Images
  never ride supply (it only APPENDS uploads — issue #947): the `play_store`
  lane pushes them through `play_listing_sync.rb`, which replaces the whole
  image set per locale + device type (dropped sets are cleared) and verifies
  the committed goldens against `edits.images.list`. The daily
  `daily-publish.yml` play leg dispatches `build-mobile.yml` with
  `android_content=all`, so every release train redeploys the listing.

