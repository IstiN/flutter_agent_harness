// Mouse hit-region plumbing for the FA TUI (issue #278): click/drag/
// release routing over the per-frame [TuiHitRegionRegistry], the composer
// click→caret mapping, and the `/mouse` slash command.
//
// Lives in a part file to keep fa_tui.dart under the line gate; the state
// it drives (`_hitRegions`, `_mouseRouter`, `_mouseHintShown`) is declared
// on [FaTuiModel] itself — extensions cannot add fields.
part of 'fa_tui.dart';

extension _TuiMouseRegions on FaTuiModel {
  /// Click: remember the press point — activation happens on RELEASE
  /// (press-to-release model, standard SGR 1002 button semantics). The
  /// composer caret is the exception: X10 (modes 9/1000) reports presses
  /// only, so mousedown already homes the caret; the SGR release then
  /// re-activates idempotently.
  (Model, Cmd?) _handleMouseClick(MouseClickMsg msg) {
    if (!mouseCapture) return (this, null);
    _mouseRouter.pressAt(msg.mouse.x, msg.mouse.y);
    final region = _hitRegions.hitTest(msg.mouse.x, msg.mouse.y);
    if (region != null && region.kind == TuiRegionKind.composer) {
      return _activateRegion(region, msg.mouse.x, msg.mouse.y);
    }
    return (this, null);
  }

  /// Motion while pressed: past the drag threshold the gesture becomes a
  /// drag and its release activates nothing (E1 — a drag with capture on
  /// is the user attempting a selection).
  (Model, Cmd?) _handleMouseMotion(MouseMotionMsg msg) {
    if (!mouseCapture) return (this, null);
    _mouseRouter.motionTo(msg.mouse.x, msg.mouse.y);
    return (this, null);
  }

  /// Release: [TuiMouseRouter.releaseAt] classifies the gesture and
  /// hit-tests the release point (topmost region wins); a click on a
  /// region routes to [_activateRegion].
  (Model, Cmd?) _handleMouseRelease(MouseReleaseMsg msg) {
    if (!mouseCapture) return (this, null);
    final gesture = _mouseRouter.releaseAt(msg.mouse.x, msg.mouse.y, _hitRegions);
    if (gesture is! MouseClickGesture) return (this, null);
    return _activateRegion(gesture.region, msg.mouse.x, msg.mouse.y);
  }

  /// Per-region-type routing (AC1): composer → caret move, menu row →
  /// accept, queue row → drop, scrollback → consumed no-op (the click
  /// must not fall through to unclaimed-chrome behavior).
  (Model, Cmd?) _activateRegion(TuiHitRegion region, int x, int y) {
    switch (region.kind) {
      case TuiRegionKind.composer:
        final caret = _caretForComposerClick(y - region.y, x);
        return (
          copyWith(cursor: caret.clamp(0, inputText.length)),
          null,
        );
      case TuiRegionKind.menuRow:
        final index = region.index.clamp(0, menuItems.length - 1);
        // Picker rows go through the picker accept; slash/path menu rows
        // take the SAME handler keyboard-Enter uses (a plain slash menu
        // has no picker id, so the picker path would silently no-op).
        final selected = copyWith(menuSelected: index);
        if (!menuModelMode) return selected._acceptSlashMenuItem();
        return selected._acceptPickerAt(index);
      case TuiRegionKind.queueRow:
        final index = region.index;
        if (index < 0 || index >= queue.length) return (this, null);
        final next = [...queue]..removeAt(index);
        return (copyWith(queue: next), null);
      case TuiRegionKind.scrollback:
        return (this, null);
    }
  }

  /// Maps a composer click to a caret offset in [inputText]: [clickRow]
  /// is relative to the input zone top, [clickCol] the screen column.
  /// Walks the logical lines with the same wrap the view paints
  /// ([_wrapInputLine], one display row per [width]-cell chunk), so the
  /// caret lands exactly under the clicked cell; wide graphemes claim
  /// their full cell width, clicks past a line's end snap to its end.
  int _caretForComposerClick(int clickRow, int clickCol) {
    final width = termWidth < 1 ? 1 : termWidth;
    var offset = 0; // code units consumed, newlines included
    for (final line in inputText.split('\n')) {
      final chunkRows = line.isEmpty ? 0 : (line.length + width - 1) ~/ width;
      if (clickRow < chunkRows) {
        return offset + _caretInChunk(line, clickRow * width, clickCol, width);
      }
      if (clickRow == chunkRows) {
        // The phantom row the cursor rests on past the last chunk —
        // snap to the line end.
        return offset + line.length;
      }
      offset += line.length + 1; // +1 newline
    }
    return inputText.length;
  }

  /// Caret offset inside [line] for a click at [clickCol] within the
  /// display chunk starting at code-unit [start] (the same [width]-cell
  /// wrap the view paints): wide graphemes claim their full cell width,
  /// clicks past the chunk's end snap to its end.
  int _caretInChunk(String line, int start, int clickCol, int width) {
    final end = start + width > line.length ? line.length : start + width;
    var cells = 0;
    var takenUnits = 0;
    for (final grapheme in line.substring(start, end).characters) {
      if (cells >= clickCol) break;
      cells += tuiTextWidth(grapheme);
      takenUnits += grapheme.length;
    }
    return start + takenUnits;
  }

  /// `/mouse [on|off]` — the TUI-side mouse capture toggle (issue #278,
  /// AC4: the same switch governs wheel capture AND hit-regions). Bare
  /// `/mouse` flips; an explicit arg must parse. OFF prints the
  /// keyboard-degrade hint once per session (E4). Null when [text] is
  /// not the /mouse command.
  (FaTuiModel, Cmd?)? _handleMouseCommand(String text) {
    const cmd = '/mouse';
    if (text != cmd && !text.startsWith('$cmd ')) return null;
    final arg = text == cmd ? '' : text.substring(cmd.length + 1).trim();
    switch (arg) {
      case '':
      case 'on':
        return (
          copyWith(mouseCapture: true, inputText: '', cursor: 0),
          null,
        );
      case 'off':
        final hint = _mouseHintShown
            ? null
            : 'mouse capture off — wheel and clicks disabled; /mouse to '
                're-enable';
        _mouseHintShown = true;
        return (
          copyWith(
            mouseCapture: false,
            inputText: '',
            cursor: 0,
            outputLines: hint == null
                ? null
                : FaTuiModel._appendOutput(outputLines, _dim(hint), true),
          ),
          null,
        );
      default:
        return (
          copyWith(
            inputText: '',
            cursor: 0,
            outputLines: FaTuiModel._appendOutput(
              outputLines,
              _dim('usage: /mouse [on|off]'),
              true,
            ),
          ),
          null,
        );
    }
  }
}
