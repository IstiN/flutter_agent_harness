/// Registry of extensions bundled with the harness (contract section 12) and
/// the install planner for them.
library;

/// Bundled seeds are const Dart strings (see `crap_guard.dart`) — no assets,
/// no IO. Trust provenance is always `ExtTrustSource.bundled` /
/// `'bundled'`; the content hash a trust record pins is derived by callers
/// via `extContentHash(plan.files)` (the same function `applyInstall` uses).
import 'dart:convert';

import '../ext_install.dart' show ExtInstallException, ExtInstallPlan;
import '../ext_manifest.dart';
import '../trust.dart' show ExtTrustSource;
import 'crap_guard.dart';

/// Bundled extensions by name: `{'manifest.json': ..., 'main.js': ...}`.
///
/// v1 ships exactly one entry, the `crap-guard` reference extension.
const Map<String, Map<String, String>> kBundledExtensions = {
  'crap-guard': {
    'manifest.json': kCrapGuardManifestJson,
    'main.js': kCrapGuardMainJs,
  },
};

/// Plans an install of the bundled extension [name].
///
/// Validates `manifest.json` through [ExtensionManifest.fromJson] (a broken
/// bundled seed throws [ExtManifestException]) and returns the plan with
/// trust source `bundled` / trustRef `'bundled'`. An unknown name throws
/// [ExtInstallException].
ExtInstallPlan planBundledInstall(String name) {
  final files = kBundledExtensions[name];
  if (files == null) {
    throw ExtInstallException(
      'unknown bundled extension: $name (available: ${kBundledExtensions.keys.join(', ')})',
    );
  }
  return ExtInstallPlan(
    name: name,
    files: files,
    manifest: ExtensionManifest.fromJson(
      jsonDecode(files['manifest.json']!) as Map<String, dynamic>,
    ),
    trustSource: ExtTrustSource.bundled,
    trustRef: 'bundled',
  );
}
