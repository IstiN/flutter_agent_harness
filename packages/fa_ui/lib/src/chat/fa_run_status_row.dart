// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show KaomojiFace, KaomojiFacePicker, kKaomojiFaces, kKaomojiSwapPeriod;

import '../theme/app_theme.dart';
import 'chat_strings.dart';
import 'fa_chat_service.dart';
import 'fa_kaomoji.dart';
import 'run_phase.dart';

/// The single transient run-status row (issues #865, #1042): the
/// visually-LAST transcript entry while the run is active, naming the run
/// phase (provider wait / streaming / current tool) with the elapsed
/// seconds on a 1 s tick, driven purely by the service's event sequence
/// via [faRunPhase] — the UI is never silent while the agent works, and
/// on completion the row disappears the same frame the assistant message
/// lands (the ChatGPT-style «last message» pattern: never a
/// composer-docked badge, never a second row — hosts mount exactly this
/// one widget, and it hides itself when the run ends).
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

  /// The kaomoji face the row shows (issue #1374): re-picked on the same
  /// frame clock as the elapsed seconds — a random frame every
  /// [kKaomojiSwapPeriod] — so the row introduces NO timer of its own:
  /// the ticker stops with the phase (AC4), and tests pump the fake
  /// frame clock exactly like they already do for the seconds.
  final KaomojiFacePicker _facePicker = KaomojiFacePicker();
  KaomojiFace _face = kKaomojiFaces[0];
  Duration? _lastFaceSwap;

  void _onTick(Duration elapsed) {
    _lastElapsed = elapsed;
    final seconds = (elapsed - _phaseStart).inSeconds;
    if (seconds != _seconds) setState(() => _seconds = seconds);
    if (_lastFaceSwap == null ||
        elapsed - _lastFaceSwap! >= kKaomojiSwapPeriod) {
      _lastFaceSwap = elapsed;
      setState(() => _face = _facePicker.next());
    }
  }

  /// Resets the phase clock: to the latest tick while running (a stopped
  /// ticker restarts at elapsed zero), else to zero. The face cadence
  /// restarts with it — a fresh phase opens on a fresh random face.
  void _restartClock() {
    _seconds = 0;
    _lastFaceSwap = null;
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
          // Token emission reads «Fa is typing...» (issue #1042 fix
          // contract) — the old standalone typing row's string, reused.
          FaRunPhaseKind.writing => strings.chatTyping,
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
              // The two-tone kaomoji face (issue #1374) replaces the
              // stock spinner: the same random-frame face set the CLI
              // busy row styles, re-picked every ~0.9 s on the row's
              // frame clock — no timer of its own, so an idle row (the
              // ticker is stopped) never animates (AC4). Fixed zone:
              // a swap never moves the label (the #365 fixed-cell rule).
              SizedBox(
                width: kKaomojiFaceTextZoneWidth,
                child: KaomojiFaceText(
                  face: _face,
                  style:
                      theme.textTheme.bodySmall?.copyWith(color: palette.dim),
                ),
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
