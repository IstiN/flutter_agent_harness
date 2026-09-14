// Frame row renderers for the FA TUI: the inline menu (item window with
// scroll hints + footer hint), the busy/queue block, and the scheduled
// follow-ups indicator.
//
// Lives in a part file to keep fa_tui.dart under the line gate (same
// pattern as composer_overlay.dart / fa_tui_mouse.dart); the render state
// (`_hitRegions`, model fields) is declared on [FaTuiModel] itself —
// extensions cannot add fields.
part of 'fa_tui.dart';

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
      menuOpen && menuModelMode &&
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
