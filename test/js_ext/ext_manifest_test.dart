import 'dart:convert';

import 'package:flutter_agent_harness/src/js_ext/ext_manifest.dart';
import 'package:test/test.dart';

void main() {
  group('ExtensionManifest.fromJson', () {
    test('parses a full manifest', () {
      final manifest = ExtensionManifest.fromJson({
        'name': 'crap-guard',
        'kind': 'hybrid',
        'version': '1.2.3',
        'description': 'Guard',
        'platforms': ['CLI', 'macOS'],
        'capabilities': {
          'exec': {
            'allowedCommands': ['dart', 'git status'],
          },
          'fs': {'read': true},
          'hooks': ['afterToolCall', 'onSessionEnd'],
          'network': true,
          'keys': true,
          'tools': true,
          'menus': true,
          'vendorFuture': {'anything': 1},
        },
      });
      expect(manifest.name, 'crap-guard');
      expect(manifest.kind, ExtKind.hybrid);
      expect(manifest.version, '1.2.3');
      expect(manifest.description, 'Guard');
      expect(manifest.platforms, {ExtPlatformTag.cli, ExtPlatformTag.macos});
      expect(manifest.capabilities.network, isTrue);
      expect(manifest.capabilities.allowedCommands, {'dart', 'git status'});
      expect(manifest.capabilities.fs, isTrue);
      expect(manifest.capabilities.hooks, {
        ExtHookEvent.afterToolCall,
        ExtHookEvent.sessionEnd,
      });
      expect(manifest.capabilities.keys, isTrue);
      expect(manifest.capabilities.tools, isTrue);
      expect(manifest.capabilities.menus, isTrue);
      expect(manifest.supportsPlatform(ExtPlatformTag.cli), isTrue);
      expect(manifest.supportsPlatform(ExtPlatformTag.linux), isFalse);
    });

    test('kind absent => widget (back-compat)', () {
      final manifest = ExtensionManifest.fromJson({
        'name': 'tiny',
        'version': '0.1.0',
      });
      expect(manifest.kind, ExtKind.widget);
      expect(manifest.capabilities, const ExtCapabilities());
      expect(manifest.platforms, isNull);
      expect(manifest.supportsPlatform(ExtPlatformTag.web), isTrue);
      expect(manifest.description, isNull);
    });

    test("accepts 'id' alias for name", () {
      final manifest = ExtensionManifest.fromJson({
        'id': 'aliased',
        'version': '1.0.0',
      });
      expect(manifest.name, 'aliased');
    });

    test('flat capability forms', () {
      final manifest = ExtensionManifest.fromJson({
        'name': 'flat',
        'version': '1.0.0',
        'capabilities': {
          'network': true,
          'keys': true,
          'tools': true,
          'menus': true,
          'fs': true,
          'allowedCommands': ['dart'],
        },
      });
      expect(manifest.capabilities.network, isTrue);
      expect(manifest.capabilities.keys, isTrue);
      expect(manifest.capabilities.tools, isTrue);
      expect(manifest.capabilities.menus, isTrue);
      expect(manifest.capabilities.fs, isTrue);
      expect(manifest.capabilities.allowedCommands, {'dart'});
      expect(manifest.capabilities.hooks, isEmpty);
    });

    test('fs bool form', () {
      final on = ExtensionManifest.fromJson({
        'name': 'fs-on',
        'version': '1.0.0',
        'capabilities': {'fs': true},
      });
      expect(on.capabilities.fs, isTrue);
      final off = ExtensionManifest.fromJson({
        'name': 'fs-off',
        'version': '1.0.0',
        'capabilities': {
          'fs': {'read': false},
        },
      });
      expect(off.capabilities.fs, isFalse);
    });

    test('fs true only when read===true in nested form', () {
      final manifest = ExtensionManifest.fromJson({
        'name': 'fs-nested',
        'version': '1.0.0',
        'capabilities': {
          'fs': {'read': true},
        },
      });
      expect(manifest.capabilities.fs, isTrue);
    });

    test('toJson/fromJson round-trip', () {
      final manifest = ExtensionManifest.fromJson({
        'name': 'round-trip',
        'kind': 'cli-extension',
        'version': '2.0.0',
        'description': 'd',
        'platforms': ['cli', 'linux'],
        'capabilities': {
          'exec': {
            'allowedCommands': ['git'],
          },
          'hooks': ['onSteering'],
          'network': true,
        },
      });
      final back = ExtensionManifest.fromJson(
        jsonDecode(jsonEncode(manifest.toJson())) as Map<String, dynamic>,
      );
      expect(back.name, manifest.name);
      expect(back.kind, manifest.kind);
      expect(back.version, manifest.version);
      expect(back.description, manifest.description);
      expect(back.platforms, manifest.platforms);
      expect(back.capabilities, manifest.capabilities);
    });

    test('accumulates EVERY problem (E12)', () {
      late ExtManifestException caught;
      try {
        ExtensionManifest.fromJson(const {
          'name': 'Bad_Name',
          'kind': 'daemon',
          'version': '',
          'description': 3,
          'platforms': ['toaster', 'cli'],
          'capabilities': {
            'network': 'yes',
            'hooks': ['onSessionStart', 'onTeaTime', 5],
            'fs': 2,
            'exec': 'dart',
          },
        });
        fail('expected ExtManifestException');
      } on ExtManifestException catch (e) {
        caught = e;
      }
      void expectProblem(String substring) {
        expect(
          caught.problems.any((p) => p.contains(substring)),
          isTrue,
          reason: 'missing problem "$substring" in: ${caught.problems}',
        );
      }

      expectProblem('invalid name');
      expectProblem('unknown kind: daemon');
      expectProblem('version must be non-empty');
      expectProblem('description must be a string');
      expectProblem('unknown platform: toaster');
      expectProblem('capabilities.network must be a boolean');
      expectProblem('unknown hook event: onTeaTime');
      expectProblem('capabilities.hooks entries must be strings');
      expectProblem('capabilities.fs must be a boolean or an object');
      expectProblem('capabilities.exec must be an object');
      expect(caught.toString(), contains('invalid extension manifest'));
    });

    test('missing name and missing version are problems', () {
      expect(
        () => ExtensionManifest.fromJson(const {'kind': 'widget'}),
        throwsA(
          isA<ExtManifestException>().having(
            (e) => e.problems,
            'problems',
            containsAll(['name is required', 'version is required']),
          ),
        ),
      );
    });

    test('invalid name pattern and wrong name type', () {
      expect(
        () =>
            ExtensionManifest.fromJson(const {'name': 'X', 'version': '1.0.0'}),
        throwsA(
          isA<ExtManifestException>().having(
            (e) => e.problems.single,
            'problem',
            contains('invalid name'),
          ),
        ),
      );
      expect(
        () => ExtensionManifest.fromJson(const {'id': 7, 'version': '1'}),
        throwsA(
          isA<ExtManifestException>().having(
            (e) => e.problems.single,
            'problem',
            'name must be a string',
          ),
        ),
      );
    });
  });

  group('json name helpers', () {
    test('kind round-trips through json names', () {
      for (final kind in ExtKind.values) {
        expect(extKindFromJsonName(extKindJson(kind)), kind);
      }
      expect(extKindFromJsonName('widget-app'), isNull);
    });

    test('hook events round-trip through json names', () {
      for (final event in ExtHookEvent.values) {
        expect(extHookEventFromJsonName(extHookEventJson(event)), event);
      }
      expect(extHookEventFromJsonName('sessionStart'), isNull);
    });

    test('platform tags parse case-insensitively', () {
      expect(extPlatformTagFromJsonName('CLI'), ExtPlatformTag.cli);
      expect(extPlatformTagFromJsonName('MacOS'), ExtPlatformTag.macos);
      expect(extPlatformTagFromJsonName('toaster'), isNull);
    });

    test('ExtCapabilities equality on all fields', () {
      const a = ExtCapabilities(network: true, allowedCommands: {'dart'});
      expect(
        a,
        const ExtCapabilities(allowedCommands: {'dart'}, network: true),
      );
      expect(a, isNot(const ExtCapabilities(network: true)));
      expect(
        a,
        isNot(const ExtCapabilities(network: true, allowedCommands: {'git'})),
      );
      expect(
        const ExtCapabilities(hooks: {ExtHookEvent.onSteering}),
        const ExtCapabilities(hooks: {ExtHookEvent.onSteering}),
      );
      expect(
        const ExtCapabilities(hooks: {ExtHookEvent.onSteering}),
        isNot(const ExtCapabilities(hooks: {ExtHookEvent.sessionEnd})),
      );
    });
  });
}
