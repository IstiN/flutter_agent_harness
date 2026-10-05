/// Issue #1079 slice 1 — SDK foundation tests.
///
/// AC3 matrix completeness (cell-exact against the issue table) · AC4 floor
/// narrowing (loud construction failures) · AC10 catalog ceiling (SDK ⊇ CLI,
/// inventory-driven) · AC7 hiding (plan-level + real-text string absence) ·
/// E1 platform-service validation · E2 undeclared-capability rejection.
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'host_hiding.dart';

/// Platform services the CLI-wired capabilities need (E1 seam; the names
/// are the builder contract, the values are host-side in slice 2). The
/// vision/transcribe row requires no services — its per-tool config
/// gating lives inside the slice-2 assembly.
final cliPlatformServices = {
  'mcpTransportFactory': Object(),
  'hubFabric': Object(),
  'cubeSpec': Object(),
  'fsProbe': Object(),
  'shellJobFactory': Object(),
  'sqliteEngine': Object(),
  'lspTransportFactory': Object(),
  'webSearchSecrets': Object(),
  'browserBridgeHandle': Object(),
  'extRuntimeFactory': Object(),
  'sessionRoot': Object(),
};

/// [cliPlatformServices] plus what the non-CLI hosts' wired rows need
/// (on-device inference factory, the chat widget sink behind js_apps).
final fullPlatformServices = {
  ...cliPlatformServices,
  'onDeviceProviderFactory': Object(),
  'dynamicMessageSink': Object(),
};

HostWiringPlan buildFor(HostCapabilityProfile profile) => HostWiringBuilder(
  profile: profile,
  platformServices: fullPlatformServices,
).build();

void main() {
  group('AC3 — matrix completeness', () {
    test('every built-in profile declares every capability', () {
      for (final profile in builtInProfiles.values) {
        for (final capability in HostCapability.values) {
          expect(
            profile.states.containsKey(capability),
            isTrue,
            reason: '${profile.name} does not declare ${capability.id}',
          );
        }
      }
    });

    test('off/transport cells carry non-empty reasons', () {
      for (final profile in builtInProfiles.values) {
        for (final entry in profile.states.entries) {
          final reason = entry.value.reason;
          if (reason != null) {
            expect(
              reason.trim(),
              isNotEmpty,
              reason:
                  '${profile.name}/${entry.key.id} has a blank reason — '
                  'off/transition cells must say why (AC3)',
            );
          }
        }
      }
    });

    test('transport cells name known transports only', () {
      for (final profile in builtInProfiles.values) {
        for (final entry in profile.states.entries) {
          final state = entry.value;
          if (state is CapabilityTransportState) {
            final vocabulary = hostCapabilityTransports[entry.key]!.all;
            expect(
              state.transports.every(vocabulary.contains),
              isTrue,
              reason:
                  '${profile.name}/${entry.key.id} names transports '
                  '${state.transports} outside the vocabulary $vocabulary',
            );
            expect(state.transports, isNotEmpty);
          }
        }
      }
    });

    // The issue's capability × platform table, cell-exact. Platform order:
    // cli, macos, ios, android, web, extension, outlook.
    const on = 'on', off = 'off';
    String tx(String transports) => 'tx:$transports';
    final matrix = <HostCapability, List<String>>{
      HostCapability.configSections: [
        on,
        on,
        on,
        on,
        tx('origin-storage'),
        tx('origin-storage'),
        tx('origin-storage'),
      ],
      HostCapability.compaction: [
        on,
        on,
        on,
        on,
        on,
        off,
        tx('origin-storage'),
      ],
      HostCapability.loadModes: [
        on,
        on,
        on,
        on,
        on,
        tx('registered-only'),
        tx('registered-only'),
      ],
      HostCapability.mcp: [
        on,
        tx('remote'),
        tx('remote'),
        tx('remote'),
        tx('remote'),
        tx('remote'),
        tx('remote'),
      ],
      HostCapability.messagingFabric: [
        on,
        tx('file,hub'),
        tx('hub'),
        tx('hub'),
        tx('hub'),
        tx('hub'),
        tx('hub'),
      ],
      HostCapability.approvalGate: [on, on, on, on, on, on, on],
      HostCapability.skills: [
        on,
        on,
        on,
        on,
        on,
        tx('registered'),
        tx('registered'),
      ],
      HostCapability.sandboxEnv: [on, on, on, on, on, off, off],
      HostCapability.backgroundShellJobs: [
        on,
        on,
        tx('future'),
        tx('async'),
        tx('async'),
        off,
        off,
      ],
      HostCapability.sqliteLspDap: [
        on,
        tx('ffi,process'),
        off,
        off,
        tx('sqljs'),
        off,
        off,
      ],
      HostCapability.onDeviceProviders: [
        off,
        tx('in-process'),
        on,
        on,
        on,
        tx('in-process'),
        off,
      ],
      HostCapability.jsApps: [off, on, on, on, on, tx('extension-subset'), on],
      HostCapability.checkpointRewind: [
        on,
        on,
        tx('origin-storage'),
        tx('origin-storage'),
        tx('origin-storage'),
        off,
        off,
      ],
      HostCapability.hostExtensionApi: [on, on, on, on, on, on, on],
    };
    const platformOrder = [
      'cli',
      'macos',
      'ios',
      'android',
      'web',
      'extension',
      'outlook',
    ];

    test('the 14 matrix rows are pinned cell-exact (UT-2)', () {
      expect(matrix.length, 14, reason: 'the issue table has 14 rows');
      for (final capability in matrix.keys) {
        final row = matrix[capability]!;
        expect(row.length, platformOrder.length);
        for (var i = 0; i < row.length; i++) {
          final profile = builtInProfiles[platformOrder[i]]!;
          final state = profile.stateFor(capability);
          final expected = row[i];
          switch (expected) {
            case 'on':
              expect(
                state,
                isA<CapabilityOnState>(),
                reason: _cell(capability, platformOrder[i], expected),
              );
            case 'off':
              expect(
                state,
                isA<CapabilityOffState>(),
                reason: _cell(capability, platformOrder[i], expected),
              );
            default:
              final transports = expected.substring(3).split(',');
              expect(
                state,
                isA<CapabilityTransportState>(),
                reason: _cell(capability, platformOrder[i], expected),
              );
              expect(
                (state as CapabilityTransportState).transports,
                equals(transports.toSet()),
                reason: _cell(capability, platformOrder[i], expected),
              );
          }
        }
      }
    });

    test('the five inventory-driven rows: CLI on, every other host off', () {
      const inventoryRows = [
        HostCapability.webSearch,
        HostCapability.visionTranscribe,
        HostCapability.subagents,
        HostCapability.browserBridge,
        HostCapability.jsExtensions,
      ];
      for (final capability in inventoryRows) {
        expect(cliProfile.stateFor(capability), isA<CapabilityOnState>());
        for (final entry in builtInProfiles.entries) {
          if (entry.key == 'cli') continue;
          final state = entry.value.stateFor(capability);
          expect(
            state,
            isA<CapabilityOffState>(),
            reason:
                '${entry.key}/${capability.id}: only the CLI wires this '
                'today',
          );
          expect(
            (state as CapabilityOffState).reason,
            contains('not wired'),
            reason: 'the off-reason must record the today-state',
          );
        }
      }
    });

    test('a custom profile missing a capability is rejected (E2/UT-2)', () {
      final states = {
        for (final c in HostCapability.values) c: CapabilityState.on,
      }..remove(HostCapability.compaction);
      expect(
        () => HostCapabilityProfile(name: 'custom', states: states),
        throwsA(
          isA<HostProfileViolation>().having(
            (e) => e.message,
            'message',
            contains('compaction'),
          ),
        ),
      );
    });

    test('a custom host can construct its own complete profile', () {
      final states =
          <HostCapability, CapabilityState>{
              for (final c in HostCapability.values) c: CapabilityState.on,
            }
            ..[HostCapability.jsApps] = CapabilityState.off(
              'kiosk host renders no browser APIs',
            )
            ..[HostCapability.mcp] = CapabilityState.transport({
              'remote',
            }, 'kiosk allows remote only');
      final profile = HostCapabilityProfile(name: 'kiosk', states: states);
      expect(
        profile.stateFor(HostCapability.jsApps),
        isA<CapabilityOffState>(),
      );
    });

    test('transport vocabulary covers every capability (E2)', () {
      for (final capability in HostCapability.values) {
        expect(
          hostCapabilityTransports.containsKey(capability),
          isTrue,
          reason:
              '${capability.id} has no hostCapabilityTransports entry — '
              'declare it (empty record for on/off-only) when adding the '
              'enum value',
        );
      }
    });
  });

  group('AC4 — floor narrowing (UT-3)', () {
    test('iosProfile cannot force-enable mcp over stdio (pinned example)', () {
      // `on` needs every default transport (stdio + remote); the iOS floor
      // allows remote only.
      expect(
        () => iosProfile.narrowed({HostCapability.mcp: CapabilityState.on}),
        throwsA(
          isA<HostProfileViolation>().having(
            (e) => e.message,
            'message',
            allOf(contains('mcp'), contains('ios'), contains('remote')),
          ),
        ),
        reason: 'the violation must name the profile, capability and floor',
      );
      expect(
        () => iosProfile.narrowed({
          HostCapability.mcp: CapabilityState.transport({
            'stdio',
          }, 'want stdio'),
        }),
        throwsA(isA<HostProfileViolation>()),
      );
    });

    test('off is always declarable, even on a floored capability', () {
      final narrowed = iosProfile.narrowed({
        HostCapability.mcp: CapabilityState.off('policy disables MCP'),
      });
      expect(
        narrowed.stateFor(HostCapability.mcp),
        isA<CapabilityOffState>().having(
          (s) => s.reason,
          'reason',
          'policy disables MCP',
        ),
      );
    });

    test('manifest-sandbox floors hold: no sandbox/shell/sqlite raise', () {
      for (final profile in [extensionProfile, outlookProfile]) {
        for (final capability in [
          HostCapability.sandboxEnv,
          HostCapability.backgroundShellJobs,
          HostCapability.sqliteLspDap,
          HostCapability.checkpointRewind,
        ]) {
          expect(
            () => profile.narrowed({capability: CapabilityState.on}),
            throwsA(isA<HostProfileViolation>()),
            reason: '${profile.name} must not force-enable ${capability.id}',
          );
        }
      }
    });

    test('a custom profile force-enabling past an explicit floor throws '
        'at construction', () {
      final states = {
        for (final c in HostCapability.values) c: CapabilityState.on,
      }..[HostCapability.onDeviceProviders] = CapabilityState.on;
      expect(
        () => HostCapabilityProfile(
          name: 'vm-plus',
          states: states,
          floors: {
            HostCapability.onDeviceProviders: const FloorOff(
              'no inference runtime on the VM',
            ),
          },
        ),
        throwsA(
          isA<HostProfileViolation>().having(
            (e) => e.message,
            'message',
            contains('on_device_providers'),
          ),
        ),
      );
    });

    test('the floor table survives narrowing (a narrowed profile cannot '
        'raise what its base floored)', () {
      final narrowed = iosProfile.narrowed({
        HostCapability.compaction: CapabilityState.off('temporarily off'),
      });
      expect(
        () => narrowed.narrowed({HostCapability.mcp: CapabilityState.on}),
        throwsA(isA<HostProfileViolation>()),
      );
    });

    test('macOS may explicitly narrow UP to stdio (floor keeps both '
        'transports)', () {
      final stdio = macosProfile.narrowed({
        HostCapability.mcp: CapabilityState.transport({
          'stdio',
          'remote',
        }, 'unsandboxed kiosk mode opts into stdio'),
      });
      expect(
        (stdio.stateFor(HostCapability.mcp) as CapabilityTransportState)
            .transports,
        equals({'stdio', 'remote'}),
      );
    });
  });

  group('AC10 — catalog ceiling: SDK ⊇ CLI (UT-6)', () {
    /// The verified CLI wiring inventory (sweep 2026-09-29, file:line-checked).
    /// Every item classifies as:
    /// - `capability` — a turn-on/off concern; MUST be a catalog row with
    ///   CLI wiring evidence;
    /// - `core-invariant` — SDK-owned, identical on every host (AC9), never
    ///   host-gated, so never a catalog row;
    /// - `host-glue` — thin-shell process wiring that stays host-side;
    /// - `config-consumer` — a consumer of a config section inside the
    ///   configSections row.
    const inventory = <String, (String, HostCapability?)>{
      // — capability rows —
      'config sections roles:/tools:/ttsr:/redact:/providerTimeouts:/agent:': (
        'capability',
        HostCapability.configSections,
      ),
      'compaction wiring (roles.smol, overWindowRelief, contextWindowCap)': (
        'capability',
        HostCapability.compaction,
      ),
      'load modes + discover_tools': ('capability', HostCapability.loadModes),
      'mcp servers (stdio + remote)': ('capability', HostCapability.mcp),
      'messaging fabric (file + hub + a2a)': (
        'capability',
        HostCapability.messagingFabric,
      ),
      'approval gate (modes + unattended + always-allow)': (
        'capability',
        HostCapability.approvalGate,
      ),
      'skills + project context': ('capability', HostCapability.skills),
      'sandbox env (cube + local)': ('capability', HostCapability.sandboxEnv),
      'background shell jobs (bash_job board)': (
        'capability',
        HostCapability.backgroundShellJobs,
      ),
      'sqlite reader / lsp / dap tools': (
        'capability',
        HostCapability.sqliteLspDap,
      ),
      'checkpoint + rewind': ('capability', HostCapability.checkpointRewind),
      'plugin registration (PluginContext.register)': (
        'capability',
        HostCapability.hostExtensionApi,
      ),
      'web_search / web_fetch tools': ('capability', HostCapability.webSearch),
      'vision + transcribe (inspect_image, transcribe_audio, image gen)': (
        'capability',
        HostCapability.visionTranscribe,
      ),
      'subagents + task system (SubagentManager, task/agent tools)': (
        'capability',
        HostCapability.subagents,
      ),
      'browser tool family over the bridge handle': (
        'capability',
        HostCapability.browserBridge,
      ),
      'QuickJS JS extensions + the fa-jsr widget pass-through (#1062)': (
        'capability',
        HostCapability.jsExtensions,
      ),
      // — core invariants (AC9): identical everywhere, never a row —
      'memory (MemoryController + memory_* tools)': (
        'core-invariant (AC9)',
        null,
      ),
      'JSONL tool session persistence': ('core-invariant (AC9)', null),
      'trajectory': ('core-invariant (AC9)', null),
      'context management': ('core-invariant (AC9)', null),
      // — host glue: stays in the thin shell —
      'TUI chrome (theme, HID, mouse, status line)': ('host-glue', null),
      'session presence store': ('host-glue', null),
      'power/sleep prevention': ('host-glue', null),
      'secure key store (platform store behind the seam)': ('host-glue', null),
      'prompt template dirs': ('host-glue', null),
      // — config consumers inside the configSections row —
      'providers queue runtime (boot failover)': ('config-consumer', null),
      'model roles resolver': ('config-consumer', null),
      'custom providers registry': ('config-consumer', null),
      'models config + media slots': ('config-consumer', null),
      'redaction pipeline': ('config-consumer', null),
      'ttsr rules': ('config-consumer', null),
      'spills': ('config-consumer', null),
      'wireDump flag': ('config-consumer', null),
    };

    test('every capability-classified inventory item is a catalog row with '
        'CLI evidence', () {
      for (final entry in inventory.entries) {
        final (kind, capability) = entry.value;
        if (kind != 'capability') continue;
        final spec = hostCapabilityCatalog[capability];
        expect(
          spec,
          isNotNull,
          reason:
              '"${entry.key}" is CLI-wired but absent from the '
              'catalog — the SDK ⊇ CLI ceiling is broken (AC10)',
        );
        expect(
          spec!.cliWiringSites,
          isNotEmpty,
          reason: '"${entry.key}" needs CLI wiring evidence',
        );
      }
    });

    test('the catalog covers every capability in the enum', () {
      for (final capability in HostCapability.values) {
        expect(
          hostCapabilityCatalog.containsKey(capability),
          isTrue,
          reason: '${capability.id} has no catalog spec',
        );
      }
    });

    test('matrix-floored rows carry no fake CLI evidence', () {
      for (final capability in [
        HostCapability.onDeviceProviders,
        HostCapability.jsApps,
      ]) {
        expect(
          hostCapabilityCatalog[capability]!.cliWiringSites,
          isEmpty,
          reason:
              '${capability.id} is matrix-floored off on the VM — it '
              'must not claim CLI wiring',
        );
      }
    });

    test('wiring evidence files still exist (rot guard)', () {
      for (final spec in hostCapabilityCatalog.values) {
        for (final site in spec.cliWiringSites) {
          final path = site.split(' (').first.trim();
          expect(
            File(path).existsSync() || Directory(path).existsSync(),
            isTrue,
            reason:
                '${spec.capability.id} cites missing wiring site "$path" '
                '— update the catalog',
          );
        }
      }
    });

    test('the CLI plan hides exactly the two VM-floored rows and wires the '
        'rest of the ceiling', () {
      final plan = buildFor(cliProfile);
      expect(
        plan.hidden.map((e) => e.capability),
        equals({HostCapability.jsApps, HostCapability.onDeviceProviders}),
        reason: 'the matrix floors exactly these two rows on the VM',
      );
      expect(plan.wired.length, HostCapability.values.length - 2);
    });
  });

  group('AC7 — hiding (UT-4)', () {
    test('the CLI plan hides the browser-API JS surface (pinned example)', () {
      final plan = buildFor(cliProfile);
      expectCapabilityHidden(plan, HostCapability.jsApps);
      final entry = plan.planFor(HostCapability.jsApps) as HiddenCapability;
      expect(entry.reason, contains('browser APIs'));
    });

    test('the real CLI help text carries zero jsApps references', () {
      // cliHelpText is a REAL emitted CLI surface: if the capability were
      // wired-but-hidden or half-hidden, its tokens would show here.
      expectTextFreeOf(
        'cliHelpText',
        hostCapabilityCatalog[HostCapability.jsApps]!.surface,
        cliHelpText('0.0.0-test'),
      );
    });

    test('jsr token ownership: the CLI pass-through is wired, the '
        'browser-API row stays hidden', () {
      // #1062 wired `fa jsr` + `/jsr` into the CLI — they belong to
      // jsExtensions (wired on the CLI), never to js_apps. The absence
      // half of js_apps is covered by the preceding help-text test; this
      // one pins the split itself.
      final plan = buildFor(cliProfile);
      expectCapabilitySurfaces(plan, HostCapability.jsExtensions);
      expect(plan.surfacedTokens, containsAll({'fa jsr', '/jsr'}));
      expect(cliHelpText('0.0.0-test'), contains('jsr'));
    });

    test(
      'expectTextFreeOf matches on identifier boundaries, not substrings',
      () {
        const surface = CapabilitySurface(tokens: {'task', 'lsp'});
        // Substring hits inside longer identifiers are NOT leaks: 'tasks',
        // 'help'. Standalone occurrences are.
        expectTextFreeOf('boundary probe', surface, 'run the tasks via help');
        expect(
          () => expectTextFreeOf('boundary probe', surface, 'use task here'),
          throwsA(isA<TestFailure>()),
        );
      },
    );

    test('every hidden cell of every built-in profile removes its whole '
        'surface', () {
      for (final profile in builtInProfiles.values) {
        final plan = buildFor(profile);
        for (final entry in plan.hidden) {
          expectCapabilityHidden(plan, entry.capability);
        }
      }
    });

    test('🔀 surfaces only the chosen transports (mcp on iOS)', () {
      final plan = buildFor(iosProfile);
      expectCapabilitySurfaces(
        plan,
        HostCapability.mcp,
        transports: {'remote'},
      );
    });

    test('positive control: the CLI plan really surfaces its tokens', () {
      final plan = buildFor(cliProfile);
      expectCapabilitySurfaces(
        plan,
        HostCapability.mcp,
        transports: {'stdio', 'remote'},
      );
      expectCapabilitySurfaces(plan, HostCapability.webSearch);
      expectCapabilitySurfaces(plan, HostCapability.backgroundShellJobs);
      expectCapabilitySurfaces(plan, HostCapability.jsExtensions);
      expect(
        plan.surfacedTokens,
        containsAll({'discover_tools', 'bash_job', 'mcp:stdio', 'mcp:remote'}),
      );
    });
  });

  group('builder — platform services (E1 embryo)', () {
    test('a missing service fails loudly, naming every gap', () {
      try {
        HostWiringBuilder(profile: cliProfile).build();
        fail('build() must reject a host that forgot its platform services');
      } on HostWiringException catch (e) {
        for (final service in cliPlatformServices.keys) {
          expect(e.message, contains(service));
        }
      }
    });

    test('a partially served profile names exactly what is missing', () {
      try {
        HostWiringBuilder(
          profile: cliProfile,
          platformServices: {'mcpTransportFactory': Object()},
        ).build();
        fail('build() must reject');
      } on HostWiringException catch (e) {
        expect(e.message, contains('hubFabric'));
        expect(
          e.message,
          isNot(contains('mcpTransportFactory')),
          reason: 'provided services must not be reported missing',
        );
      }
    });

    test('the plan carries the platform services for the slice-2 wiring', () {
      final plan = buildFor(cliProfile);
      expect(plan.platformServices, same(fullPlatformServices));
    });

    test('a sqljs-only web host needs no lsp process factory (E1 '
        'by-transport)', () {
      // webProfile pins sqlite_lsp_dap to transport({sqljs}): the
      // sql.js-backed engine is required, the process lsp factory is not —
      // the cell's transports subset the required set.
      final plan = HostWiringBuilder(
        profile: webProfile,
        platformServices: {...fullPlatformServices}
          ..remove('lspTransportFactory'),
      ).build();
      expect(plan.planFor(HostCapability.sqliteLspDap), isA<WiredCapability>());
    });

    test('a profile wiring fewer capabilities needs fewer services', () {
      // The extension profile wires only hub messaging, remote MCP, the
      // extension runtime, on-device inference and the js-app subset.
      final plan = HostWiringBuilder(
        profile: extensionProfile,
        platformServices: {
          'hubFabric': Object(),
          'mcpTransportFactory': Object(),
          'extRuntimeFactory': Object(),
          'onDeviceProviderFactory': Object(),
          'dynamicMessageSink': Object(),
        },
      ).build();
      expect(plan.planFor(HostCapability.compaction), isA<HiddenCapability>());
    });
  });
}

String _cell(HostCapability capability, String platform, String expected) =>
    '$platform/${capability.id} must be $expected (issue #1079 matrix)';
