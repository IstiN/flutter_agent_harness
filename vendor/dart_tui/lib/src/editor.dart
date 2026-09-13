// LineEditor: readline-grade immutable line editing for the TUI composer
// (issue #275 scope 3). Value semantics — every mutation returns a new
// LineEditor, so FaTuiModel.copyWith can carry it like any other field.
//
// Features: kill-ring (ctrl-w/u/k cut, ctrl-y yank, ring of 8, per-session
// by construction), grouped undo (word-wise coalescing, cap 100 steps),
// ctrl-t transpose. Paste inserts verbatim like any other text.
library;

/// One immutable line-buffer snapshot: [text] with the caret at [cursor].
class LineBuffer {
  final String text;
  final int cursor;

  const LineBuffer(this.text, [this.cursor = 0]);

  String get before => text.substring(0, cursor.clamp(0, text.length));
  String get after => text.substring(cursor.clamp(0, text.length));
}

/// A single undo step: the buffer BEFORE the change plus a grouping tag.
/// Consecutive steps with the same tag coalesce into one undo (word
/// grouping: typing "hello world" undoes one word at a time, not per key).
class _UndoStep {
  final LineBuffer buffer;
  final Object group;

  const _UndoStep(this.buffer, this.group);
}

/// Word boundaries for kill/undo grouping: whitespace runs (default) or
/// non-word characters. Whitespace immediately left of the caret is skipped
/// first (readline kills "foo " not "foo" then " ").
bool _atWordStart(String text, int index) {
  if (index <= 0) return true;
  final prev = text[index - 1];
  if (prev != ' ' && prev != '\t') return false;
  return index >= text.length || text[index] != prev;
}

int _previousWordStart(String text, int index) {
  var i = index;
  while (i > 0 && (text[i - 1] == ' ' || text[i - 1] == '\t')) {
    i--;
  }
  while (i > 0 && text[i - 1] != ' ' && text[i - 1] != '\t') {
    i--;
  }
  return i;
}

/// Immutable readline-style editor with kill-ring and grouped undo.
class LineEditor {
  /// Kill ring capacity (readline default is 10; 8 keeps memory trivial).
  static const int killRingSize = 8;

  /// Undo stack cap: 100 grouped steps per session.
  static const int undoLimit = 100;

  final LineBuffer buffer;
  final List<String> killRing;
  final int killIndex;
  final List<_UndoStep> undoStack;
  final bool lastActionWasYank;

  const LineEditor._(
    this.buffer, {
    this.killRing = const [],
    this.killIndex = -1,
    this.undoStack = const [],
    this.lastActionWasYank = false,
  });

  LineEditor([String text = '', int cursor = 0])
      : this._(LineBuffer(text, cursor));

  /// An empty editor — const, usable as a default parameter value.
  const LineEditor.empty() : this._(const LineBuffer('', 0));

  /// Replaces the buffer while preserving the kill-ring and undo history.
  /// Programmatic whole-line sets (history recall, menu-accept prefills)
  /// and cursor-only motion ride this; neither is an undoable edit.
  LineEditor withBuffer(LineBuffer next) => LineEditor._(
        next,
        killRing: killRing,
        killIndex: killIndex,
        undoStack: undoStack,
        lastActionWasYank: lastActionWasYank,
      );

  String get text => buffer.text;
  int get cursor => buffer.cursor;
  bool get canUndo => undoStack.isNotEmpty;
  bool get canYank => killRing.isNotEmpty;

  LineEditor _push(LineBuffer next, Object group) {
    final steps = [...undoStack, _UndoStep(buffer, group)];
    return LineEditor._(
      next,
      killRing: killRing,
      killIndex: killIndex,
      undoStack: steps.length > undoLimit
          ? steps.sublist(steps.length - undoLimit)
          : steps,
    );
  }

  /// Inserts [insert] at the caret. Typing groups by word: a run of
  /// non-separator chars starting at a word start coalesces into one undo.
  LineEditor insert(String insert) {
    if (insert.isEmpty) return this;
    final b = buffer;
    final next = LineBuffer(
      b.before + insert + b.after,
      b.cursor + insert.length,
    );
    final atWordStart = _atWordStart(b.text, b.cursor);
    final group = _WordGroup(atWordStart);
    return _push(next, group);
  }

  /// Deletes [count] chars back from the caret, pushing the killed text on
  /// the ring. ctrl-u alias with count = cursor.
  LineEditor backspace() {
    final b = buffer;
    if (b.cursor == 0) return this;
    final killed = b.text.substring(b.cursor - 1, b.cursor);
    final next = LineBuffer(
      b.text.substring(0, b.cursor - 1) + b.after,
      b.cursor - 1,
    );
    return _push(next, const _KillGroup())._ringPush(killed);
  }

  /// Deletes the char under the caret (forward delete), no ring entry
  /// (readline puts only ctrl-d-region kills on the ring; plain forward
  /// delete keeps undo though).
  LineEditor deleteForward() {
    final b = buffer;
    if (b.cursor >= b.text.length) return this;
    final next = LineBuffer(
      b.before + b.text.substring(b.cursor + 1),
      b.cursor,
    );
    return _push(next, const _KillGroup());
  }

  /// ctrl-w: kill the word left of the caret onto the ring.
  LineEditor killWordBefore() {
    final b = buffer;
    if (b.cursor == 0) return this;
    final start = _previousWordStart(b.text, b.cursor);
    if (start == b.cursor) return this;
    final killed = b.text.substring(start, b.cursor);
    final next = LineBuffer(b.text.substring(0, start) + b.after, start);
    return _push(next, const _KillGroup())._ringPush(killed);
  }

  /// ctrl-u: kill from line start to the caret onto the ring.
  LineEditor killToLineStart() {
    final b = buffer;
    if (b.cursor == 0) return this;
    final killed = b.before;
    final next = LineBuffer(b.after, 0);
    return _push(next, const _KillGroup())._ringPush(killed);
  }

  /// ctrl-k: kill from the caret to line end onto the ring.
  LineEditor killToLineEnd() {
    final b = buffer;
    if (b.cursor >= b.text.length) return this;
    final killed = b.after;
    final next = LineBuffer(b.before, b.cursor);
    return _push(next, const _KillGroup())._ringPush(killed);
  }

  /// ctrl-y: yank the most recent kill at the caret. Consecutive ctrl-y
  /// calls walk OLDER ring entries (readline meta-y without the meta key).
  LineEditor yank() {
    if (killRing.isEmpty) return this;
    final index = killIndex < 0 ? killRing.length - 1 : killIndex;
    final killed = killRing[index];
    final b = buffer;
    final next =
        LineBuffer(b.before + killed + b.after, b.cursor + killed.length);
    return LineEditor._(
      _push(next, _YankGroup).buffer,
      killRing: killRing,
      killIndex: index,
      undoStack: undoStack,
      lastActionWasYank: true,
    );
  }

  /// ctrl-y followed by more yanks pop older ring entries; the previously
  /// yanked span is replaced, not appended (readline yank-pop semantics).
  LineEditor yankOlder() {
    if (killRing.isEmpty) return this;
    final current = killIndex < 0 ? killRing.length - 1 : killIndex;
    final next = current <= 0 ? killRing.length - 1 : current - 1;
    final killed = killRing[next];
    final b = buffer;
    // Replace the previously yanked span, not append.
    final prev = killRing[current];
    final start = b.cursor - prev.length;
    final replaced = start >= 0 && b.text.substring(start, b.cursor) == prev;
    final nextText = replaced
        ? b.text.substring(0, start) + killed + b.after
        : b.before + killed + b.after;
    final nextCursor =
        replaced ? start + killed.length : b.cursor + killed.length;
    return LineEditor._(
      _push(LineBuffer(nextText, nextCursor), _YankGroup).buffer,
      killRing: killRing,
      killIndex: next,
      undoStack: undoStack,
      lastActionWasYank: true,
    );
  }

  LineEditor _ringPush(String killed) {
    final ring = [...killRing, killed];
    final over = ring.length - killRingSize;
    final kept = over > 0 ? ring.sublist(over) : ring;
    return LineEditor._(
      buffer,
      killRing: kept,
      // A fresh kill becomes the yank head.
      killIndex: kept.length - 1,
      undoStack: undoStack,
    );
  }

  /// ctrl-t: swap the char before the caret with the one under it.
  LineEditor transpose() {
    final b = buffer;
    if (b.cursor < 2 && !(b.cursor == b.text.length && b.text.length >= 2)) {
      if (b.text.length < 2) return this;
    }
    var c = b.cursor;
    if (c == 0) return this;
    if (c == b.text.length) c -= 1; // caret at EOL transposes last two chars
    if (c < 1) return this;
    final t = b.text.substring(0, c - 1) +
        b.text[c] +
        b.text[c - 1] +
        b.text.substring(c + 1);
    return _push(LineBuffer(t, c + 1), const _TransposeGroup());
  }

  /// Undo one grouped step, returning the previous buffer.
  LineEditor undo() {
    if (undoStack.isEmpty) return this;
    final last = undoStack.last;
    var steps = undoStack.sublist(0, undoStack.length - 1);
    // Coalesce: pop all steps sharing the last step's group so one undo
    // walks back to before the whole word/run. A singleton tail (a kill
    // after typing, say) pops nothing more.
    final group = last.group;
    var popped = 0;
    while (steps.isNotEmpty && steps.last.group == group) {
      steps = steps.sublist(0, steps.length - 1);
      popped++;
    }
    // The restored buffer is the state recorded just before the whole
    // coalesced run (the anchor step below the popped tail). A singleton
    // NON-word tail (kill/yank/transpose after typing) pops nothing and
    // is its own run: undoing it restores that step's own buffer - the
    // pre-change line. A lone word-start anchor still restores the step
    // below it (the run it anchors was already undone).
    final restored = steps.isEmpty || (popped == 0 && last.group is! _WordGroup)
        ? last.buffer
        : steps.last.buffer;
    return LineEditor._(
      restored,
      killRing: killRing,
      killIndex: killIndex,
      undoStack: steps,
    );
  }

  /// Exposes the raw current buffer (for rendering the highlight window).
  LineBuffer get lineBuffer => buffer;

  @override
  bool operator ==(Object other) =>
      other is LineEditor &&
      other.buffer.text == buffer.text &&
      other.buffer.cursor == buffer.cursor;

  @override
  int get hashCode => Object.hash(buffer.text, buffer.cursor);

  @override
  String toString() => 'LineEditor(${buffer.text}@${buffer.cursor})';
}

class _WordGroup {
  final bool atWordStart;
  const _WordGroup(this.atWordStart);
  @override
  bool operator ==(Object other) =>
      other is _WordGroup && other.atWordStart == atWordStart;
  @override
  int get hashCode => atWordStart.hashCode;
}

class _KillGroup {
  const _KillGroup();
}

class _YankGroup {
  const _YankGroup();
}

class _TransposeGroup {
  const _TransposeGroup();
}
