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

/// The app passed its gate.
final class AppPreflightOk extends AppPreflightOutcome {
  const AppPreflightOk({required super.gate});
}

/// The app FAILED its gate — [excerpt] is the error/test failure text the
/// tool result carries (bounded).
final class AppPreflightFailure extends AppPreflightOutcome {
  const AppPreflightFailure({required super.gate, required this.excerpt});

  final String excerpt;

  /// Cap on the excerpt a tool result embeds.
  static const int maxExcerptChars = 2000;
}

/// Runs the app's standing test file; hosts that can spawn the Flutter
/// toolchain provide this seam. Returns the outcome with gate
/// `flutter-test`.
typedef FlutterTestRunner =
    Future<AppPreflightOutcome> Function(ExecutionEnv env, String testPath);

/// Overrides the default smoke probe (tests inject a fake so gate
/// selection is testable without a JS engine).
typedef SmokeRenderRunner =
    Future<AppPreflightOutcome> Function(
      ExecutionEnv env,
      JsAppInfo app, {
      required Duration budget,
    });

/// The app's standing acceptance test path (the skill teaches extending it
/// — AC9: the SAME file is reused across iterations).
String appTestPath(String appId) => 'test/apps/${appId}_test.dart';

/// Joins [cwd] and [relative] without doubling the separator (env cwds are
/// often `/` in tests and sandboxes).
String joinEnvPath(String cwd, String relative) =>
    cwd.endsWith('/') ? '$cwd$relative' : '$cwd/$relative';

/// Runs the pre-flight gate for [app] against [env].
///
/// With a test file present AND a [testRunner] wired → `flutter-test`;
/// anything else → the default [smokeRenderApp] probe (or [smokeRender]
/// override in tests). The outcome names the gate either way.
Future<AppPreflightOutcome> runAppPreflight(
  ExecutionEnv env,
  JsAppInfo app, {
  FlutterTestRunner? testRunner,
  SmokeRenderRunner? smokeRender,
  Duration renderBudget = const Duration(seconds: 10),
}) async {
  final testFile = joinEnvPath(env.cwd, appTestPath(app.id));
  if (testRunner != null && (await env.exists(testFile)).valueOrNull == true) {
    return testRunner(env, appTestPath(app.id));
  }
  final runner = smokeRender ?? smokeRenderApp;
  return runner(env, app, budget: renderBudget);
}

/// The default smoke probe: boots the app headlessly in a real JS engine
/// against an in-memory copy of the app folder and requires a first render
/// with no captured error within [budget].
Future<AppPreflightOutcome> smokeRenderApp(
  ExecutionEnv env,
  JsAppInfo app, {
  required Duration budget,
}) async {
  final scratch = MemoryExecutionEnv(cwd: env.cwd);
  try {
    final copied = await _copyDir(env, scratch, app.dir);
    if (!copied) {
      return AppPreflightFailure(
        gate: 'smoke-render',
        excerpt:
            'app folder ${app.dir} could not be read for the '
            'pre-flight smoke render',
      );
    }
    final errors = <JsAppErrorEvent>[];
    final engine = JsAppEngine(
      app: app,
      env: scratch,
      permissions: app.declaredPermissions,
      errorSink: errors.add,
    );
    try {
      await engine.start();
    } on Object catch (error) {
      // Bootstrap failure (Dart-side start throw): a load error.
      return AppPreflightFailure(
        gate: 'smoke-render',
        excerpt: 'bootstrap failed: $error',
      );
    }
    final rendered = Completer<void>();
    void listener() {
      if (engine.tree.value != null && !rendered.isCompleted) {
        rendered.complete();
      }
    }

    engine.tree.addListener(listener);
    try {
      await Future.any([
        if (engine.tree.value != null) Future<void>.value(),
        rendered.future,
        Future<void>.delayed(budget),
      ]);
      if (errors.isNotEmpty) {
        return AppPreflightFailure(
          gate: 'smoke-render',
          excerpt:
              '${errors.first.message}'
              '${errors.first.stack.isEmpty ? '' : '\n${errors.first.stack}'}',
        );
      }
      if (engine.tree.value == null) {
        return AppPreflightFailure(
          gate: 'smoke-render',
          excerpt:
              'no render within the ${budget.inSeconds}s budget — the entry '
              'file never produced a UI tree (a syntax error compiles to '
              'nothing; read ${app.widgetPath} back and check it)',
        );
      }
      return const AppPreflightOk(gate: 'smoke-render');
    } finally {
      engine.tree.removeListener(listener);
      await engine.dispose();
    }
  } finally {
    // The probe never touches the app's own storage: it ran on scratch.
    await scratch.remove(app.dir, recursive: true, force: true);
  }
}

/// Copies one directory tree from [from] into [to] (recursive, bounded by
/// a file count to keep the probe cheap). Returns false when the root is
/// missing.
Future<bool> _copyDir(
  ExecutionEnv from,
  ExecutionEnv to,
  String path, {
  int budget = 64,
}) async {
  final listing = await from.listDir(path);
  final entries = listing.valueOrNull;
  if (entries == null) return false;
  if ((await to.exists(path)).valueOrNull != true) {
    await to.createDir(path, recursive: true);
  }
  for (final entry in entries) {
    if (budget <= 0) break;
    if (entry.kind == FileKind.directory) {
      final copied = await _copyDir(from, to, entry.path, budget: budget - 1);
      budget -= 1;
      if (!copied) continue;
    } else {
      final text = await from.readTextFile(entry.path);
      final content = text.valueOrNull;
      if (content != null) {
        await to.writeFile(entry.path, content);
      } else {
        final binary = await from.readBinaryFile(entry.path);
        final bytes = binary.valueOrNull;
        if (bytes != null) await to.writeBinaryFile(entry.path, bytes);
      }
      budget -= 1;
    }
  }
  return true;
}

/// The [AppPreflight] callback shape `open_app` accepts: runs the gate and
/// hands the outcome back to the tool.
typedef AppPreflight = Future<AppPreflightOutcome> Function(JsAppInfo app);

/// Whether the JS engine the smoke probe boots can load its native bridge
/// Builds the pre-flight callback AgentService wires into `open_app`:
/// the service's env, the default test-runner seam (null on sandboxed
/// hosts → the gate degrades to the named smoke render), the default
/// smoke probe.
///
/// Returns null when this host cannot boot the JS engine at all
/// ([jsEngineBootable] false — bare CI runners): no gate is installed
/// rather than a gate that reports every healthy app as broken. Tests
/// force the branch with [jsEngineBootableOverride].
AppPreflight? defaultAppPreflight(
  ExecutionEnv env, {
  FlutterTestRunner? testRunner,
  bool? jsEngineBootableOverride,
}) {
  if (!(jsEngineBootableOverride ?? jsEngineBootable)) return null;
  return (app) => runAppPreflight(env, app, testRunner: testRunner);
}

/// Bounded excerpt for tool results (never a silent cut — the cap is
/// announced inside the text).
String preflightExcerptForTool(AppPreflightFailure failure) {
  var text = failure.excerpt;
  if (text.length > AppPreflightFailure.maxExcerptChars) {
    text =
        '${text.substring(0, AppPreflightFailure.maxExcerptChars)}… '
        '(truncated from ${text.length} chars)';
  }
  return 'pre-flight gate (${failure.gate}) FAILED:\n$text';
}
