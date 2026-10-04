// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1164 Part C: the pre-flight gate on the app handover path — the
/// `open_app` tool call NEVER returns success for an app whose JS fails to
/// load/render or whose test is red (the "no fake success" contract, AC7).
///
/// Gate selection (AC10):
///
/// 1. **`flutter-test`** — the app's standing test `test/apps/<id>_test.dart`
///    exists AND the host provides a [FlutterTestRunner] (it can spawn the
///    toolchain). A red test fails with the failure excerpt.
/// 2. **`smoke-render`** — everywhere else (sandboxed hosts cannot run
///    `flutter test`): the app boots headlessly in a real JS engine; the
///    gate requires a first render with no captured error within the
///    budget. A load-time throw, a `jsr.showError`, or "no render at all"
///    (a syntax error) fails with the excerpt.
///
/// The gate never degrades to a silent skip: every outcome NAMES the gate
/// that ran, and the failure text carries the error excerpt.
///
/// Web safety: the native-bridge probe ([jsEngineBootable]) lives in a
/// conditional-import pair (`app_preflight_probe_io.dart` /
/// `app_preflight_probe_stub.dart`) — dart:ffi has no web target, and on
/// the web the JS engine ships inside the page bundle anyway (the stub
/// reports bootable). The gate itself (engine boot + tree read) is pure
/// Dart and compiles for every surface.
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/apps/app_preflight_probe_stub.dart'
    if (dart.library.io) 'package:fa/apps/app_preflight_probe_io.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';

export 'package:fa/apps/app_preflight_probe_stub.dart'
    if (dart.library.io) 'package:fa/apps/app_preflight_probe_io.dart';

/// The outcome of one gate run; [gate] is always named.
sealed class AppPreflightOutcome {
  const AppPreflightOutcome({required this.gate});

  /// Which gate ran: `flutter-test` or `smoke-render`.
  final String gate;
}

/// The app passed its gate (green test, or a clean first render).
class AppPreflightPassed extends AppPreflightOutcome {
  const AppPreflightPassed({required super.gate});

  @override
  String toString() => 'pre-flight $gate: passed';
}

/// The app failed its gate; [excerpt] is the bounded failure text for the
/// tool result (AC7: the tool result itself is a failure carrying the
/// error).
class AppPreflightFailed extends AppPreflightOutcome {
  const AppPreflightFailed({required super.gate, required this.excerpt});

  final String excerpt;

  @override
  String toString() => 'pre-flight $gate failed:\n$excerpt';
}

/// The seam the gate uses to run `flutter test test/apps/<id>_test.dart`
/// on hosts that can spawn the toolchain. Null on sandboxed hosts → the
/// gate degrades to the named smoke-render gate (AC10).
abstract class FlutterTestRunner {
  /// Runs the app's standing test and returns the (bounded) output.
  Future<FlutterTestResult> runAppTest(String appId);
}

/// Result of one [FlutterTestRunner] invocation.
class FlutterTestResult {
  const FlutterTestResult({required this.passed, required this.output});

  final bool passed;

  /// Bounded stdout/stderr excerpt (already capped by the runner).
  final String output;
}

/// A captured JS error for the smoke gate; [revision] is the app's source
/// revision at boot, so the gate summary can name the exact source that
/// failed.
class SmokeProbeError {
  const SmokeProbeError({required this.event, required this.revision});

  final JsAppErrorEvent event;
  final String revision;
}

/// Boots the app headlessly in a real JS engine on a SCRATCH COPY of the
/// app folder (the app's own files are never touched) and requires a first
/// render with no captured error within [renderBudget]. Mirrors the
/// js_app_engine suite's boot recipe so the smoke gate sees exactly what
/// the real launcher would.
Future<AppPreflightOutcome> runSmokeRenderGate(
  JsAppInfo app,
  ExecutionEnv env, {
  JsAppEngine Function({
    required JsAppInfo app,
    required ExecutionEnv env,
    required AppPermissions permissions,
    String entryFile,
    void Function(JsAppErrorEvent event)? errorSink,
  })?
  engineFactory,
  Duration renderBudget = const Duration(seconds: 10),
}) async {
  final errors = <SmokeProbeError>[];
  JsAppEngine? engine;
  final scratch = MemoryExecutionEnv();
  try {
    // Copy ONLY the app folder — the smoke run must never touch the
    // app's real storage or files.
    final result = await scratch.copyTreeFrom(env, app.dir);
    if (result.isErr) {
      return const AppPreflightFailed(
        gate: 'smoke-render',
        excerpt: 'smoke setup failed: could not stage the app copy',
      );
    }
    engine = (engineFactory ?? _defaultEngineFactory)(
      app: JsAppInfo(
        id: app.id,
        dir: app.dir,
        name: app.name,
        description: app.description,
        version: app.version,
        icon: app.icon,
        accent: app.accent,
        permissions: app.permissions,
        entryPoints: app.entryPoints,
        sourceUrl: app.sourceUrl,
      ),
      env: scratch,
      permissions: app.permissions,
      entryFile: app.entryFileFor(defaultEntryFile),
      errorSink: (event) => errors.add(
        SmokeProbeError(event: event, revision: engine?.sourceRevision ?? ''),
      ),
    );
    try {
      await engine.start();
    } on Object catch (error) {
      return AppPreflightFailed(
        gate: 'smoke-render',
        excerpt: 'engine boot failed: $error',
      );
    }
    final rendered = await _awaitFirstRender(engine, renderBudget);
    if (rendered == null) {
      final excerpt = errors.isNotEmpty
          ? 'no first render within ${renderBudget.inSeconds}s; captured '
                'error: ${errors.first.event.message}'
          : 'no first render within ${renderBudget.inSeconds}s (a syntax '
              'error in the entry usually produces no render at all)';
      return AppPreflightFailed(gate: 'smoke-render', excerpt: excerpt);
    }
    if (errors.isNotEmpty) {
      return AppPreflightFailed(
        gate: 'smoke-render',
        excerpt:
            'rendered with a captured error: ${errors.first.event.message}',
      );
    }
    return const AppPreflightPassed(gate: 'smoke-render');
  } finally {
    await engine?.dispose();
    scratch.dispose();
  }
}

JsAppEngine _defaultEngineFactory({
  required JsAppInfo app,
  required ExecutionEnv env,
  required AppPermissions permissions,
  String entryFile = defaultEntryFile,
  void Function(JsAppErrorEvent event)? errorSink,
}) => JsAppEngine(
  app: app,
  env: env,
  permissions: permissions,
  entryFile: entryFile,
  errorSink: errorSink,
);

Future<bool> _awaitFirstRender(JsAppEngine engine, Duration budget) {
  if (engine.tree.value != null) return Future.value(true);
  final completer = Completer<bool>();
  Timer? timeout;
  late void Function() listener;
  listener = () {
    if (engine.tree.value != null && !completer.isCompleted) {
      completer.complete(true);
    }
  };
  engine.tree.addListener(listener);
  timeout = Timer(budget, () {
    engine.tree.removeListener(listener);
    if (!completer.isCompleted) completer.complete(false);
  });
  return completer.future.whenComplete(() {
    timeout.cancel();
    engine.tree.removeListener(listener);
  });
}

/// Runs the pre-flight gate for [appId]: the app's standing test when the
/// host can run it, otherwise the in-engine smoke render (AC10 — the tool
/// result names which gate ran). Returns null when the app has no gate at
/// all: no test file AND a host where no JS engine can boot (bare CI
/// runners) — installing a gate there would report every healthy app
/// broken (a host-capability error masquerading as an app error).
Future<AppPreflightOutcome?> runAppPreflight(
  String appId,
  ExecutionEnv env, {
  FlutterTestRunner? testRunner,
  Future<AppPreflightOutcome> Function(
    JsAppInfo app,
    ExecutionEnv env,
  )?
  smokeProbe,
  bool? jsEngineBootableOverride,
}) async {
  final lookup = await JsAppsStore(env).byId(appId);
  final app = lookup.getOrNull;
  if (app == null) {
    return const AppPreflightFailed(
      gate: 'none',
      excerpt: 'app not found',
    );
  }
  final hasTest = (await env.listDir('test/apps')).getOrNull?.any(
        (entry) => entry.name == '${app.id}_test.dart',
      ) ??
      false;
  if (testRunner != null && hasTest) {
    final result = await testRunner.runAppTest(app.id);
    if (!result.passed) {
      return AppPreflightFailed(
        gate: 'flutter-test',
        excerpt: result.output,
      );
    }
    return const AppPreflightPassed(gate: 'flutter-test');
  }
  if (!(jsEngineBootableOverride ?? jsEngineBootable)) return null;
  return (smokeProbe ?? runSmokeRenderGate)(app, env);
}
