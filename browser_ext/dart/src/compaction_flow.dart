// The extension SW host's compaction glue (gh-2059): a thin consumer of the
// SDK's shared compaction contract — `resolveExtensionCompactionWiring` for
// every config value, `HostCompactionFlow` for the settle / relief / manual
// paths — plus the host's two visibility channels (`[fah][sw]` console lines
// via providerDebug, panel system notices via the event sink).
//
// agent_host.dart is web-only (package:web via fetch_client), so the glue
// lives here where the VM suite can pin it: wiring resolution, the notice
// channels, and the relief counter the over-window guard contract relies
// on. Pure Dart — no chrome.*, no js_interop.
library;

import 'package:flutter_agent_harness/src/agent/agent.dart' show AgentState;
import 'package:flutter_agent_harness/src/agent/agent_loop.dart'
    show StreamFunction;
import 'package:flutter_agent_harness/src/agent/auto_compactor.dart'
    show AutoCompactorSources;
import 'package:flutter_agent_harness/src/cancel_token.dart' show CancelToken;
import 'package:flutter_agent_harness/src/compaction/host_compaction_flow.dart';
import 'package:flutter_agent_harness/src/compaction/host_wiring.dart';
import 'package:flutter_agent_harness/src/session/session_tree.dart'
    show Session;
import 'package:flutter_agent_harness/src/types.dart' show Message;

import 'providers.dart' show providerDebug;

/// [HostCompactionNotices] over the extension's two channels: every line
/// rides the `[fah][sw]` console + the panel debug relay (AC11 — the SW log
/// alone answers "did a pass run, what did it drop, why did it fail"), and
/// notices surface as panel system events (gh-1077 AC2 shape).
class ExtCompactionNotices implements HostCompactionNotices {
  ExtCompactionNotices({void Function(String text)? notice}) {
    _notice = notice;
  }

  /// The panel system-notice sink; defaults to a log-only impl so a
  /// headless boot (no panel attached) still logs everything.
  void Function(String text)? _notice;

  /// Installs the live panel sink (the host wires its event sink here).
  set noticeSink(void Function(String text)? sink) => _notice = sink;

  /// Panel system-notice tap for tests (the current sink, may be null).
  void Function(String text)? get noticeSinkForTest => _notice;

  @override
  void log(String line) => providerDebug('[fah][sw] $line');

  @override
  void notice(String text) {
    providerDebug('[fah][sw] notice: $text');
    _notice?.call(text);
  }
}

/// The flow factory seam (tests pin the exact construction the host uses).
typedef ExtCompactionFlowFactory =
    HostCompactionFlow Function({
      required Session session,
      required AgentState state,
      required CompactionHostWiring wiring,
      required AutoCompactorSources sources,
      required HostCompactionNotices notices,
    });

HostCompactionFlow _defaultFlow({
  required Session session,
  required AgentState state,
  required CompactionHostWiring wiring,
  required AutoCompactorSources sources,
  required HostCompactionNotices notices,
}) => HostCompactionFlow(
  session: session,
  state: state,
  wiring: wiring,
  sources: sources,
  notices: notices,
);

/// The extension host's compaction controller: resolves the SHARED wiring
/// fresh on every path run (the model swaps live via reconfigure), runs the
/// SDK flow, and exposes the same test seam the app host has (the relief
/// counter). The smol slot IS the main stream — the extension has no roles
/// chain, and `resolveExtensionCompactionWiring` normalizes that shape.
final class ExtCompactionController {
  ExtCompactionController({
    required this.session,
    required this.state,
    required this.stream,
    required this.notices,
    required this.contextWindowCap,
    this.flowFactory = _defaultFlow,
  });

  final Session Function() session;
  final AgentState Function() state;
  final StreamFunction Function() stream;
  final ExtCompactionNotices notices;

  /// The owner cap (`faContextWindowCap` panel setting), read live — a
  /// settings change applies on the next compaction.
  final int? Function() contextWindowCap;

  final ExtCompactionFlowFactory flowFactory;

  /// AC1's relief counter — the extension analogue of the app host's
  /// `overWindowReliefCountForTest`.
  int reliefCountForTest = 0;

  /// The wiring the CURRENT model resolves to (test seam; the parity test
  /// compares this path against the CLI and app resolutions).
  CompactionHostWiring wiringForTest() => resolveExtensionCompactionWiring(
    mainModel: state().model,
    contextWindowCap: contextWindowCap(),
  );

  HostCompactionFlow _flow() => flowFactory(
    session: session(),
    state: state(),
    wiring: wiringForTest(),
    sources: AutoCompactorSources(
      // Extension shape: smol == main (same stream + model) — the wiring
      // normalizes it to the no-fallback single-summarizer run.
      smolStream: stream(),
      smolModel: state().model,
      mainStream: stream(),
      mainModel: state().model,
    ),
    notices: notices,
  );

  /// The post-run settle path (the `AgentSettledEvent` hook).
  Future<HostCompactionReceipt> settle({CancelToken? runToken}) =>
      _flow().settle(runToken: runToken);

  /// The `/compact` path (CLI parity: unconditional).
  Future<HostCompactionReceipt> manual({CancelToken? runToken}) =>
      _flow().manual(runToken: runToken);

  /// The loop guard's relief closure (issue #387): one synchronous
  /// compaction of the over-window transcript, linked to the run's
  /// cancellation token (issue #1085 parity). The counter mirrors the
  /// app host's `overWindowReliefCountForTest`.
  Future<List<Message>?> relieveOverWindow(
    List<Message> overWindow, {
    CancelToken? runToken,
  }) {
    reliefCountForTest++;
    return _flow().relieveOverWindow(overWindow, runToken: runToken);
  }
}
