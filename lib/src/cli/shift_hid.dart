/// Shift+Enter HID polling for the interactive TUI (issue #355).
///
/// Terminals that do not encode the Shift modifier in the input stream
/// expose it through the macOS HID state: the TUI's Enter handler polls
/// CoreGraphics synchronously from inside `Model.update` — the same drain
/// loop that drives rendering and the SIGINT handler. Outside a GUI login
/// session (SSH) the `CGEventSourceFlagsState` Mach call blocks
/// indefinitely instead of answering, freezing the whole REPL (Ctrl+C
/// dead, `kill -9` only).
///
/// This library keeps that call out of hostile sessions:
///
/// - `FA_TUI_SHIFT_HID=0` — explicit kill switch (mirrors `FA_TUI_MOUSE`);
/// - `SSH_CONNECTION`/`SSH_TTY` set — SSH session, HID unavailable;
/// - a one-shot startup probe ([probeHidShiftPolling]) runs the poll in a
///   sacrificial isolate with a ~300 ms timeout — a hang marks HID
///   polling unavailable for the session and the isolate is killed.
///
/// Degradation is the pre-TUI status quo: modifier-encoding terminals
/// still deliver Shift+Enter on the wire (kitty `shift+enter`, legacy
/// `ESC CR` — #77); a bare CR stays a plain submit.
///
/// Exported only from `lib/io.dart` — web has no FFI and never wires a
/// TUI host.
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

typedef _CGEventSourceFlagsStateC = ffi.Uint64 Function(ffi.Uint32);
typedef _CGEventSourceFlagsStateDart = int Function(int);

/// Resolved once at first use; null when CoreGraphics is unavailable
/// (non-macOS hosts — the dylib path simply fails to open).
final int Function(int)? _cgEventSourceFlagsState =
    _lookupCGEventSourceFlagsState();

int Function(int)? _lookupCGEventSourceFlagsState() {
  try {
    final coreGraphics = ffi.DynamicLibrary.open(
      '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
    );
    return coreGraphics.lookupFunction<
      _CGEventSourceFlagsStateC,
      _CGEventSourceFlagsStateDart
    >('CGEventSourceFlagsState');
  } on Object {
    return null;
  }
}

/// The live Shift state from the HID system; false when CoreGraphics is
/// unavailable. Call only after [resolveHidShiftPressed] gated the
/// session — see the library docs.
bool isShiftPressedViaHid() {
  final fn = _cgEventSourceFlagsState;
  if (fn == null) return false;
  const kCGEventSourceStateHIDSystemState = 1;
  const kCGEventFlagMaskShift = 0x00020000;
  return fn(kCGEventSourceStateHIDSystemState) & kCGEventFlagMaskShift != 0;
}

/// Whether the session may poll the HID Shift state at all: the
/// `FA_TUI_SHIFT_HID` kill switch wins, then SSH detection — an SSH
/// session has no WindowServer attach, so the CoreGraphics call blocks
/// instead of answering (issue #355).
bool hidShiftPollingEnabled(Map<String, String> env) {
  final value = env['FA_TUI_SHIFT_HID']?.trim().toLowerCase();
  if (value == '0' || value == 'false' || value == 'no' || value == 'off') {
    return false;
  }
  return env['SSH_CONNECTION'] == null && env['SSH_TTY'] == null;
}

/// Probe entry: performs the HID read once, then ACKs. The message is a
/// completion signal — its VALUE is irrelevant (the live Shift state at
/// boot is almost always up and says nothing about probe health). Runs
/// in a sacrificial isolate ([probeHidShiftPolling]) so a wedged
/// CoreGraphics call cannot freeze the host; tests inject their own
/// entry to simulate a hang.
void _hidProbeEntry(SendPort port) {
  isShiftPressedViaHid();
  port.send(true);
}

/// Runs [entry] in a fresh isolate and waits [timeout] for its
/// completion ACK. True means the HID read COMPLETED in time — the
/// session is healthy enough to poll; a hang (a GUI-less session where
/// CoreGraphics blocks) answers false. Any message counts: the payload
/// value is ignored. The isolate is killed unconditionally — a wedged
/// probe never leaks.
Future<bool> probeHidShiftPolling({
  void Function(SendPort port)? entry,
  Duration timeout = const Duration(milliseconds: 300),
}) async {
  final port = ReceivePort();
  final isolate = await Isolate.spawn(entry ?? _hidProbeEntry, port.sendPort);
  try {
    await port.first.timeout(timeout);
    return true; // any message = the HID read completed in time
  } on TimeoutException {
    return false;
  } finally {
    port.close();
    isolate.kill(priority: Isolate.immediate);
  }
}

/// Resolves the TUI host callback for Shift detection: the HID poll when
/// the session allows it, null when it must stay off — a non-macOS host,
/// the kill switch, an SSH session, or a startup probe whose HID read
/// failed to complete in time (issue #355). Wiring keys on probe
/// COMPLETION, never on the live Shift value it happened to read. The
/// probe runs ONCE, at startup, off the UI isolate; [probeEntry] is the
/// test seam for the isolate payload.
Future<bool Function()?> resolveHidShiftPressed({
  Map<String, String>? env,
  bool isMacOS = true,
  void Function(SendPort port)? probeEntry,
  Duration probeTimeout = const Duration(milliseconds: 300),
}) async {
  if (!isMacOS) return null;
  if (!hidShiftPollingEnabled(env ?? Platform.environment)) return null;
  final ok = await probeHidShiftPolling(
    entry: probeEntry,
    timeout: probeTimeout,
  );
  return ok ? isShiftPressedViaHid : null;
}
