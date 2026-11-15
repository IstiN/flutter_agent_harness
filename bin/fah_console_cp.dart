part of 'fah.dart';

/// Windows console code-page tables backing [ConsoleLineDecoder]: the
/// line-REPL stdin decoder (`_TerminalCliIO.lines` in `fah_io.dart`).
///
/// A RU-locale Windows console delivers non-ASCII keystrokes in two broken
/// shapes (Russian input unusable in the fa REPL — the TUI's own path is
/// guarded separately in `vendor/dart_tui`):
///
/// - **CP-6501 translation mojibake** — the console re-encodes the ANSI
///   code page BYTE of the character as if it were a code point: 'п'
///   (CP1251 0xEF) arrives as UTF-8 `C3 AF` ('ï'). Repaired with the
///   **ANSI code page** (`GetACP`) map over the decoded Latin-1 range.
/// - **Legacy input pages** — ConPTY pipes / older consoles never leave
///   their OEM page: 'п' arrives as the single byte 0xEF, which strict
///   UTF-8 decoding rejects (a `FormatException` into the input stream —
///   the "cannot type Russian at all" symptom). Repaired with the
///   **console input code page** (`GetConsoleCP`) byte map.
///
/// Tables build once from kernel32 (`MultiByteToWideChar`); any failure
/// (non-Windows, stripped API) leaves them empty and the decoder falls
/// back to plain UTF-8 — today's behavior. `lib/` stays dart:ffi-free:
/// this file is the app boundary (`bin/fah.dart`).

/// Whether the code-page tables were already probed (build once; failures
/// latch as empty maps so every later call is a table lookup).
bool _consoleCpTablesBuilt = false;

/// ANSI-code-page (GetACP) repair map: Latin-1-range char → real character,
/// only entries where the mapping differs from the char itself. Empty =
/// no shape-1 repair (non-Windows, or the ANSI page is UTF-8 / failed).
final Map<String, String> _ansiRepairMap = {};

/// Console-input-code-page (GetConsoleCP) byte map: raw byte → character.
/// Empty = no shape-2 repair; undecodable bytes surface as U+FFFD.
final Map<int, String> _consoleByteMap = {};

/// Latin-1 supplement range — the only chars the mojibake shape produces
/// (single ANSI bytes re-encoded as UTF-8 code points).
final RegExp _latin1Range = RegExp('[\u00A0-\u00FF]');

/// A fresh stdin decoder for one [Stream.transform] chain (the decoder
/// carries cross-chunk byte state, so instances are not shared).
ConsoleLineDecoder _consoleLineDecoder() {
  _buildConsoleCpTables();
  return ConsoleLineDecoder(
    runRepair: _ansiRepairMap.isEmpty
        ? null
        : (run) => run.replaceAllMapped(
            _latin1Range,
            (m) => _ansiRepairMap[m[0]] ?? m[0]!,
          ),
    singleByteDecode: _consoleByteMap.isEmpty
        ? null
        : (b) => _consoleByteMap[b],
  );
}

void _buildConsoleCpTables() {
  if (_consoleCpTablesBuilt) return;
  _consoleCpTablesBuilt = true;
  if (!Platform.isWindows) return;
  try {
    final k32 = DynamicLibrary.open('kernel32.dll');
    final getAcp = k32.lookupFunction<Uint32 Function(), int Function()>(
      'GetACP',
    );
    final getConsoleCp = k32.lookupFunction<Uint32 Function(), int Function()>(
      'GetConsoleCP',
    );
    final multiByteToWideChar = k32
        .lookupFunction<
          Int32 Function(
            Uint32,
            Uint32,
            Pointer<Uint8>,
            Int32,
            Pointer<Uint16>,
            Int32,
          ),
          int Function(int, int, Pointer<Uint8>, int, Pointer<Uint16>, int)
        >('MultiByteToWideChar');
    final ansiCp = getAcp();
    if (ansiCp != 0 && ansiCp != 65001) {
      // The mojibake shape only produces chars in the Latin-1 supplement
      // (single ANSI bytes re-encoded as UTF-8); map that range.
      for (var b = 0xA0; b <= 0xFF; b++) {
        final wide = _byteToWideChar(multiByteToWideChar, ansiCp, b);
        if (wide != null && wide != String.fromCharCode(b)) {
          _ansiRepairMap[String.fromCharCode(b)] = wide;
        }
      }
    }
    final inputCp = getConsoleCp();
    if (inputCp != 0 && inputCp != 65001) {
      for (var b = 0x80; b <= 0xFF; b++) {
        final wide = _byteToWideChar(multiByteToWideChar, inputCp, b);
        if (wide != null) {
          _consoleByteMap[b] = wide;
        }
      }
    }
  } on Object {
    // Stripped kernel32 or a probe failure: keep the maps empty — the
    // decoder degrades to plain UTF-8 (the pre-fix behavior).
  }
}

/// Decodes one ANSI/OEM byte through [codePage] via [multiByteToWideChar].
/// Returns null when the byte has no single-char mapping in that page.
String? _byteToWideChar(
  int Function(int, int, Pointer<Uint8>, int, Pointer<Uint16>, int)
  multiByteToWideChar,
  int codePage,
  int byte,
) {
  final inBuf = calloc<Uint8>();
  final outBuf = calloc<Uint16>();
  try {
    inBuf.value = byte;
    final written = multiByteToWideChar(codePage, 0, inBuf, 1, outBuf, 1);
    if (written != 1) return null;
    return String.fromCharCode(outBuf.value);
  } on Object {
    return null;
  } finally {
    calloc.free(inBuf);
    calloc.free(outBuf);
  }
}
