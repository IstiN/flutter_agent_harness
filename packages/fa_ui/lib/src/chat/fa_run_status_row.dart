// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_theme.dart';
import 'chat_strings.dart';
import 'fa_chat_service.dart';
import 'run_phase.dart';

/// The composer-adjacent live status row (issue #865): names the run phase
/// (provider wait / streaming / current tool) with the elapsed seconds on a
/// 1 s tick, driven purely by the service's event sequence via [faRunPhase]
/// — the UI is never silent while the agent works, and the row disappears
/// the frame the run ends.
///
/// Elapsed time counts the CURRENT phase (the clock resets when the phase
/// or the named tool changes) and is derived from the ticker's frame clock
/// — monotonic in the app, and driven by `tester.pump` (a fake clock) in
/// widget tests. The ticker runs only while the row is visible.
class FaRunStatusRow extends StatefulWidget {
  const FaRunStatusRow({super.key, required this.service});

  final FaChatService service;

  @override
  State<FaRunStatusRow> createState() => _FaRunStatusRowState();
}

class _FaRunStatusRowState extends State<FaRunStatusRow>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);

  /// Seconds shown for the current phase.
  int _seconds = 0;

  /// The most recent tick's elapsed value — the phase baseline when the
  /// clock restarts mid-epoch.
  Duration? _lastElapsed;

  /// The ticker-elapsed value the current phase started at.
  Duration _phaseStart = Duration.zero;

  /// The phase the clock is running for — kind + tool identity, NOT the
  /// parallel count: a second tool joining or one finishing must not reset
  /// the elapsed time (E1: no flicker per delta).
  (FaRunPhaseKind, String?)? _clockedPhase;

  void _onTick(Duration elapsed) {
    _lastElapsed = elapsed;
    final seconds = (elapsed - _phaseStart).inSeconds;
    if (seconds != _seconds) setState(() => _seconds = seconds);
  }

  /// Resets the phase clock: to the latest tick while running (a stopped
  /// ticker restarts at elapsed zero), else to zero.
  void _restartClock() {
    _seconds = 0;
    _phaseStart = _ticker.isActive
        ? (_lastElapsed ?? Duration.zero)
        : Duration.zero;
  }

  @override
  void didUpdateWidget(covariant FaRunStatusRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      _clockedPhase = null;
      _restartClock();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final phase = faRunPhase(
          streaming: widget.service.isStreaming,
          messages: widget.service.messages,
        );
        if (phase.kind == FaRunPhaseKind.hidden) {
          _ticker.stop();
          _clockedPhase = null;
          _restartClock();
          return const SizedBox.shrink();
        }
        final clocked = (phase.kind, phase.toolName);
        if (clocked != _clockedPhase) {
          _clockedPhase = clocked;
          _restartClock();
        }
        if (!_ticker.isActive) _ticker.start();
        final strings = FaChatStrings.of(context);
        final label = switch (phase.kind) {
          FaRunPhaseKind.writing => strings.chatStatusWriting,
          FaRunPhaseKind.tool =>
            strings.chatStatusRunningTool(phase.toolName!) +
                (phase.toolCount > 1 ? ' ×${phase.toolCount}' : ''),
          _ => strings.chatStatusThinking,
        };
        final theme = Theme.of(context);
        final palette = fahChatColorsOf(context);
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            key: const ValueKey('faChatRunStatusContent'),
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$label · ${_seconds}s',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.dim,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
