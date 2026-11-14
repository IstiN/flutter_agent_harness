import 'dart:convert';

/// Byte-to-string line decoder for Windows console input that repairs the
/// mojibake legacy code pages produce for non-ASCII keystrokes.
///
/// Wire shapes observed on a RU-locale Windows 11 machine (Russian typing
/// broken in the fa line REPL; the TUI already guards its own path —
/// `vendor/dart_tui` gh-1973 follow-up):
///
/// 1. **CP-6501 translation mojibake.** The console hands the ANSI code page
///    BYTE of the typed character over as if it were a Unicode code point,
///    then encodes that pseudo-code-point as UTF-8: 'п' (CP1251 byte 0xEF)
///    arrives as the two bytes `C3 AF` — the UTF-8 encoding of 'ï'. Strict
///    UTF-8 decoding happily yields mojibake text.
/// 2. **Legacy single-byte pages.** Nothing ever flipped the console out of
///    its OEM page (ConPTY pipes, older consoles): 'п' arrives as the single
///    byte `0xEF`. Strict `utf8.decoder` treats it as a 2-byte sequence head
///    that never completes — per-event decoding throws a `FormatException`
///    into the stream and the input line dies.
///
/// The host (`bin/`) builds the two repair tables from the real console with
/// `MultiByteToWideChar` (ANSI code page + console input code page) and
/// passes them in; every hook is optional, and with no hooks the decoder
/// behaves like `utf8.decoder` except that undecodable bytes surface as
/// U+FFFD instead of throwing (an input stream that errors is the "cannot
/// type Russian at all" symptom).
///
/// True UTF-8 text (code points above U+00FF — Cyrillic, emoji, CJK) passes
/// through untouched in every configuration; a real Latin-1 'ï' typed on a
/// repair-configured Russian console is indistinguishable on the wire from
/// shape 1 and is repaired too — a deliberate, documented trade-off (nobody
/// types Latin-1 supplement chars into a Russian-locale terminal composer).
final class ConsoleLineDecoder extends Converter<List<int>, String> {
  /// Repairs decoded Latin-1-range text (U+00A0–U+00FF) produced by shape 1.
  /// Maps each char through the console's ANSI code page; e.g. 'ï' → 'п'.
  final String Function(String run)? runRepair;

  /// Decodes a single byte no UTF-8 sequence could claim (shape 2, malformed
  /// heads, lone continuation bytes). Built from the console's input code
  /// page; e.g. 0xEF → 'п'. Null = surface U+FFFD.
  final String? Function(int byte)? singleByteDecode;

  /// Bytes of a partial multi-byte sequence carried between [convert] calls
  /// (a keystroke's UTF-8 bytes can straddle two stdin reads). One stream
  /// per instance: wire a fresh decoder into each `Stream.transform` chain
  /// (the CLI does — `_consoleLineDecoder()`).
  List<int>? _carry;

  ConsoleLineDecoder({this.runRepair, this.singleByteDecode});

  @override
  String convert(List<int> bytes) {
    final input = _carry == null ? bytes : [..._carry!, ...bytes];
    _carry = null;
    final out = StringBuffer();
    var i = 0;
    while (i < input.length) {
      final next = _decodeAt(input, i, out);
      if (next == null) {
        _carry = input.sublist(i);
        break;
      }
      i = next;
    }
    return out.toString();
  }

  @override
  ChunkedConversionSink<List<int>> startChunkedConversion(Sink<String> sink) =>
      _ConsoleLineChunkedSink(this, sink);

  /// Decodes the sequence starting at [i] into [out] and returns the next
  /// index — or null when the event ended mid-sequence and the tail must be
  /// carried for the next stdin read.
  int? _decodeAt(List<int> input, int i, StringBuffer out) {
    final b = input[i];
    if (b < 0x80) {
      out.writeCharCode(b);
      return i + 1;
    }
    final expected = _utf8SequenceLength(b);
    if (expected == 0) {
      // Not a lead byte (lone continuation, or 0xF8+). Shape-2 leftover.
      out.write(_decodeSingle(b));
      return i + 1;
    }
    switch (_classify(input, i, expected)) {
      case _SequenceShape.complete:
        out.write(_repairRun(utf8.decode(input.sublist(i, i + expected))));
        return i + expected;
      case _SequenceShape.broken:
        // The head can never complete (a non-continuation byte sits inside
        // the promised window): consume the head alone so the stream
        // recovers instead of stalling.
        out.write(_decodeSingle(b));
        return i + 1;
      case _SequenceShape.carried:
        return null;
    }
  }

  /// Whether the sequence starting at [i] (lead promising [expected] bytes)
  /// completed inside this event, merely ran out of bytes (the rest may
  /// arrive with the next stdin read), or is permanently broken by a
  /// non-continuation byte. Only bytes INSIDE the promised window may
  /// disqualify the head — what follows the sequence is unrelated input.
  _SequenceShape _classify(List<int> input, int i, int expected) {
    final remaining = input.length - i;
    final window = expected < remaining ? expected : remaining;
    for (var j = 1; j < window; j++) {
      if ((input[i + j] & 0xC0) != 0x80) return _SequenceShape.broken;
    }
    return window < expected ? _SequenceShape.carried : _SequenceShape.complete;
  }

  String _decodeSingle(int b) {
    final decoded = singleByteDecode?.call(b);
    return decoded ?? '\uFFFD';
  }

  String _repairRun(String run) {
    final repair = runRepair;
    if (repair == null) return run;
    final out = StringBuffer();
    for (final rune in run.runes) {
      if (rune >= 0xA0 && rune <= 0xFF) {
        out.write(repair(String.fromCharCode(rune)));
      } else {
        out.writeCharCode(rune);
      }
    }
    return out.toString();
  }
}

/// Outcome of [_classify] for one multi-byte sequence head.
enum _SequenceShape {
  /// Every promised byte present and valid — decode and advance.
  complete,

  /// The event ended mid-sequence with valid continuations so far — carry
  /// the tail for the next stdin read.
  carried,

  /// A non-continuation byte sits inside the promised window — the head can
  /// never decode; consume it through the single-byte fallback.
  broken,
}

/// How many bytes a UTF-8 sequence starting with [b] occupies (1 for ASCII),
/// or 0 when [b] cannot start one.
int _utf8SequenceLength(int b) {
  if (b < 0x80) return 1;
  if ((b & 0xE0) == 0xC0) return 2;
  if ((b & 0xF0) == 0xE0) return 3;
  if ((b & 0xF8) == 0xF0) return 4;
  return 0;
}

/// Chunked adapter for [Stream.transform]: each stdin data event goes
/// through [ConsoleLineDecoder.convert]; the carry state lives on the
/// decoder instance the stream was built with.
final class _ConsoleLineChunkedSink
    implements ChunkedConversionSink<List<int>> {
  final ConsoleLineDecoder _decoder;
  final Sink<String> _sink;

  _ConsoleLineChunkedSink(this._decoder, this._sink);

  @override
  void add(List<int> chunk) => _sink.add(_decoder.convert(chunk));

  @override
  void close() => _sink.close();
}
