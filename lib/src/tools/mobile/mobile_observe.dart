/// The observe-and-act step contract (issue #622, UT-delta-1).
///
/// Steals artemis's loop SHAPE — one step = hierarchy + screenshot
/// captured CONCURRENTLY under a wall-clock budget (~5 s/step) — without
/// its host-driven architecture: our agent loop already exists, this is
/// the single observation step its `mobile.hierarchy {screenshot: true}`
/// call performs.
///
/// Pure Dart: no `dart:io`.
library;

import 'mobile_backend.dart';

/// Default per-step wall-clock budget (artemis's 3–5 s/step envelope).
const defaultMobileObserveBudget = Duration(seconds: 5);

/// One observation step: both captures are dispatched before either is
/// awaited (the concurrency contract), and the step fails with the named
/// `observe-budget-exceeded` state when the wall clock passes [budget].
///
/// [clock] is injectable for tests (fake clock; the production driver
/// passes nothing and gets a fresh [Stopwatch] per step).
Future<MobileObserveResult> mobileObserveStep(
  MobileAutomationBackend automation, {
  Duration budget = defaultMobileObserveBudget,
  Duration Function()? clock,
}) async {
  final watch = Stopwatch()..start();
  final elapsed = clock ?? () => watch.elapsed;
  final started = elapsed();
  final hierarchy = automation.dumpHierarchy();
  final shot = automation.screenshot();
  final xml = await hierarchy;
  final captured = await shot;
  final took = elapsed() - started;
  if (took > budget) {
    throw MobileAutomationException(
      MobileErrorCode.observeBudgetExceeded,
      'observe step exceeded its ${budget.inMilliseconds} ms budget '
      '(${took.inMilliseconds} ms)',
    );
  }
  return MobileObserveResult(xml: xml, screenshot: captured, took: took);
}

/// The outcome of one observe step.
final class MobileObserveResult {
  /// Raw hierarchy XML (parse with `parseMobileHierarchy`).
  final String xml;

  /// The concurrently captured screen.
  final MobileScreenshot screenshot;

  /// Wall-clock time the step took.
  final Duration took;

  const MobileObserveResult({
    required this.xml,
    required this.screenshot,
    required this.took,
  });
}
