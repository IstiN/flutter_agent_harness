// PR #1227 rework (gh-1096 AC4): dropping `s.vendored_frameworks` from
// vendor/wasm_run_flutter/macos/wasm_run_flutter.podspec turned the
// `Build macOS (debug)` CI leg red. The pod target still compiled
// Classes/EnforceBundling.swift, whose `dummy_method_to_enforce_bundling()`
// references ~200 flutter_rust_bridge symbols (_wire_*, _new_*, _drop_*, …)
// that ONLY the removed vendored dynamic framework used to satisfy at the
// pod-target link step:
//
//   Pods.xcodeproj: wasm_run_flutter: Undefined symbols for architecture
//   arm64: "_drop_dart_object", … referenced from:
//   _dummy_method_to_enforce_bundling in EnforceBundling.o
//
// On macOS the app does NOT need the EnforceBundling dummy: the Runner
// target force_loads WasmRun.xcframework's libwasm_run_dart.a and exports
// every C-ABI symbol (flutter_app/macos/Podfile), and package:wasm_run
// resolves them at runtime via DynamicLibrary.executable(). EnforceBundling
// is the iOS mechanism (the app there statically links the pod's vendored
// framework and the dummy keeps dead-code stripping from discarding the
// wire_* roots); it must not ride in the macOS pod once the framework is
// gone. Static lint over the vendored pod, same style as
// wasmrun_restore_budget_test.dart.
import 'dart:io';

import 'package:test/test.dart';

const podspecPath = 'vendor/wasm_run_flutter/macos/wasm_run_flutter.podspec';
const classesDir = 'vendor/wasm_run_flutter/macos/Classes';
const podfilePath = 'flutter_app/macos/Podfile';

void main() {
  group(
    'wasm_run_flutter macOS pod stays linkable without a vendored framework',
    () {
      test('podspec vendors no framework or library (AC4 size diet)', () {
        final podspec = File(podspecPath).readAsStringSync();
        // Ignore comment prose — the podspec itself documents the removal.
        final code = podspec
            .split('\n')
            .where((l) => !l.trimLeft().startsWith('#'))
            .join('\n');
        expect(
          code.contains('vendored_frameworks'),
          isFalse,
          reason:
              '$podspecPath must not vendor WasmRun.xcframework — the '
              '27 MB wasm_run_flutter.framework was a never-loaded fallback '
              '(gh-1096 AC4). The XCFramework download block stays only so '
              'the static archive feeds the Podfile force_load.',
        );
        expect(
          code.contains('vendored_libraries'),
          isFalse,
          reason:
              '$podspecPath must not vendor libwasm_run_dart.a either: '
              'statically linking the rust archive into the pod framework '
              'would recreate the bloat AC4 removed (dead-code stripping '
              'cannot discard it — EnforceBundling references the symbols).',
        );
      });

      test(
        'macOS pod compiles no sources referencing wasm_run FFI symbols',
        () {
          final dir = Directory(classesDir);
          expect(dir.existsSync(), isTrue, reason: '$classesDir must exist');
          final compiled = dir
              .listSync(recursive: true)
              .whereType<File>()
              .where(
                (f) =>
                    f.path.endsWith('.swift') ||
                    f.path.endsWith('.m') ||
                    f.path.endsWith('.mm') ||
                    f.path.endsWith('.c') ||
                    f.path.endsWith('.cpp'),
              )
              .toList(growable: false);
          expect(
            compiled,
            isEmpty,
            reason:
                'With no vendored framework/library, the pod target links '
                'nothing that defines the flutter_rust_bridge symbols '
                '(_wire_*/_new_*/_drop_*/dummy_method_to_enforce_bundling). '
                'Any compiled translation unit referencing them fails the '
                'pod-target link with "Undefined symbols for architecture '
                'arm64 … in EnforceBundling.o" — the PR #1227 red leg. On '
                'macOS the Runner provides the symbols via force_load + '
                'exported_symbol (see $podfilePath), so the EnforceBundling '
                'dummy (an iOS mechanism) must not be compiled here. '
                'Offending files: '
                '${compiled.map((f) => f.path).join(', ')}',
          );
          // The header must stay: it is the package's public FFI surface and
          // keeps the pod non-empty so `pod install` materializes the target.
          final headers = dir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.h'))
              .toList(growable: false);
          expect(headers, isNotEmpty, reason: '$classesDir keeps frb.h');
        },
      );

      test('Podfile still force_loads + exports the static archive', () {
        // Guard the provider side of the invariant: if the pod compiles no
        // code, the ONLY source of the FFI symbols is the Runner link.
        final podfile = File(podfilePath).readAsStringSync();
        expect(
          podfile.contains('-force_load'),
          isTrue,
          reason:
              '$podfilePath must force_load '
              'WasmRun.xcframework/macos-arm64_x86_64/libwasm_run_dart.a — '
              'otherwise the wire_* symbols never make it into the '
              'executable and DynamicLibrary.executable() lookups fail at '
              'runtime (the PR #1227 build would link but boot broken).',
        );
        expect(
          podfile.contains('exported_symbol'),
          isTrue,
          reason:
              '$podfilePath must export the FFI symbols in non-Debug '
              'configs (Debug exports all globals by default); dlsym only '
              'sees exported symbols.',
        );
      });
    },
  );
}
