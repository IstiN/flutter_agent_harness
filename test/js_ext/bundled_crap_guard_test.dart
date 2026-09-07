// Unit tests for the bundled crap-guard reference extension (contract
// section 12): manifest validation, the bundled install plan, a host wiring
// smoke through FakeJsrRuntime, and — when `node` is on PATH — the JS
// behavior suite in test/js_ext/node/.
import 'dart:convert';

import 'package:flutter_agent_harness/src/js_ext/bundled/bundled_exts.dart';
import 'package:flutter_agent_harness/src/js_ext/bundled/crap_guard.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_bootstrap_js.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_bridge.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_install.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_manifest.dart';
import 'package:flutter_agent_harness/src/js_ext/extension_store.dart';
import 'package:flutter_agent_harness/src/js_ext/jsr_runtime.dart';
import 'package:flutter_agent_harness/src/js_ext/trust.dart';
import 'package:test/test.dart';

void main() {
  final manifest = ExtensionManifest.fromJson(
    jsonDecode(kCrapGuardManifestJson) as Map<String, dynamic>,
  );

  group('crap-guard manifest', () {
    test('parses as a cli-extension with the declared capabilities', () {
      expect(manifest.name, 'crap-guard');
      expect(manifest.kind, ExtKind.cliExtension);
      expect(manifest.version, '1.0.0');
      expect(
        manifest.platforms,
        containsAll([
          ExtPlatformTag.cli,
          ExtPlatformTag.macos,
          ExtPlatformTag.linux,
          ExtPlatformTag.windows,
        ]),
      );
      expect(manifest.capabilities.allowedCommands, {'dart'});
      expect(manifest.capabilities.fs, isTrue);
      expect(manifest.capabilities.hooks, {
        ExtHookEvent.afterToolCall,
        ExtHookEvent.sessionEnd,
      });
      // Everything else stays denied: the guard is deliberately minimal.
      expect(manifest.capabilities.network, isFalse);
      expect(manifest.capabilities.keys, isFalse);
      expect(manifest.capabilities.tools, isFalse);
      expect(manifest.capabilities.menus, isFalse);
    });

    test('kBundledExtensions entries carry manifest.json + main.js', () {
      expect(kBundledExtensions.keys, contains('crap-guard'));
      for (final files in kBundledExtensions.values) {
        expect(files.keys, containsAll(['manifest.json', 'main.js']));
        expect(
          () => ExtensionManifest.fromJson(
            jsonDecode(files['manifest.json']!) as Map<String, dynamic>,
          ),
          returnsNormally,
        );
      }
    });
  });

  group('planBundledInstall', () {
    test('returns a bundled-trust plan for crap-guard', () {
      final plan = planBundledInstall('crap-guard');
      expect(plan.name, 'crap-guard');
      expect(plan.files, kBundledExtensions['crap-guard']);
      expect(plan.manifest.name, 'crap-guard');
      expect(plan.manifest.kind, ExtKind.cliExtension);
      expect(plan.trustSource, ExtTrustSource.bundled);
      expect(plan.trustRef, 'bundled');
    });

    test('content sha via extContentHash is deterministic 64-hex', () {
      final plan = planBundledInstall('crap-guard');
      final sha = extContentHash(plan.files);
      expect(sha, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(extContentHash(kBundledExtensions['crap-guard']!), sha);
    });

    test('unknown name throws ExtInstallException', () {
      expect(
        () => planBundledInstall('nope'),
        throwsA(
          isA<ExtInstallException>().having(
            (e) => e.message,
            'message',
            contains('nope'),
          ),
        ),
      );
    });
  });

  group('host wiring smoke (commit payload fixture)', () {
    test('registers exactly the two hooks, no tools/slash/flows', () async {
      final runtime = FakeJsrRuntime('fake');
      addTearDown(runtime.dispose);
      // Dart fixture mimicking what kCrapGuardMainJs registers via
      // jsr.ext.onHook — the payload __extCommit() returns.
      runtime.onGlobal(
        '__extCommit',
        (_) async => const {
          'tools': <Object>[],
          'hooks': [
            {'event': 'afterToolCall', 'handle': 1},
            {'event': 'onSessionEnd', 'handle': 2},
          ],
          'slash': <Object>[],
          'flows': <Object>[],
        },
      );
      await runtime.start(
        bootstrapJs: kExtBootstrapCoreJs,
        mainJs: kCrapGuardMainJs,
        bridges: (method, args) async => null,
      );
      expect(runtime.lastMainJs, kCrapGuardMainJs);

      final commit = parseExtCommit(await runtime.invoke('__extCommit', []));
      expect(commit.tools, isEmpty);
      expect(commit.slash, isEmpty);
      expect(commit.flows, isEmpty);
      expect(commit.hooks.map((h) => h.event).toSet(), {
        ExtHookEvent.afterToolCall,
        ExtHookEvent.sessionEnd,
      });
      // Registered hooks stay inside the declared capability set.
      expect(
        commit.hooks
            .map((h) => h.event)
            .toSet()
            .difference(manifest.capabilities.hooks),
        isEmpty,
      );
    });
  });
}
