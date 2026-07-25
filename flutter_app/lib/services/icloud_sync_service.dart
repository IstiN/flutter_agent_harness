// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

export 'package:fa/services/icloud_sync_service_stub.dart'
    if (dart.library.io) 'package:fa/services/icloud_sync_service_io.dart';

/// Name of the env-side state file ([ICloudSyncService.syncNow] rewrites it
/// after every run): `{"lastSyncMs": …, "filesCopied": …, "bytesCopied": …}`.
const icloudSyncStateFile = 'icloud_sync.json';

/// Outcome of one [ICloudSyncService.syncNow] run: how many files (and
/// bytes) were copied in either direction, and when the run finished.
typedef ICloudSyncReport = ({
  int filesCopied,
  int bytesCopied,
  DateTime syncedAt,
});

/// Syncs the sandbox's `sessions/` and `apps/` trees with the app's iCloud
/// Drive ubiquity container (`<container>/Documents/FaSync/{sessions,apps}`)
/// so they follow the user across devices.
///
/// The channel reports `containerUrl == null` (→ unavailable) unless the
/// app is signed with a provisioning profile that carries the iCloud
/// capability. iOS ships the entitlements in `ios/Runner/Runner.
/// entitlements`; macOS deliberately does NOT (the
/// `com.apple.developer.icloud-services` / `ubiquity-containers` keys make
/// `flutter build macos --debug` fail — "entitlements require signing with
/// a development certificate" — for ad-hoc-signed local builds, and build
/// integrity wins). To enable the container on a signed build:
///
/// 1. Apple Developer portal → Certificates, Identifiers & Profiles →
///    Identifiers → `dev.fa1.app` → enable **iCloud** (iCloud Documents).
/// 2. Identifiers → iCloud Containers → create `iCloud.dev.fa1.app` and
///    assign it to the App ID's iCloud capability.
/// 3. Regenerate the provisioning profiles so they pick up the capability.
/// 4. macOS only: re-add the two entitlement keys (see the iOS file) to
///    `macos/Runner/DebugProfile.entitlements` and `Release.entitlements`.
///
/// v1 semantics — manual trigger only (no background sync), a file-level
/// two-way merge with **last-write-wins by file mtime**: a file present on
/// both sides copies the newer-mtime version over the older one; a file
/// present on one side only copies to the other. Deletions are NOT
/// propagated (a file deleted on one device comes back from the other on
/// the next sync) — conflict handling is deliberately dumb until a real
/// need shows up. Two known wrinkles of v1:
///
/// - The env filesystem API cannot set mtimes, so a pulled file lands with
///   "now" as its mtime and is pushed back once on the next sync before the
///   mtimes settle (the content is identical — no data churn, just a copy).
/// - Equal mtimes are treated as "in sync" without comparing content.
///
/// Use [createICloudSyncService] (conditionally imported above) to obtain
/// the platform implementation: the `fah/icloud` method channel + `dart:io`
/// container copy on iOS/macOS, a never-available stub on web. Tests inject
/// fakes.
abstract interface class ICloudSyncService {
  /// Whether the ubiquity container resolved (iCloud signed in and the
  /// capability/container id present in the provisioning profile).
  Future<bool> isAvailable();

  /// The container Documents URL string, or null when unavailable.
  Future<String?> containerUrl();

  /// Runs one merge and returns the report. Throws [StateError] when the
  /// container is unavailable — check [isAvailable] first for guidance.
  Future<ICloudSyncReport> syncNow();

  /// The timestamp of the last successful sync, or null when never synced.
  Future<DateTime?> lastSyncAt();
}

/// Formats a sync timestamp for tool results and snackbars:
/// `YYYY-MM-DD HH:MM` local time.
String formatICloudSyncTimestamp(DateTime at) =>
    '${at.year.toString().padLeft(4, '0')}-'
    '${at.month.toString().padLeft(2, '0')}-'
    '${at.day.toString().padLeft(2, '0')} '
    '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}';
