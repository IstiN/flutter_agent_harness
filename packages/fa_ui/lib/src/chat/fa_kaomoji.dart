// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show
        KaomojiFace,
        KaomojiFacePicker,
        kKaomojiEyeArgb,
        kKaomojiMouthArgb,
        kKaomojiSwapPeriod,
        kaomojiFaceSvg;

/// The thinking indicator's Flutter rendering (issue #1374): the shared
/// kaomoji face set drawn two-tone in the brand palette, swapping on a
/// RANDOM pick every [kKaomojiSwapPeriod] (~0.9 s) while the phase runs.
/// The face data lives in one pure-Dart source the CLI busy row styles
/// too; this file only renders it — [KaomojiThinkingIcon] for the chat
/// thinking block (the approved SVG sprite frames) and [KaomojiFaceText]
/// for status rows (colored text spans).
///
/// The random-frame owner: re-picks a face through [KaomojiFacePicker]
/// on the shared cadence while [active], and hands it to [builder]. The
/// swap clock (a Ticker on the host's frame clock) runs ONLY while
/// active (AC4) — an idle indicator never animates, and no test ends
/// with a pending timer — and [random] seeds the picks so widget tests
/// are deterministic.
class KaomojiSwapper extends StatefulWidget {
  const KaomojiSwapper({
    super.key,
    required this.builder,
    this.active = true,
    this.random,
  });

  /// Builds the indicator for the current face.
  final Widget Function(BuildContext context, KaomojiFace face) builder;

  /// Whether the watched phase is live. Flipping it false stops the swap
  /// clock on the same frame; the last face stays on screen.
  final bool active;

  /// The randomness source; null seeds from the process entropy. Tests
  /// inject `Random(seed)` for deterministic frames.
  final Random? random;

  @override
  State<KaomojiSwapper> createState() => _KaomojiSwapperState();
}

class _KaomojiSwapperState extends State<KaomojiSwapper>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  late final KaomojiFacePicker _picker = KaomojiFacePicker(widget.random);
  late KaomojiFace _face;
  Duration? _lastSwap;

  @override
  void initState() {
    super.initState();
    _face = _picker.first();
    _syncTicker();
  }

  @override
  void didUpdateWidget(KaomojiSwapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _syncTicker();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  /// The swap clock runs ONLY while the phase is live (issue #1374
  /// AC4) — and it is the same frame clock the status row's elapsed
  /// seconds ride, so the indicator owns NO timer: an idle indicator
  /// never animates, and no test ever ends with a pending timer.
  void _syncTicker() {
    if (widget.active && !_ticker.isActive) {
      _lastSwap = Duration.zero;
      _ticker.start();
    } else if (!widget.active && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    if (_lastSwap != null && elapsed - _lastSwap! < kKaomojiSwapPeriod) {
      return;
    }
    _lastSwap = elapsed;
    setState(() => _face = _picker.next());
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _face);
}

/// The app thinking block's icon (issue #1374 — the head-with-gear spot):
/// the approved SVG sprite frames at [size] (24-grid content scaled to
/// ~90%), swapping on the shared ~0.9 s random cadence while [active].
/// A finished thinking note keeps its last face (the tile stays on
/// screen with [active] false — no timer).
class KaomojiThinkingIcon extends StatelessWidget {
  const KaomojiThinkingIcon({
    super.key,
    this.size = 16,
    // Default FROZEN (PR #1419 re-review round 2): this widget is in the
    // public barrel, and the one configuration AC4 forbids is a call
    // site that forgets `active:` and silently gets an endless ticker.
    // Callers pass `active: isLive` explicitly — ChatMessageTile does.
    this.active = false,
    this.random,
  });

  final double size;

  final bool active;

  /// The randomness source ([KaomojiSwapper]); tests seed it.
  final Random? random;

  @override
  Widget build(BuildContext context) {
    return KaomojiSwapper(
      active: active,
      random: random,
      builder: (_, face) => SizedBox.square(
        // Keyed by the face so tests can read the shown frame without
        // reaching into flutter_svg's provider internals.
        key: ValueKey<KaomojiFace>(face),
        dimension: size,
        child: SvgPicture.string(kaomojiFaceSvg(face), fit: BoxFit.contain),
      ),
    );
  }
}

/// One face as two-tone colored text spans (issue #1374's text
/// rendering for status rows): eyes/face strokes teal, mouths blue —
/// the CLI busy row's ANSI segmentation with the brand palette.
class KaomojiFaceText extends StatelessWidget {
  const KaomojiFaceText({super.key, required this.face, this.style});

  final KaomojiFace face;

  /// The base style; each run overrides the color per its tone. Defaults
  /// to the ambient [DefaultTextStyle].
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    final text = face.text;
    // Degenerate-input guard (PR #1419 re-review round 2): a face with
    // no visible glyphs (empty/whitespace runs) must never crash the
    // status row — fall back to a plain span. Real faces always carry
    // non-empty runs, so production never takes this branch.
    if (text.trim().isEmpty) {
      return Text(
        text,
        style: base,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
      );
    }
    return Text.rich(
      TextSpan(
        children: [
          for (final (text, mouth) in face.runs)
            TextSpan(
              text: text,
              style: base.copyWith(
                color: mouth
                    ? const Color(kKaomojiMouthArgb)
                    : const Color(kKaomojiEyeArgb),
              ),
            ),
        ],
      ),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.visible,
    );
  }
}

/// The fixed face zone for text-mode rows: the widest face (`o_o?`) is 4
/// cells, so a swap inside a box this wide never moves anything right of
/// it (the CLI busy row's fixed-cell rule, issue #365).
const double kKaomojiFaceTextZoneWidth = 32;
