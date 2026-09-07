// UT-T2 (issue #30 AC4/AC4d): the declarative permission⇄tool matrix.
// (a) the real-manifest gate, (b) one fixture per violation direction,
// (c) store vs unpacked profile, (d) the impossible `passwords` row.
//
// The checked-in manifest.json still lacks most v2.1 permissions (a sibling
// phase updates it), so gate (a) runs against the UNION of the real
// manifest's permissions and the table's own — i.e. the future manifest.
// Once manifest.json carries the full set the union degenerates to the
// manifest itself and the gate tightens for free, no test change needed.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:flutter_agent_harness/src/agent/tool_registry.dart';

import '../src/browser_api_tools.dart';
import '../src/fake_chrome.dart';
import '../src/permission_matrix.dart';

Map<String, dynamic> _manifestJsonMap() {
  for (final path in const [
    'browser_ext/manifest.json', // cwd = repo root (dart test <path>)
    '../manifest.json', // cwd = browser_ext/dart (package root)
  ]) {
    final file = File(path);
    if (file.existsSync()) {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }
  }
  fail(
    'browser_ext/manifest.json not found relative to '
    '${Directory.current.path}',
  );
}

/// The real extension manifest's permissions, located relative to the
/// package root (`dart test` cwd) or the repo root.
Set<String> _realManifestPermissions() => {
  ...(_manifestJsonMap()['permissions'] as List<dynamic>).cast<String>(),
};

/// Names a compliant registry would key: every table row the agent may
/// actually run. Excluded rows are documentation, never registrations.
Set<String> _registeredTools() => {
  for (final e in manifestEntries())
    if (e.tier != MatrixTier.excluded) e.tool,
};

/// The live registry's namespace footprint: every chrome permission the
/// operation tools of browserApiToolSpecs() touch. Operation names
/// (tabs_open, ...) are finer than table rows, so registry⇄table
/// consistency is checked on namespaces.
Set<String> _registryFootprint() => {
  for (final s in browserApiToolSpecs()) ...s.permissions,
};

void main() {
  final tableTools = {for (final e in manifestEntries()) e.tool};

  group('UT-T2a: real manifest gate (AC4)', () {
    test('union of real manifest and table → zero violations, unpacked', () {
      // Union = the future manifest: while the real manifest is missing
      // v2.1 permissions this stays green; when it catches up the union is
      // a no-op and the gate asserts the manifest alone.
      final union = {
        ..._realManifestPermissions(),
        ...corePermissions(),
        ...secondTierOptionalPermissions,
      };
      final violations = checkMatrix(
        manifestPermissions: union,
        entries: manifestEntries(),
        registeredToolNames: _registryFootprint(),
        profile: profileUnpacked,
      );
      expect(violations, isEmpty, reason: violations.join('\n'));
    });

    group('UT-T2a: registry ⇄ table consistency (browserApiToolSpecs)', () {
      // The registry keys tools at operation granularity (tabs_open, ...)
      // while table rows are chrome namespaces; the shared key between the
      // two granularities is each spec's `permissions` set. Consistency is
      // therefore asserted on the namespace footprint: every API the live
      // registry touches must be a table row (no ghosts), never an
      // excluded one, and spec visibility must agree with the table tier.
      final specs = browserApiToolSpecs();

      test('live registry footprint passes the checker', () {
        final violations = checkMatrix(
          manifestPermissions: {
            ..._realManifestPermissions(),
            ...corePermissions(),
            ...secondTierOptionalPermissions,
          },
          entries: manifestEntries(),
          registeredToolNames: _registryFootprint(),
          profile: profileUnpacked,
        );
        expect(violations, isEmpty, reason: violations.join('\n'));
      });

      test('spec visibility agrees with the table tier', () {
        for (final spec in specs) {
          for (final permission in spec.permissions) {
            final tier = tierOfPermission(permission);
            expect(
              tier,
              isNotNull,
              reason: '${spec.name}: "$permission" is outside the table',
            );
            expect(
              tier == MatrixTier.secondTier,
              spec.visibility == BrowserToolVisibility.secondTier,
              reason:
                  '${spec.name} declares ${spec.visibility.name} but the '
                  'table classifies "$permission" as ${tier!.name}',
            );
          }
        }
      });

      test('registry names are unique', () {
        expect(specs.map((s) => s.name).toSet(), hasLength(specs.length));
      });

      test(
        'AC4d: one matrix across all three tiers (registry + manifest)',
        () async {
          final chrome = FakeChrome(clock: () => 1730000000000);
          final reg = ToolRegistry();
          await registerBrowserApiTools(reg, chrome); // default gate: core only
          for (final spec in specs) {
            switch (spec.visibility) {
              case BrowserToolVisibility.core:
                expect(
                  reg.names,
                  contains(spec.name),
                  reason: 'core "${spec.name}" must register and be visible',
                );
              case BrowserToolVisibility.secondTier:
                expect(
                  reg.names,
                  isNot(contains(spec.name)),
                  reason: 'second-tier "${spec.name}" is hidden by default',
                );
            }
          }
          // Excluded rows: absent from the registry (nothing to register)
          final optional = {
            ...((_manifestJsonMap()['optional_permissions']
                        as List<dynamic>?) ??
                    const [])
                .cast<String>(),
          };
          final excluded = {
            for (final entry in manifestEntries())
              if (entry.tier == MatrixTier.excluded) ...entry.permissions,
          };
          expect(excluded, isNotEmpty, reason: 'the table has excluded rows');
          expect(
            _registryFootprint().intersection(excluded),
            isEmpty,
            reason: 'excluded permissions must never back a registered tool',
          );
          expect(
            optional.intersection(excluded),
            isEmpty,
            reason: 'excluded permissions must stay out of the manifest',
          );
        },
      );
    });

    test('table covers every real manifest permission in use today', () {
      final covered = {for (final e in manifestEntries()) ...e.permissions};
      expect(
        _realManifestPermissions().difference(covered),
        isEmpty,
        reason: 'manifest grants permissions no tool row claims',
      );
    });
  });

  group('UT-T2b: one fixture per violation direction', () {
    test('manifest permission no tool claims → dead_permission', () {
      final tabsRow = manifestEntries().firstWhere((e) => e.tool == 'tabs');
      final violations = checkMatrix(
        manifestPermissions: {'tabs', 'downloads'},
        entries: [tabsRow],
        registeredToolNames: {'tabs'},
      );
      expect(violations, hasLength(1));
      expect(violations.single.kind, 'dead_permission');
      expect(violations.single.detail, contains('downloads'));
    });

    test('core tool whose permission the manifest lacks → ghost_tool', () {
      final withoutAlarms = {...corePermissions()}..remove('alarms');
      final violations = checkMatrix(
        manifestPermissions: withoutAlarms,
        entries: manifestEntries(),
        registeredToolNames: _registeredTools(),
        profile: profileUnpacked,
      );
      expect(violations, hasLength(1));
      expect(violations.single.kind, 'ghost_tool');
      expect(violations.single.detail, contains('alarms'));
    });

    test('excluded API in the manifest → exposed_excluded with rationale', () {
      final violations = checkMatrix(
        manifestPermissions: {...corePermissions(), 'browsingData'},
        entries: manifestEntries(),
        registeredToolNames: _registeredTools(),
      );
      expect(violations, hasLength(1));
      expect(violations.single.kind, 'exposed_excluded');
      expect(violations.single.detail, contains('wipes user data'));
    });

    test('registration absent from the table → ghost registration', () {
      final violations = checkMatrix(
        manifestPermissions: corePermissions(),
        entries: manifestEntries(),
        registeredToolNames: {..._registeredTools(), 'bookmarks_import'},
      );
      expect(violations, hasLength(1));
      expect(violations.single.kind, 'ghost_tool');
      expect(violations.single.detail, contains('bookmarks_import'));
    });
  });

  group('UT-T2c: store vs unpacked profile', () {
    test('store tolerates a reduced manifest (no debugger/cookies, no second '
        'tier)', () {
      final reduced = {...corePermissions()}
        ..remove('debugger')
        ..remove('cookies');
      final violations = checkMatrix(
        manifestPermissions: reduced,
        entries: manifestEntries(),
        registeredToolNames: _registeredTools(),
        profile: profileStore,
      );
      expect(violations, isEmpty, reason: violations.join('\n'));
    });

    test(
      'store rejects the full unpacked manifest (stripped APIs present)',
      () {
        final violations = checkMatrix(
          manifestPermissions: corePermissions(),
          entries: manifestEntries(),
          registeredToolNames: _registeredTools(),
          profile: profileStore,
        );
        final stripped = violations.where((v) => v.kind == 'tier_mismatch');
        expect(stripped, hasLength(2));
        expect(stripped.map((v) => v.detail), contains(contains('debugger')));
        expect(stripped.map((v) => v.detail), contains(contains('cookies')));
      },
    );

    test('excluded APIs fail under both profiles', () {
      final withBrowsingData = {...corePermissions(), 'browsingData'};
      for (final profile in const [profileUnpacked, profileStore]) {
        final violations = checkMatrix(
          manifestPermissions: withBrowsingData,
          entries: manifestEntries(),
          registeredToolNames: _registeredTools(),
          profile: profile,
        );
        expect(
          violations.where((v) => v.kind == 'exposed_excluded'),
          isNotEmpty,
          reason: 'profile $profile tolerated browsingData',
        );
      }
    });
  });

  group('UT-T2d: the impossible passwords row', () {
    test('table documents passwords as impossible-by-construction', () {
      final row = manifestEntries().singleWhere((e) => e.impossible);
      expect(row.tool, 'passwords');
      expect(row.tier, MatrixTier.excluded);
      expect(row.rationale, isNotNull);
      expect(row.rationale, contains('no API'));
    });

    test('passwords in the manifest → violation, wherever it shows up', () {
      final inManifest = checkMatrix(
        manifestPermissions: {'tabs', 'passwords'},
        entries: [manifestEntries().firstWhere((e) => e.tool == 'tabs')],
        registeredToolNames: {'tabs'},
      );
      expect(inManifest, hasLength(1));
      expect(inManifest.single.kind, 'exposed_excluded');
      expect(inManifest.single.detail, contains('no API'));

      final inRegistry = checkMatrix(
        manifestPermissions: {'tabs'},
        entries: [manifestEntries().firstWhere((e) => e.tool == 'tabs')],
        registeredToolNames: {'tabs', 'passwords'},
      );
      expect(inRegistry, hasLength(1));
      expect(inRegistry.single.kind, 'exposed_excluded');
      expect(inRegistry.single.detail, contains('no API'));
    });
  });

  group('UT-T2: table self-checks', () {
    test('secondTierOptionalPermissions is exactly the second tier', () {
      // `tts` and `declarativeNetRequest` are NOT optional-eligible in
      // Chrome (load-time warnings: "cannot be listed as optional") — they
      // moved to the excluded record, see manifest.json.
      expect(secondTierOptionalPermissions, {
        'search',
        'topSites',
        'readingList',
        'pageCapture',
        'tabCapture',
        'desktopCapture',
        'userScripts',
      });
    });

    test('unknown profile value throws', () {
      expect(
        () => checkMatrix(
          manifestPermissions: {'tabs'},
          entries: manifestEntries(),
          registeredToolNames: const {},
          profile: 'ci',
        ),
        throwsArgumentError,
      );
    });

    test('runtime needs no permission; every other core row carries one', () {
      final permissionless = manifestEntries().where(
        (e) => e.permissions.isEmpty,
      );
      expect(permissionless.map((e) => e.tool), ['runtime']);
      expect(tableTools, containsAll(_registeredTools()));
    });
  });
}
