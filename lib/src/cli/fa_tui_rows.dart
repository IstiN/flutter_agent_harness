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
        return '$prefix${_accent(item.label)}${_dim(desc)}';
      }
      return '$prefix${item.label}${_dim(desc)}';
    }
    final text = _fitWidth(full, termWidth - 2);
    return selected ? '$prefix${_accent(text)}' : '$prefix$text';
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
    final label = busyPhase.isEmpty ? 'Working…' : busyPhase;
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

  int _writeBusyAndQueue(StringBuffer b, int baseRow) {
    // Scheduled follow-ups sit ON TOP of the working row (issue #115) and
    // stay visible while idle — a pending reminder is exactly what the user
    // needs to see when nothing else is happening.
    var row = baseRow;
    if (scheduledCount > 0) {
      b.writeln(_scheduledRowLine());
      row++;
    }
    if (busy) {
      b.writeln(_busyRowLine());
      row++;
    }
    if (queue.isNotEmpty) {
      // The count badge is the "your typing is not lost" contract (AC2).
      b.writeln(_dim('⏵ queued (${queue.length})'));
      row++;
      for (var q = 0; q < queue.length; q++) {
        final flat = queue[q].text.replaceAll('\n', ' ');
        final badge = queue[q].steer ? '⤳ [steer] ' : '❯ ';
        final line = '$badge$flat';
        final clipped = line.length > termWidth - 2
            ? '${line.substring(0, termWidth - 3)}…'
            : line;
        b.writeln(_dim(clipped));
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
      b.writeln(_dim('↑ edit · ctrl+x delete · ctrl-s send immediately'));
      row++;
    }
    if (attachments.isNotEmpty) {
      for (final attachment in attachments) {
        b.writeln(_accent2Plain(attachment.chip));
        row++;
      }
      b.writeln(_dim('chips send with your next message'));
      row++;
    }
    b.writeln(_dim('─' * termWidth));
    row++;
    return row - baseRow;
  }

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
}
