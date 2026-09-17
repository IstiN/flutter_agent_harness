// Frame row renderers for the FA TUI: the inline menu (item window with
// scroll hints + footer hint), the busy/queue block, and the scheduled
// follow-ups indicator.
//
// Lives in a part file to keep fa_tui.dart under the line gate (same
// pattern as composer_overlay.dart / fa_tui_mouse.dart); the render state
// (`_hitRegions`, model fields) is declared on [FaTuiModel] itself —
// extensions cannot add fields.
part of 'fa_tui.dart';

/// Busy-row fixed cells (issue #365): the row used to reflow on every
/// power-of-ten second (digit growth) and on the 180 s quiet-threshold
/// crossing, so everything right of the timer jumped horizontally each
/// tick. Overlong labels (long MCP tool names, compaction tails running
/// counters) ellipsize inside the zone instead of pushing the timer.
const _busyLabelCells = 24;

/// The elapsed field always fits six cells: `0s`…`3599s`, then
/// `1h00m`…`99h59m`, then the `99h+` cap — the layout never reflows.
const _busyElapsedCells = 6;

/// Formats busy-row elapsed seconds as a fixed-cell field: the value
/// never exceeds [_busyElapsedCells] cells (the caller right-aligns it).
String _formatBusyElapsed(int seconds) {
  if (seconds < 1) return '0s';
  if (seconds < 3600) return '${seconds}s';
  final hours = seconds ~/ 3600;
  // ponytail: stable cells beat honest digits past 99 h — a four-day
  // watch freezes the field instead of reflowing it once more.
  if (hours > 99) return '99h+';
  final minutes = (seconds % 3600) ~/ 60;
  return '${hours}h${minutes.toString().padLeft(2, '0')}m';
}

extension _TuiRowRenderers on FaTuiModel {
  /// The visible window of menu items, with the scroll-more hint rows when
  /// the list overflows above or below. Every item row registers a
  /// [TuiRegionKind.menuRow] hit-region carrying the item's ORIGINAL
  /// index ([menuSelected] addresses the unwindowed list); a models-family
  /// picker adds the one-line footer hint under the table.
  int _writeMenuItems(StringBuffer b, int baseRow) {
    final (start, end) = _menuWindow();
    var row = baseRow;
    var lastGroup = '';
    if (start > 0) {
      b.writeln(_dim('  ↑ more'));
      row++;
    }
    for (var i = start; i < end; i++) {
      final group = menuItems[i].group;
      if (group.isNotEmpty && group != lastGroup) {
        b.writeln(_dim('  ── $group ──'));
        lastGroup = group;
      }
      b.writeln(_menuItemRow(menuItems[i], i == menuSelected));
      _hitRegions.add(
        TuiHitRegion(
          x: 0,
          y: row,
          w: termWidth,
          h: 1,
          kind: TuiRegionKind.menuRow,
          index: i,
        ),
      );
      row++;
    }
    if (end < menuItems.length) {
      b.writeln(_dim('  ↓ more'));
      row++;
    }
    if (_modelPickerFamilyOpen) {
      b.writeln(_dim(' $modelPickerFooterHint'));
      row++;
    }
    return row - baseRow;
  }

  /// True while the models picker (or its two-step provider page) is open —
  /// the only pickers that carry the footer hint row.
  bool get _modelPickerFamilyOpen =>
      menuOpen &&
      menuModelMode &&
      (pickerId == 'models' || pickerId == 'modelProvider');

  /// One menu row (label + dim description, truncated to the width).
  String _menuItemRow(MenuItem item, bool selected) {
    final desc = item.description.isNotEmpty ? ' ${item.description}' : '';
    // Menu rows must never exceed the width: a soft-wrapped chrome line
    // desyncs the renderer's row math and smears frames on every key.
    final full = '${item.label}$desc';
    final prefix = selected ? '${_accent('▸')} ' : '  ';
    if (tuiTextWidth(full) <= termWidth - 2) {
      if (selected) {
        return '$prefix${_rearmSelection(item.label)}${_dim(desc)}';
      }
      return '$prefix${item.label}${_dim(desc)}';
    }
    final text = _fitWidth(full, termWidth - 2);
    return selected ? '$prefix${_rearmSelection(text)}' : '$prefix$text';
  }

  /// A fuzzy-highlighted label embeds per-match `accent2Soft …\x1b[0m`
  /// runs; the vendor's full reset strips the wrapping selection accent
  /// from every later cell — the "letters of different colors" overlay
  /// tear (issue #519, 97_fuzzy_overlay.png). Re-opens the selection
  /// accent after each embedded reset so the selected row keeps one base
  /// role: matched cells accent2Soft, everything else the selection
  /// accent.
  String _rearmSelection(String label) {
    final theme = FaThemeController.instance;
    final open = theme.sgrPrefix(theme.current.accent);
    if (open.isEmpty || !label.contains('\x1b[0m')) return label;
    return label.replaceAll('\x1b[0m', '\x1b[0m$open');
  }

  /// The [height]-row window of the wrapped output history at [offset].
  /// Always paints exactly [height] rows — [height] is the frame plan's
  /// [history] (issue #496: the sticky echo's rows left the budget, so
  /// window + echo + chrome sums to the physical height exactly).
  int _writeHistoryRows(
    StringBuffer b,
    int height,
    List<String> wrapped,
    int offset,
  ) {
    for (var i = 0; i < height; i++) {
      final row = offset + i;
      b.writeln(row < wrapped.length ? wrapped[row] : '');
    }
    return height;
  }

  /// Scroll progress indicator — only while the user scrolled away from
  /// the live edge (a "you are here" hint); while following, the row stays
  /// blank so the layout never shifts. (A transient viewport shrink, e.g.
  int _writeScrollIndicator(StringBuffer b, List<String> wrapped, int offset) {
    final bottom = _scrollBottom(wrapped);
    if (!followTail && offset < bottom) {
      final scrollPercent = bottom == 0
          ? 100
          : ((offset / bottom) * 100).round().clamp(0, 100);
      final progressText = ' $scrollPercent% ';
      final progressWidth = progressText.length;
      final leftWidth = (termWidth - progressWidth) ~/ 2;
      final rightWidth = termWidth - progressWidth - leftWidth;
      b.writeln(
        _dim('─' * (leftWidth < 0 ? 0 : leftWidth)) +
            _accent2Plain(progressText) +
            _dim('─' * (rightWidth < 0 ? 0 : rightWidth)),
      );
    } else {
      // The row is always reserved (progressH): skipping the blank row
      // while following shifted every later row on scroll.
      b.writeln();
    }
    return 1;
  }

  /// The busy indicator line (one row): spinner + label + honesty
  /// suffixes in FIXED cells (issue #365). The label zone and the elapsed
  /// field hold a constant cell count, so digit growth at a power-of-ten
  /// second, the 180 s quiet-threshold crossing and a mid-run phase swap
  /// never reflow the row — nothing right of a changing cell moves. The
  /// suffixes render provenance-first (a zone that appears or grows must
  /// never sit left of a stable one), and the row is fitted AND padded to
  /// the terminal width like the status row: stale tails are overwritten
  /// and the cursor parks at a stable column.
  String _busyRowLine() {
    if (menuOpen && menuModelMode) {
      // An interactive host picker is open: the run is blocked on the
      // user's choice, not working.
      return _dim(tuiPadRight('waiting for your selection…', termWidth));
    }
    final frame = _spinnerFrames[spinnerFrame % _spinnerFrames.length];
    final elapsedSeconds = busyStartedAtMs < 0
        ? 0
        : ((DateTime.now().millisecondsSinceEpoch - busyStartedAtMs) / 1000)
              .floor();
    final label = runStalled
        ? 'Stalled…'
        : (busyPhase.isEmpty ? 'Working…' : busyPhase);
    final quietSeconds = busyLastEventMs < 0
        ? 0
        : ((DateTime.now().millisecondsSinceEpoch - busyLastEventMs) / 1000)
              .floor();
    final suffix = [
      if (busySource.isNotEmpty) '· $busySource',
      if (quietSeconds >= 180) '· quiet ${quietSeconds ~/ 60}m',
    ].join(' ');
    final labelCell = tuiPadRight(
      tuiFitWidth(label, _busyLabelCells),
      _busyLabelCells,
    );
    final elapsedCell = _formatBusyElapsed(
      elapsedSeconds,
    ).padLeft(_busyElapsedCells);
    final plain =
        '$frame $labelCell $elapsedCell${suffix.isEmpty ? '' : ' $suffix'}';
    final padded = tuiPadRight(tuiFitWidth(plain, termWidth), termWidth);
    if (padded.length <= frame.length + 1) return _dim(padded);
    return '${_accent2Plain(frame)} '
        '${_dim(padded.substring(frame.length + 1))}';
  }

  int _writeBusyAndQueue(StringBuffer b, int baseRow, _FramePlan plan) {
    var row = baseRow;
    // Scheduled follow-ups sit ON TOP of the working row (issue #115) and
    // stay visible while idle — a pending reminder is exactly what the user
    // needs to see when nothing else is happening.
    if (plan.scheduled > 0) {
      b.writeln(_scheduledRowLine());
      row++;
    }
    row = _writeJobBoard(b, row, plan);
    row = _writeWaitingRows(b, row, plan);
    row = _writeBusyRow(b, row);
    row = _writeQueueRows(b, row, plan);
    row = _writeAttachmentChips(b, row, plan);
    b.writeln(_dim('─' * termWidth));
    return row + 1 - baseRow;
  }

  /// The background-job board's live region (issue #429): dim summary +
  /// live rows, clipped per frame at the live width (resize-safe). Paints
  /// only the plan's visible rows (issue #496 yield order: the board is
  /// the most dispensable section).
  int _writeJobBoard(StringBuffer b, int row, _FramePlan plan) {
    for (final line in jobBoardLines.take(plan.board)) {
      b.writeln(_dim(_clipToWidth(line)));
      row++;
    }
    return row;
  }

  /// The visible-waiting row (issue #450): WHAT the agent waits for,
  /// while idle. The busy row owns the screen while working — the waiting
  /// row yields to it (E3) and re-renders on the next waiter change.
  int _writeWaitingRows(StringBuffer b, int row, _FramePlan plan) {
    for (final line in _waitingRowLines().take(plan.waiting)) {
      b.writeln(line);
      row++;
    }
    return row;
  }

  /// The working indicator: the busy row owns the screen while a turn runs.
  int _writeBusyRow(StringBuffer b, int row) {
    if (busy) {
      b.writeln(_busyRowLine());
      row++;
    }
    return row;
  }

  /// Queued submissions with their per-row hit regions: the count badge is
  /// the "your typing is not lost" contract (AC2). Under a squeezed frame
  /// (issue #496) the block yields progressively — the hint row first,
  /// then the OLDEST queued rows; the header + newest rows stay.
  int _writeQueueRows(StringBuffer b, int row, _FramePlan plan) {
    if (!plan.queueHeader) return row;
    b.writeln(_dim('⏵ queued (${queue.length})'));
    row++;
    final first = queue.length - plan.queue;
    for (var q = first < 0 ? 0 : first; q < queue.length; q++) {
      final flat = queue[q].text.replaceAll('\n', ' ');
      b.writeln(_dim(_clipToWidth('${_queueBadge(queue[q].steer)}$flat')));
      _hitRegions.add(
        TuiHitRegion(
          x: 0,
          y: row,
          w: termWidth,
          h: 1,
          kind: TuiRegionKind.queueRow,
          index: q,
        ),
      );
      row++;
    }
    if (plan.queueHint) {
      b.writeln(_dim('↑ edit · ctrl+x delete · ctrl-s send immediately'));
    }
    return row;
  }

  /// Attachment chips send with the user's next message.
  int _writeAttachmentChips(StringBuffer b, int row, _FramePlan plan) {
    if (plan.chips <= 0) return row;
    for (final attachment in attachments.take(plan.chips)) {
      b.writeln(_accent2Plain(attachment.chip));
      row++;
    }
    if (plan.chips > attachments.length) {
      b.writeln(_dim('chips send with your next message'));
    }
    return row;
  }

  /// The `steer` badge on a queued submission: steering entries read
  /// differently from plain queued sends.
  static String _queueBadge(bool steer) => steer ? '⤳ [steer] ' : '❯ ';

  /// Clips a live row to the frame width, ellipsising the tail (resize-safe).
  String _clipToWidth(String line) => line.length > termWidth - 2
      ? '${line.substring(0, termWidth - 3)}…'
      : line;

  /// The scheduled follow-ups indicator line (one dim row): count + the
  /// nearest ETA, styled after the busy row so it reads as one family.
  String _scheduledRowLine() {
    final now = nowFn().millisecondsSinceEpoch;
    final eta = scheduledNextDueMs < 0
        ? ''
        : scheduledNextDueMs <= now
        ? ' · due now'
        : ' · next in '
              '${ScheduledMessageQueue.formatDelay(Duration(milliseconds: scheduledNextDueMs - now))}';
    return _dim('⏰ $scheduledCount scheduled$eta');
  }

  /// The visible-waiting rows (issue #450): headline row (`⏳ waiting ·
  /// purpose · next wake in 4m (timer)`) plus capped detail rows and the
  /// restart-honesty note; empty while busy or with no waiters. The pure
  /// builder `waitingRowLines` holds the logic.
  List<String> _waitingRowLines() => waitingRowLines(
    busy: busy,
    waitingJobs: waitingJobs,
    waitingTimers: waitingTimers,
    waitingLostJobs: waitingLostJobs,
    nowMs: nowFn().millisecondsSinceEpoch,
  );

  /// The visible-waiting push (issue #450): replaces the waiter aggregate;
  /// while a timer countdown is on screen, arms the shared minute-boundary
  /// tick (one chain — [scheduledTickPending] guards it).
  (Model, Cmd?) _handleWaitingStatus(WaitingStatusMsg msg) {
    final next = copyWith(
      waitingJobs: msg.jobs,
      waitingTimers: msg.timers,
      waitingLostJobs: msg.lostJobs,
    );
    if (next.waitingTimers.isNotEmpty && !scheduledTickPending) {
      return (
        next.copyWith(scheduledTickPending: true),
        _scheduleScheduledTick(),
      );
    }
    return (next, null);
  }
}

/// Pure row builder for the visible-waiting block (issue #450) — top-level
/// so tests hit it directly and sibling lanes (#446 row builders) can share
/// the one implementation. Split into per-piece helpers to keep each CRAP
/// score under the repo's ≤12 gate.
List<String> waitingRowLines({
  required bool busy,
  required List<String> waitingJobs,
  required List<({int dueMs, String preview})> waitingTimers,
  required int waitingLostJobs,
  required int nowMs,
}) {
  if (busy) return const [];
  if (waitingJobs.isEmpty && waitingTimers.isEmpty) return const [];
  String etaOf(int dueMs) => dueMs <= nowMs
      ? 'due now'
      : ScheduledMessageQueue.formatDelay(
          Duration(milliseconds: dueMs - nowMs),
        );
  final lines = <String>[
    _waitingHeadLine(waitingJobs, waitingTimers, etaOf),
    ..._waitingDetailLines(waitingJobs, waitingTimers, etaOf),
    if (waitingLostJobs > 0) _waitingLostLine(waitingLostJobs),
  ];
  return lines;
}

/// The `⏳ waiting` headline: job purpose and/or the nearest timer wake.
String _waitingHeadLine(
  List<String> jobs,
  List<({int dueMs, String preview})> timers,
  String Function(int) etaOf,
) {
  final head = StringBuffer('⏳ waiting');
  if (jobs.length == 1) {
    head.write(' · ${jobs.single}');
  } else if (jobs.length > 1) {
    head.write(' · ${jobs.length} jobs');
  }
  if (timers.isNotEmpty) {
    final nearest = timers.map((t) => t.dueMs).reduce((a, b) => a < b ? a : b);
    final eta = etaOf(nearest);
    head.write(
      timers.length == 1
          ? ' · next wake in $eta (timer)'
          : ' · ${timers.length} timers · next wake in $eta',
    );
  }
  return _dim(head.toString());
}

/// Detail rows exist only when a count hides something (>1 of a kind);
/// the job board above already lists every job live. Capped at two rows.
List<String> _waitingDetailLines(
  List<String> jobs,
  List<({int dueMs, String preview})> timers,
  String Function(int) etaOf,
) {
  final details = <String>[
    if (jobs.length > 1) ...jobs,
    if (timers.length > 1)
      ...timers.map((t) => '${t.preview} · due in ${etaOf(t.dueMs)}'),
  ];
  return [for (final detail in details.take(2)) _dim('  $detail')];
}

/// The restart-honesty note: waiters lost to the previous run's exit.
String _waitingLostLine(int lost) {
  final noun = 'background job${lost == 1 ? '' : 's'}';
  final verb = lost == 1 ? 'was' : 'were';
  return _dim('$lost $noun from the previous run $verb lost');
}
