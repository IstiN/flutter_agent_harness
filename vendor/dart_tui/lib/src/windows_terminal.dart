// coverage:ignore-file
// Windows-only console (Win32 FFI) code. Unreachable on the CI runners
// (macOS/Linux), so it is excluded from the coverage denominator rather than
// force-tested with brittle platform mocks.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'key_buffer_parser.dart' show consoleTextRepair;

// Windows console input-mode flags (consoleapi / wincon.h).
const int _enableProcessedInput = 0x0001;
const int _enableLineInput = 0x0002;
const int _enableEchoInput = 0x0004;
const int _enableMouseInput = 0x0010;
const int _enableQuickEditMode = 0x0040;
const int _enableExtendedFlags = 0x0080;
const int _enableVirtualTerminalInput = 0x0200;
const int _stdInputHandle = 0xFFFFFFF6; // (DWORD)-10

typedef _GetStdHandleC = IntPtr Function(Uint32);
typedef _GetStdHandleD = int Function(int);
typedef _GetConsoleModeC = Int32 Function(IntPtr, Pointer<Uint32>);
typedef _GetConsoleModeD = int Function(int, Pointer<Uint32>);
typedef _SetConsoleModeC = Int32 Function(IntPtr, Uint32);
typedef _SetConsoleModeD = int Function(int, int);
typedef _GetConsoleCpC = Uint32 Function();
typedef _GetConsoleCpD = int Function();
typedef _SetConsoleCpC = Int32 Function(Uint32);
typedef _SetConsoleCpD = int Function(int);
typedef _GetAcpC = Uint32 Function();
typedef _GetAcpD = int Function();
typedef _MultiByteToWideCharC = Int32 Function(
    Uint32, Uint32, Pointer<Uint8>, Int32, Pointer<Uint16>, Int32);
typedef _MultiByteToWideCharD = int Function(
    int, int, Pointer<Uint8>, int, Pointer<Uint16>, int);

/// The UTF-8 code page: what `dart_tui`'s decoder expects on the wire.
const int _utf8CodePage = 65001;

int? _savedMode;
int? _savedCodePage;

/// ANSI-code-page (GetACP) repair map for [consoleTextRepair]: the Latin-1
/// char a legacy console mis-delivers → the character actually typed.
/// Built once when raw mode is first entered; empty when the ANSI page is
/// UTF-8, the probe fails, or the platform is not Windows.
final Map<String, String> _mojibakeRepairMap = {};

/// Whether [_mojibakeRepairMap] has been probed (build once — raw mode can
/// be entered/exited many times per process).
var _mojibakeRepairProbed = false;

/// Puts the Windows console **input** handle into raw virtual-terminal mode so
/// arrow keys, Esc, Shift+Tab, function keys and the mouse arrive as the escape
/// sequences [TerminalInputDecoder] understands.
///
/// Flipping Dart's `stdin.lineMode`/`echoMode` alone is not enough on Windows:
/// it leaves the console in legacy input mode, where those events never reach
/// the byte stream at all (only plain ASCII does). Enabling
/// `ENABLE_VIRTUAL_TERMINAL_INPUT` is what makes them work; clearing
/// `ENABLE_QUICK_EDIT_MODE` is what lets mouse clicks through instead of being
/// captured as text selection, and clearing `ENABLE_PROCESSED_INPUT` delivers
/// Ctrl+C as a byte (matching Unix raw mode) rather than a console signal.
///
/// No-op on non-Windows platforms or when stdin is not a real console. Call it
/// while entering raw mode; the previous mode is saved for [restoreWindowsVtInput].
void enableWindowsVtInput() {
  if (!Platform.isWindows) return;
  final k32 = DynamicLibrary.open('kernel32.dll');
  final getStdHandle =
      k32.lookupFunction<_GetStdHandleC, _GetStdHandleD>('GetStdHandle');
  final getConsoleMode =
      k32.lookupFunction<_GetConsoleModeC, _GetConsoleModeD>('GetConsoleMode');
  final setConsoleMode =
      k32.lookupFunction<_SetConsoleModeC, _SetConsoleModeD>('SetConsoleMode');

  final handle = getStdHandle(_stdInputHandle);
  final modePtr = calloc<Uint32>();
  try {
    if (getConsoleMode(handle, modePtr) == 0) return; // not a console
    _savedMode ??= modePtr.value;
    final next = (modePtr.value |
            _enableVirtualTerminalInput |
            _enableExtendedFlags |
            _enableMouseInput) &
        ~(_enableQuickEditMode |
            _enableLineInput |
            _enableEchoInput |
            _enableProcessedInput);
    setConsoleMode(handle, next);
    // The console hands input over in its INPUT code page: under a legacy OEM
    // page (866/1251 on a Russian Windows) a Cyrillic keystroke is a single
    // byte like 0xEF, which `key_buffer_parser.dart` cannot decode as UTF-8 —
    // and a stream stuck on such a byte swallows every later keystroke too
    // ("cannot type Russian at all"). UTF-8 makes non-ASCII arrive in the
    // bytes the decoder already understands.
    try {
      final getConsoleCP =
          k32.lookupFunction<_GetConsoleCpC, _GetConsoleCpD>('GetConsoleCP');
      final setConsoleCP =
          k32.lookupFunction<_SetConsoleCpC, _SetConsoleCpD>('SetConsoleCP');
      final previousCp = getConsoleCP();
      if (previousCp != 0 && previousCp != _utf8CodePage) {
        _savedCodePage ??= previousCp;
        setConsoleCP(_utf8CodePage);
      }
    } on Object {
      // Older Windows / not a real console: the parser's recovery path below
      // still keeps the input stream alive.
    }
    // Even with the input page flipped to UTF-8, some consoles translate
    // keyboard bytes through the ANSI page first (and ConPTY-era hosts the
    // flip never reaches keep the legacy page entirely): 'п' then arrives
    // either as the Latin-1 rune 'ï' (the ANSI byte re-encoded as UTF-8) or
    // as the bare byte 0xEF. Both decode through `key_buffer_parser.dart`
    // into Latin-1-range text — repair it back through the ANSI page
    // (fa issue #1973 follow-up: Russian typing).
    _installMojibakeRepairMap(k32);
  } finally {
    calloc.free(modePtr);
  }
}

/// Restores the console input mode captured by the first [enableWindowsVtInput]
/// call. No-op on non-Windows platforms or if it was never enabled.
void restoreWindowsVtInput() {
  if (!Platform.isWindows) return;
  final savedCp = _savedCodePage;
  // The parser hook must not survive the raw session: after restore the
  // console is back in whatever mode the host set, and repairing decoded
  // text through a stale table would corrupt plain UTF-8 input. Cleared
  // before the saved-mode early return so every restore path hits it.
  consoleTextRepair = null;
  if (savedCp != null) {
    try {
      DynamicLibrary.open('kernel32.dll')
              .lookupFunction<_SetConsoleCpC, _SetConsoleCpD>('SetConsoleCP')(
          savedCp);
    } on Object {
      // Best effort: never block the teardown on a console that went away.
    }
    _savedCodePage = null;
  }
  final saved = _savedMode;
  if (saved == null) return;
  final k32 = DynamicLibrary.open('kernel32.dll');
  final getStdHandle =
      k32.lookupFunction<_GetStdHandleC, _GetStdHandleD>('GetStdHandle');
  final setConsoleMode =
      k32.lookupFunction<_SetConsoleModeC, _SetConsoleModeD>('SetConsoleMode');
  setConsoleMode(getStdHandle(_stdInputHandle), saved);
  _savedMode = null;
}

/// Builds the ANSI-code-page repair map (once per process) and installs it
/// as [consoleTextRepair]. Only Latin-1-supplement entries that differ from
/// the char itself land in the map; an empty map leaves the hook unset —
/// every other platform keeps byte-for-byte identity decoding.
void _installMojibakeRepairMap(DynamicLibrary k32) {
  if (!_mojibakeRepairProbed) {
    _mojibakeRepairProbed = true;
    try {
      final getAcp = k32.lookupFunction<_GetAcpC, _GetAcpD>('GetACP');
      final multiByteToWideChar =
          k32.lookupFunction<_MultiByteToWideCharC, _MultiByteToWideCharD>(
              'MultiByteToWideChar');
      final ansiCodePage = getAcp();
      if (ansiCodePage != 0 && ansiCodePage != _utf8CodePage) {
        final inBuf = calloc<Uint8>();
        final outBuf = calloc<Uint16>();
        try {
          for (var b = 0xA0; b <= 0xFF; b++) {
            inBuf.value = b;
            if (multiByteToWideChar(ansiCodePage, 0, inBuf, 1, outBuf, 1) ==
                1) {
              final wide = String.fromCharCode(outBuf.value);
              if (wide != String.fromCharCode(b)) {
                _mojibakeRepairMap[String.fromCharCode(b)] = wide;
              }
            }
          }
        } finally {
          calloc.free(inBuf);
          calloc.free(outBuf);
        }
      }
    } on Object {
      // Stripped kernel32 / probe failure: no repair (identity decode).
    }
  }
  consoleTextRepair = _mojibakeRepairMap.isEmpty ? null : _repairConsoleText;
}

final RegExp _latin1Range = RegExp('[\u00A0-\u00FF]');

String _repairConsoleText(String text) => text.replaceAllMapped(
    _latin1Range, (m) => _mojibakeRepairMap[m[0]] ?? m[0]!);
