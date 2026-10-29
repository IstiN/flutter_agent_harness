import 'dart:convert';
import 'msg.dart';

/// Parses [TeaKey]s from a byte buffer, covering the control-character and
/// simple-escape-sequence subset of terminal input that isn't claimed by the
/// CSI/OSC/DCS decoder in [TerminalInputDecoder].
///
/// Mutates [buffer] only when a full key sequence is recognised.
/// Returns `null` if more bytes are needed (incomplete escape sequence).
TeaKey? parseKeyFromBuffer(List<int> buffer) {
  if (buffer.isEmpty) return null;

  final b0 = buffer[0];

  // Control characters 0x01–0x1a (Ctrl+A … Ctrl+Z)
  if (b0 >= 0x01 && b0 <= 0x1a) {
    buffer.removeAt(0);
    return switch (b0) {
      0x09 => const TeaKey(code: KeyCode.tab), // HT / Tab
      0x0a => const TeaKey(code: KeyCode.enter), // LF / Enter (Linux/WSL)
      0x0d => const TeaKey(code: KeyCode.enter), // CR / Enter
      _ => TeaKey(
          code: KeyCode.rune,
          // 0x01→'a', 0x02→'b', … 0x1a→'z'
          text: String.fromCharCode(b0 + 0x60),
          modifiers: const {KeyMod.ctrl},
        ),
    };
  }

  // Escape sequences
  if (b0 == 0x1b) {
    if (buffer.length < 2) return null;
    final b1 = buffer[1];

    // CSI: ESC [
    if (b1 == 0x5b) {
      if (buffer.length < 3) return null;
      final b2 = buffer[2];
      final arrowOrNav = switch (b2) {
        0x41 => const TeaKey(code: KeyCode.up),
        0x42 => const TeaKey(code: KeyCode.down),
        0x43 => const TeaKey(code: KeyCode.right),
        0x44 => const TeaKey(code: KeyCode.left),
        0x48 => const TeaKey(code: KeyCode.home),
        0x46 => const TeaKey(code: KeyCode.end),
        // CSI Z is backtab (Shift+Tab); surface it as Tab + Shift so consumers
        // (e.g. TabsModel's `case 'shift+tab'`) receive `key == 'shift+tab'`.
        0x5a => const TeaKey(code: KeyCode.tab, modifiers: {KeyMod.shift}),
        _ => null,
      };
      if (arrowOrNav != null) {
        buffer.removeRange(0, 3);
        return arrowOrNav;
      }
      // ESC [ n ~  (delete, pgup, pgdn, home, end)
      if (b2 >= 0x31 && b2 <= 0x39) {
        if (buffer.length < 4) return null;
        final b3 = buffer[3];
        if (b3 == 0x7e) {
          final key = switch (b2) {
            0x31 => const TeaKey(code: KeyCode.home),
            0x33 => const TeaKey(code: KeyCode.delete),
            0x34 => const TeaKey(code: KeyCode.end),
            0x35 => const TeaKey(code: KeyCode.pageUp),
            0x36 => const TeaKey(code: KeyCode.pageDown),
            0x37 => const TeaKey(code: KeyCode.home),
            0x38 => const TeaKey(code: KeyCode.end),
            _ => const TeaKey(code: KeyCode.unknown),
          };
          buffer.removeRange(0, 4);
          return key;
        }
      }
      buffer.removeRange(0, 3);
      return const TeaKey(code: KeyCode.unknown);
    }

    // SS3: ESC O  (home, end, F1–F4)
    if (b1 == 0x4f) {
      if (buffer.length < 3) return null;
      final b2 = buffer[2];
      final key = switch (b2) {
        0x48 => const TeaKey(code: KeyCode.home),
        0x46 => const TeaKey(code: KeyCode.end),
        0x50 => const TeaKey(code: KeyCode.f1),
        0x51 => const TeaKey(code: KeyCode.f2),
        0x52 => const TeaKey(code: KeyCode.f3),
        0x53 => const TeaKey(code: KeyCode.f4),
        _ => null,
      };
      buffer.removeRange(0, 3);
      return key ?? const TeaKey(code: KeyCode.unknown);
    }

    // Alt+Left: ESC b
    if (b1 == 0x62) {
      buffer.removeRange(0, 2);
      return const TeaKey(code: KeyCode.left, modifiers: {KeyMod.alt});
    }
    // Alt+Right: ESC f
    if (b1 == 0x66) {
      buffer.removeRange(0, 2);
      return const TeaKey(code: KeyCode.right, modifiers: {KeyMod.alt});
    }
    // Alt+Backspace: ESC DEL
    if (b1 == 0x7f) {
      buffer.removeRange(0, 2);
      return const TeaKey(code: KeyCode.backspace, modifiers: {KeyMod.alt});
    }
    // Alt+Enter: ESC CR (terminals without kitty/modifyOtherKeys support,
    // e.g. Warp's legacy TUI passthrough) and ESC LF — the same wire after
    // a kernel line discipline with ICRNL still on translated the CR before
    // the app read it (fa issue #77; the fallback for hosts that reset
    // termios under us or where stty is unavailable). Neither byte pair has
    // any other standard meaning.
    if (b1 == 0x0d || b1 == 0x0a) {
      buffer.removeRange(0, 2);
      return const TeaKey(code: KeyCode.enter, modifiers: {KeyMod.alt});
    }
    // Double Escape: two presses landing in one read chunk used to fall
    // into the `unknown` fallthrough below and BOTH presses were swallowed
    // — during a streaming run the abort Esc never fired and the TUI looked
    // frozen (fa issue #46). ESC ESC is not any terminal's sequence for
    // anything else: consume only the FIRST byte and emit the Escape key;
    // the remaining byte parses as a lone ESC on the next pass, delivered
    // by the Program's lone-escape timer.
    if (b1 == 0x1b) {
      buffer.removeAt(0);
      return const TeaKey(code: KeyCode.escape);
    }

    buffer.removeRange(0, 2);
    return const TeaKey(code: KeyCode.unknown);
  }

  // DEL / Backspace
  if (b0 == 0x7f) {
    buffer.removeAt(0);
    return const TeaKey(code: KeyCode.backspace);
  }

  // Other non-printable controls
  if (b0 == 0x00 || (b0 >= 0x1c && b0 <= 0x1f)) {
    buffer.removeAt(0);
    return const TeaKey(code: KeyCode.unknown);
  }

  // Multi-byte UTF-8 or Printable ASCII
  // Try to decode as much as possible from the start of the buffer.
  // Cap the run at the first CONTROL byte: a burst read delivering
  // "text\r" (or "text\n") in one chunk must not swallow the Enter into
  // the text run — the control byte belongs to the next key.
  var maxRun = 0;
  while (maxRun < buffer.length && maxRun < 4) {
    final b = buffer[maxRun];
    if (b < 0x20 || b == 0x7f) break;
    maxRun++;
  }
  for (var len = maxRun; len >= 1; len--) {
    try {
      final decoded = utf8.decode(buffer.sublist(0, len));
      buffer.removeRange(0, len);
      return TeaKey(code: KeyCode.rune, text: decoded);
    } catch (_) {
      // Continue trying shorter lengths or wait for more bytes
    }
  }

  // If we're here, it could be a PARTIAL UTF-8 sequence or something that can
  // never decode. The second case is not hypothetical: a Windows console in a
  // legacy OEM code page delivers a Cyrillic keystroke as ONE byte (0xEF for
  // 'п'), which looks like a 3-byte UTF-8 lead but is never followed by
  // continuations. Waiting for them wedged the WHOLE input stream — the buffer
  // only grew and no key was ever emitted again, so the user could not type
  // Russian at all (fa issue #1973 follow-up). Wait only while the head can
  // still complete.
  final expected = _utf8SequenceLength(b0);
  if (expected == 0) {
    // Not a UTF-8 lead byte: a bare continuation byte or 0xF8+. Junk — drop it.
    buffer.removeAt(0);
    return const TeaKey(code: KeyCode.unknown);
  }
  final lookahead = expected < buffer.length ? expected : buffer.length;
  var malformed = false;
  for (var i = 1; i < lookahead; i++) {
    if ((buffer[i] & 0xC0) != 0x80) {
      malformed = true; // a non-continuation inside the promised window
      break;
    }
  }
  if (!malformed && buffer.length < expected) {
    return null; // genuinely partial: the rest of the character is in flight
  }
  // The head can never complete here: consume ONE byte so typing recovers
  // instead of stalling. The byte surfaces as a Latin-1 rune rather than
  // vanishing silently.
  buffer.removeAt(0);
  return TeaKey(code: KeyCode.rune, text: String.fromCharCode(b0));
}

/// How many bytes a UTF-8 sequence starting with [b] occupies (1 for ASCII),
/// or 0 when [b] cannot start one. The parser uses it to tell a genuinely
/// partial character (wait for more bytes) from a head that can never decode
/// (consume it, or the stream stalls — see [parseKeyFromBuffer]).
int _utf8SequenceLength(int b) {
  if (b < 0x80) return 1;
  if ((b & 0xE0) == 0xC0) return 2;
  if ((b & 0xF0) == 0xE0) return 3;
  if ((b & 0xF8) == 0xF0) return 4;
  return 0;
}
