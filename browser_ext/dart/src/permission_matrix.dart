// The permission⇄tool matrix (issue #30 AC4/AC4d): ONE declarative table
// answering "which chrome permission backs which agent tool, at which tier"
// plus a bidirectional checker that keeps the manifest, this table and the
// tool registry in lockstep. Every other surface derives its permission
// facts from `manifestEntries()` — a permission that drifts from the table
// surfaces as a MatrixViolation instead of a silent gap. The three tiers
// mirror the v2.1 inventory: registered-and-exposed (core), implemented but
// Settings-gated (secondTier), and deliberately absent everywhere
// (excluded — the row documents why, so absence is auditable, not
// accidental). Pure Dart: compiles into the MV3 service worker, so no
// dart:io and no js_interop.
library;

/// How a tool (or permission) sits in the v2.1 inventory.
enum MatrixTier {
  /// Registered and exposed to the agent; an unpacked manifest must carry
  /// the permission.
  core,

  /// Implemented but not registered by default — a Settings gate turns it
  /// on; its permission may ride `optional_permissions`.
  secondTier,

  /// Deliberately absent from manifest AND registry; the table row's
  /// rationale documents why so the absence is auditable.
  excluded,
}

/// One row of the declarative permission⇄tool table.
final class ToolManifestEntry {
  /// Tool name as the registry keys it (equals the chrome namespace for
  /// single-namespace tools).
  final String tool;

  /// chrome manifest permission names backing the tool (empty when the
  /// namespace needs no permission, e.g. `runtime`).
  final Set<String> permissions;

  /// Which inventory tier the tool belongs to.
  final MatrixTier tier;

  /// chrome.* namespace backing the tool when it differs from [tool]
  /// (composite tools); null means [tool] names the namespace itself.
  final String? apiGroup;

  /// True only for rows impossible by construction — chrome exposes no API
  /// at all — recorded so no tool may ever probe for one.
  final bool impossible;

  /// Why an [MatrixTier.excluded] row stays out; null for other tiers.
  final String? rationale;

  const ToolManifestEntry({
    required this.tool,
    required this.permissions,
    required this.tier,
    this.apiGroup,
    this.impossible = false,
    this.rationale,
  });
}

/// The full v2.1 inventory, one row per tool. This list is the single
/// source of truth: `checkMatrix` classifies every permission and tool name
/// against it, and the registry⇄table test pins the live registry to it.
const List<ToolManifestEntry> _table = [
  // --- core: registered and driven by the agent ---
  ToolManifestEntry(tool: 'tabs', permissions: {'tabs'}, tier: MatrixTier.core),
  ToolManifestEntry(
    tool: 'windows',
    permissions: {'windows'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(
    tool: 'tabGroups',
    permissions: {'tabGroups'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(
    tool: 'sessions',
    permissions: {'sessions'},
    tier: MatrixTier.core,
  ),
  // Reading/download surfaces the v2.1 registry drives (browser_api_tools:
  // history_search, bookmarks_*, downloads_*, cookies_*, nav_wait) and the
  // ChromeApi facade covers — same core tier, same manifest requirement.
  ToolManifestEntry(
    tool: 'history',
    permissions: {'history'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(
    tool: 'bookmarks',
    permissions: {'bookmarks'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(
    tool: 'downloads',
    permissions: {'downloads'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(
    tool: 'cookies',
    permissions: {'cookies'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(
    tool: 'webNavigation',
    permissions: {'webNavigation'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(
    tool: 'scripting',
    permissions: {'scripting'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(
    tool: 'debugger',
    permissions: {'debugger'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(
    tool: 'storage',
    permissions: {'storage'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(
    tool: 'sidePanel',
    permissions: {'sidePanel'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(
    tool: 'action',
    permissions: {'action'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(
    tool: 'alarms',
    permissions: {'alarms'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(
    tool: 'offscreen',
    permissions: {'offscreen'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(
    tool: 'notifications',
    permissions: {'notifications'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(
    tool: 'power',
    permissions: {'power'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(tool: 'idle', permissions: {'idle'}, tier: MatrixTier.core),
  ToolManifestEntry(
    tool: 'commands',
    permissions: {'commands'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(
    tool: 'contextMenus',
    permissions: {'contextMenus'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(
    tool: 'omnibox',
    permissions: {'omnibox'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(
    tool: 'identity',
    permissions: {'identity'},
    tier: MatrixTier.core,
  ),
  // chrome.runtime needs no manifest permission.
  ToolManifestEntry(tool: 'runtime', permissions: {}, tier: MatrixTier.core),
  ToolManifestEntry(
    tool: 'system.cpu',
    permissions: {'system.cpu'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(
    tool: 'system.memory',
    permissions: {'system.memory'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(
    tool: 'system.storage',
    permissions: {'system.storage'},
    tier: MatrixTier.core,
  ),
  ToolManifestEntry(
    tool: 'system.display',
    permissions: {'system.display'},
    tier: MatrixTier.core,
  ),

  // --- second tier: registered-but-hidden behind a Settings gate ---
  ToolManifestEntry(
    tool: 'search',
    permissions: {'search'},
    tier: MatrixTier.secondTier,
  ),
  ToolManifestEntry(
    tool: 'topSites',
    permissions: {'topSites'},
    tier: MatrixTier.secondTier,
  ),
  ToolManifestEntry(
    tool: 'readingList',
    permissions: {'readingList'},
    tier: MatrixTier.secondTier,
  ),
  ToolManifestEntry(
    tool: 'pageCapture',
    permissions: {'pageCapture'},
    tier: MatrixTier.secondTier,
  ),
  ToolManifestEntry(
    tool: 'tabCapture',
    permissions: {'tabCapture'},
    tier: MatrixTier.secondTier,
  ),
  ToolManifestEntry(
    tool: 'desktopCapture',
    permissions: {'desktopCapture'},
    tier: MatrixTier.secondTier,
  ),
  ToolManifestEntry(
    tool: 'tts',
    permissions: {'tts'},
    tier: MatrixTier.secondTier,
  ),
  ToolManifestEntry(
    tool: 'userScripts',
    permissions: {'userScripts'},
    tier: MatrixTier.secondTier,
  ),
  ToolManifestEntry(
    tool: 'declarativeNetRequest',
    permissions: {'declarativeNetRequest'},
    tier: MatrixTier.secondTier,
  ),

  // --- excluded: absent from manifest and registry, on the record ---
  ToolManifestEntry(
    tool: 'browsingData',
    permissions: {'browsingData'},
    tier: MatrixTier.excluded,
    rationale: 'wipes user data',
  ),
  ToolManifestEntry(
    tool: 'privacy',
    permissions: {'privacy'},
    tier: MatrixTier.excluded,
    rationale: 'mutates browser-wide privacy settings',
  ),
  ToolManifestEntry(
    tool: 'proxy',
    permissions: {'proxy'},
    tier: MatrixTier.excluded,
    rationale: 'browser-wide settings mutation',
  ),
  ToolManifestEntry(
    tool: 'management',
    permissions: {'management'},
    tier: MatrixTier.excluded,
    rationale: 'controls other extensions',
  ),
  ToolManifestEntry(
    tool: 'gcm',
    permissions: {'gcm'},
    tier: MatrixTier.excluded,
    rationale: 'push-messaging transport, not an agent surface',
  ),
  ToolManifestEntry(
    tool: 'devtools',
    permissions: {'devtools'},
    tier: MatrixTier.excluded,
    rationale: 'opens interactive devtools windows, not automation',
  ),
  ToolManifestEntry(
    tool: 'fileBrowserHandler',
    permissions: {'fileBrowserHandler'},
    tier: MatrixTier.excluded,
    rationale: 'ChromeOS-only',
  ),
  ToolManifestEntry(
    tool: 'printing',
    permissions: {'printing'},
    tier: MatrixTier.excluded,
    rationale: 'ChromeOS-only',
  ),
  ToolManifestEntry(
    tool: 'printingMetrics',
    permissions: {'printingMetrics'},
    tier: MatrixTier.excluded,
    rationale: 'ChromeOS-only',
  ),
  ToolManifestEntry(
    tool: 'fileSystemProvider',
    permissions: {'fileSystemProvider'},
    tier: MatrixTier.excluded,
    rationale: 'ChromeOS-only',
  ),
  // The impossible row: chrome exposes no password API. Anything — a
  // manifest entry, a tool spec, a prompt — reaching for one is a bug by
  // construction, so the checker flags it wherever it appears.
  ToolManifestEntry(
    tool: 'passwords',
    permissions: {'passwords'},
    tier: MatrixTier.excluded,
    impossible: true,
    rationale:
        'chrome exposes no API — impossible by construction, no tool may '
        'probe for one',
  ),
];

/// The declarative permission⇄tool table. Everything derives from here.
List<ToolManifestEntry> manifestEntries() => _table;

/// Manifest permission names the core tier requires (unpacked profile).
Set<String> corePermissions() => Set.unmodifiable(_corePermissions);

/// Permission names classified excluded — allowed nowhere, ever.
Set<String> excludedPermissions() => Set.unmodifiable(_excludedNames);

/// The table's classification for one manifest permission name, or null
/// when the name is outside the vocabulary entirely (itself a violation
/// once it shows up in a manifest, entry or registry).
MatrixTier? tierOfPermission(String permission) =>
    _tierByPermission[permission];

/// The `optional_permissions` names a store-profile manifest may carry:
/// exactly the second tier. A checked-in manifest lists them only when its
/// feature gate ships.
const Set<String> secondTierOptionalPermissions = {
  'search',
  'topSites',
  'readingList',
  'pageCapture',
  'tabCapture',
  'desktopCapture',
  'tts',
  'userScripts',
  'declarativeNetRequest',
};

/// Profile: a developer/unpacked build carries the full core permission
/// set (`profileUnpacked`); a store build ships the review-safe reduced
/// profile (`profileStore`) — second tier, `debugger` and `cookies` may be
/// absent, but nothing extra may appear.
const String profileUnpacked = 'unpacked';
const String profileStore = 'store';

/// One disagreement between manifest, table and registry. [kind] is one of:
/// `dead_permission` (manifest permission with no tool), `ghost_tool` (tool
/// whose permission the manifest lacks, or a registration with no table
/// row), `exposed_excluded` (excluded API present in manifest or registry),
/// `tier_mismatch` (entry tier contradicts the table, or a store manifest
/// carries a stripped permission).
final class MatrixViolation {
  final String kind;
  final String detail;

  const MatrixViolation(this.kind, this.detail);

  @override
  String toString() => '$kind: $detail';
}

/// Walks the permission⇄tool matrix in BOTH directions:
///
/// * every manifest browser permission is claimed by ≥1 table entry
///   (`dead_permission` otherwise);
/// * every entry permission is granted by the manifest or rides
///   [secondTierOptionalPermissions] — plus `debugger`/`cookies` under the
///   store profile, which tolerates them MISSING but never present
///   (`ghost_tool` / `tier_mismatch` otherwise);
/// * excluded APIs appear in neither manifest nor registry
///   (`exposed_excluded`);
/// * every registered tool name has a table row (`ghost_tool` otherwise).
///
/// [profile] selects the manifest contract — see [profileUnpacked] /
/// [profileStore]; unknown values throw.
List<MatrixViolation> checkMatrix({
  required Set<String> manifestPermissions,
  required Iterable<ToolManifestEntry> entries,
  required Iterable<String> registeredToolNames,
  String profile = profileUnpacked,
}) {
  final isStore = switch (profile) {
    profileUnpacked => false,
    profileStore => true,
    _ => throw ArgumentError.value(
      profile,
      'profile',
      'must be "$profileUnpacked" or "$profileStore"',
    ),
  };
  final toleratedMissing = <String>{...secondTierOptionalPermissions};
  if (isStore) toleratedMissing.addAll(_storeStripped);

  final violations = <MatrixViolation>[];
  final entryTools = <String>{};
  final covered = <String>{};

  // Table side: tier honesty + permission coverage.
  for (final entry in entries) {
    entryTools.add(entry.tool);
    for (final permission in entry.permissions) {
      if (entry.tier != MatrixTier.excluded) covered.add(permission);
      final canonical = _tierByPermission[permission];
      if (canonical != entry.tier) {
        violations.add(
          MatrixViolation(
            'tier_mismatch',
            'entry "${entry.tool}" declares ${entry.tier.name} but the table '
                'classifies "$permission" as ${canonical?.name ?? 'unknown'}',
          ),
        );
        continue;
      }
      // Excluded rows document absence; they never demand a manifest slot.
      if (entry.tier == MatrixTier.excluded) continue;
      if (!manifestPermissions.contains(permission) &&
          !toleratedMissing.contains(permission)) {
        violations.add(
          MatrixViolation(
            'ghost_tool',
            'tool "${entry.tool}" needs "$permission" but it is in neither '
                'permissions nor optional_permissions',
          ),
        );
      }
    }
  }

  // Manifest side: nothing dead, nothing excluded, nothing store-stripped.
  for (final permission in manifestPermissions) {
    final rationale = _excludedRationale[permission];
    if (rationale != null) {
      violations.add(
        MatrixViolation('exposed_excluded', '"$permission": $rationale'),
      );
      continue;
    }
    if (isStore && _storeStripped.contains(permission)) {
      violations.add(
        MatrixViolation(
          'tier_mismatch',
          '"$permission" is stripped from store-profile builds; only the '
              'unpacked profile may carry it',
        ),
      );
      continue;
    }
    if (!covered.contains(permission)) {
      violations.add(
        MatrixViolation(
          'dead_permission',
          'manifest grants "$permission" but no tool row claims it',
        ),
      );
    }
  }

  // Registry side: no ghost registrations, no excluded APIs.
  for (final tool in registeredToolNames) {
    final rationale = _excludedRationale[tool];
    if (rationale != null) {
      violations.add(
        MatrixViolation(
          'exposed_excluded',
          'registered tool "$tool": $rationale',
        ),
      );
    } else if (!entryTools.contains(tool)) {
      violations.add(
        MatrixViolation(
          'ghost_tool',
          'registered tool "$tool" has no row in the declarative table',
        ),
      );
    }
  }
  return violations;
}

/// Permissions a store-profile manifest must NOT carry even though core
/// tools reference them: store review strips them, the SW degrades without.
const Set<String> _storeStripped = {'debugger', 'cookies'};

final Set<String> _corePermissions = {
  for (final e in _table)
    if (e.tier == MatrixTier.core) ...e.permissions,
};

/// Tool names and permission names mapping to their excluded row's
/// rationale — one lookup serves both manifest-permission and
/// registered-tool checks.
final Map<String, String> _excludedRationale = {
  for (final e in _table)
    if (e.tier == MatrixTier.excluded)
      for (final name in {e.tool, ...e.permissions}) name: e.rationale!,
};

final Set<String> _excludedNames = {
  for (final e in _table)
    if (e.tier == MatrixTier.excluded) ...e.permissions,
};

final Map<String, MatrixTier> _tierByPermission = {
  for (final e in _table)
    for (final p in e.permissions) p: e.tier,
};
