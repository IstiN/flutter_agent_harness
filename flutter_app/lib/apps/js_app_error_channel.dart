// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// gh-1164 Part B: the app-wide channel carrying JS app render/runtime
/// errors from the engines to the authoring session.
///
/// Engines capture the runtime's crash surfaces (the bootstrap's structured
/// `faAppError:` console records, bootstrap failures, host render
/// exceptions) and forward RAW [JsAppErrorEvent]s here; the channel's
/// [JsAppErrorFeedback] gate decides delivery — one report per
/// (app, error fingerprint) until the app source revision changes, a
/// per-app circuit breaker after repeated unacted revisions (AC4). The
/// subscribed host (AgentService) delivers the report as a failed-turn
/// system notice: steering mid-run, a fresh turn while idle (AC5).
///
/// Engines constructed with an explicit `errorSink` (the pre-flight smoke
/// gate) deliver to that sink INSTEAD, so a gate's probing boots never
/// publish into the live session.
class JsAppErrorChannel {
  /// Creates a channel with its own gate + broadcast stream. Production
  /// code uses [instance]; tests create isolated channels.
  JsAppErrorChannel();

  /// The app-wide channel every production engine publishes into.
  static final JsAppErrorChannel instance = JsAppErrorChannel();

  final StreamController<JsAppErrorReport> _controller =
      StreamController<JsAppErrorReport>.broadcast();

  /// The delivery gate (dedup + circuit breaker, AC4). Shared by every
  /// engine surface of an app, so a launcher tile and the fullscreen view
  /// reporting the same error deliver once.
  final JsAppErrorFeedback gate = JsAppErrorFeedback();

  /// Delivered reports (already deduped by [gate]).
  Stream<JsAppErrorReport> get stream => _controller.stream;

  /// Forwards one raw engine event through the gate.
  void reportAppError(
    JsAppErrorEvent event, {
    required String appId,
    required String surface,
    required String sourceRevision,
  }) {
    final report = gate.observe(
      appId: appId,
      surface: surface,
      kind: event.kind,
      message: event.message,
      stack: event.stack,
      sourceRevision: sourceRevision,
    );
    if (report != null) _controller.add(report);
  }

  /// The app's source was restored to a known-good baseline (demo reset,
  /// catalog reinstall) — drop its gate history so fresh errors report.
  void resetApp(String appId) => gate.resetApp(appId);

  /// Closes the broadcast stream (test teardown only — [instance] lives
  /// for the process).
  Future<void> close() => _controller.close();
}
