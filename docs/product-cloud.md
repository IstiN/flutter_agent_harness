# External product and browser-cloud workspace (gh-2364)

This is the host contract for branded Fa workspaces and provider-neutral drive
and JSONL-session synchronization. The harness ships **no live cloud provider,
host account, backend URL, or credential**. A host supplies each capability.

## Stock compatibility

`FaProductConfig.stock` has no endpoints or cloud feature flags. Existing hosts
keep the `Fa` title, stock build, `fah_web_fs` IndexedDB database and
`flutter-app` service-worker cache. `product_config.js` ships with null values;
a branded build replaces it. `faNetwork` is not inherited by a branded profile:
it requires both an explicit feature flag and product-owned endpoints.

## Profile and static web build

A profile is external JSON, not a source-tree edit:

```json
{
  "productId": "host-product",
  "displayName": "Host Workspace",
  "description": "Host-owned workspace",
  "storageSchemaVersion": 1,
  "themePackId": "host-theme",
  "themePack": {
    "name": "Host Theme",
    "version": "1.0.0",
    "colors": {"dark": {"accent": "#2E7D32"}}
  },
  "driveAliases": ["/health"],
  "authEndpoint": "https://auth.host.example/authorize",
  "apiEndpoint": "https://api.host.example/v1",
  "driveEndpoint": "https://drive.host.example/v1",
  "sessionEndpoint": "https://sessions.host.example/v1",
  "oauthCallback": "https://app.host.example/oauth/callback",
  "defaultProviderKey": "openrouter",
  "localeStorageKey": "host_lang",
  "legalLinks": {"privacy": "https://legal.host.example/privacy"},
  "featureFlags": ["cloudSync"],
  "brandAssets": {
    "icon192": "icon-192.png",
    "icon512": "icon-512.png",
    "favicon": "favicon.png",
    "splash": "splash.png"
  }
}
```

Build from any host checkout:

```sh
dart run scripts/build_product_web.dart \
  --profile /path/to/product.json \
  --assets /path/to/assets \
  --base-href /agent/ \
  --output /path/to/output-web
```

`--validate-only` validates without building. Icons must be square PNGs at
192/512 px; `maskable192`/`maskable512` are optional and fall back to the normal
icons. Favicon and splash are required. Absolute/parent/backslash paths,
credential-shaped fields (including nested metadata), non-HTTPS endpoints
(except loopback development), malformed metadata and invalid assets fail
BEFORE Flutter runs. `--base-href` must be an absolute path ending in `/`;
invalid values also fail BEFORE Flutter runs. Output is staged and atomically
renamed only after HTML,
manifest, splash, `product_config.{js,json}`, icons and service-worker
namespaces all succeed.

`defaultProviderKey` optionally selects a built-in onboarding provider for a
branded first run. The user still completes that provider's real connection flow;
an unknown or build-filtered preset leaves the existing connection gate unchanged.
`localeStorageKey` optionally names the host's same-origin localStorage key whose
value is `ru` or `en`. An explicit `?lang=ru|en` handoff wins, then that stored
choice, then the device locale; stock behavior is unchanged.

OAuth accepts only the exact configured callback and expected non-empty state.
Storage keys use `fa-product:<id>:schema:<n>`, with a SHA-256 tenant+subject
account partition. Upgrading `storageSchemaVersion` creates a new cache; the
service worker deletes only caches under the same product root, never stock or
another product. No profile becomes executable trusted markup.

## Identity and account switching

`CloudIdentity` contains the verified immutable tenant/subject, device id and
monotonically increasing `authGeneration`; email is not accepted as a subject.
`ProductStorageCoordinator` swaps namespaces and `web/fs_store.js` closes FS,
drive and cloud-session handles. Old operations fail their generation fence and
cannot write into the newly active account.

## Drive

Hosts construct `DriveSyncEngine` with their `RemoteDriveProvider`,
`DriveSyncStore`, `ExecutionEnv`, `DriveMountScope` and `CloudIdentity`.
`IdbDriveSyncStore` is the browser CAS implementation; Memory stores support
deterministic tests. Stock never constructs the engine.

Only `/drive` and explicitly declared aliases are accepted. Unicode NFC and
case-collision keys, POSIX traversal checks and sensitive path exclusions are
in `DrivePath`; `.dap`, logs, saved keys, wallets and OAuth secrets are not
syncable. Provider quotas, cursors and idempotency keys are isolated by
provider/connection/tenant/subject/mount.

Uploads carry bytes, SHA-256, conditional base revision, auth generation and a
stable operation id. The durable outbox survives offline/restart, flushes FIFO,
replays after a post-remote/pre-CAS crash, and rejects key/payload substitution.
Precondition failures become an explicit conflict; only Keep local or Use
remote resolution permits a write. `DriveSyncController` exposes localOnly,
syncing, synced, conflict, planInactive, quotaExceeded,
providerReauthRequired and permanentError to Files/Recent surfaces. Stock Files
has no cloud row or action.

## Cloud JSONL sessions

`CloudSessionRepo` decorates the existing `SessionRepo`; local create/open/fork/
append/delete complete first. `CloudSessionStorage` queues the latest JSONL
after local writes. `CloudSessionSynchronizer` uploads complete record-id
batches with conditional revisions and idempotency keys. Revision races merge
record ids instead of comparing mtimes. Pull materializes parents before forks,
rewrites parent paths to local paths, and moves the active pointer with an
explicit sync marker. A bounded remote read failure retains local bytes and the
pending outbox. `IdbCloudSessionSyncStore` supplies browser persistence/CAS.

Local `delete()` is deliberately local-only. `closeRemoteBranch()` is the
separate explicit remote tombstone operation. `CloudSessionShareLink` accepts
only allowlisted HTTPS hosts, a stable session id, expiry, positive maxReads and
read-only capabilities; account/cache credentials and write grants are invalid.

## External-provider readiness

`CloudProviderReadiness` classifies `stub`, `mvp` (including full-scan fallback
when delta cursors are absent) and `complete`. `CloudProviderErrorMapper` maps
401/402/403/409/412/413/429/5xx and validates revision/hash/delta payloads.
`StubRemoteDriveProvider` performs no network and returns `featureDenied`.

External authors run `runRemoteDriveProviderContract` against an isolated test
account/root. It checks conditional create, same-operation replay,
key/payload-substitution rejection, stale-base conflict, download hashes and
conditional delete. The function requires `allowMutations: true` to prevent
accidental production traffic.

## Focused verification

```sh
dart test test/product test/cloud test/scripts/build_product_web_test.dart
cd flutter_app
flutter test test/boot/app_boot_test.dart test/product_config_app_test.dart \
  test/file_browser_drive_sync_test.dart test/sandbox
TZ=UTC flutter test test/goldens/files_golden_test.dart --name drive
python3 ../scripts/check_goldens.py --quick
```
