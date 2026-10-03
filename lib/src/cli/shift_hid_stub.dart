/// Web stub for `shift_hid.dart` (macOS CoreGraphics FFI).
///
/// `dart:ffi` does not compile on the web; `lib/io.dart` conditionally
/// exports this stub there (`if (dart.library.io)`). The TUI host is never
/// wired on web, so every probe answers "unavailable".
///
/// Mirrors the public surface of `shift_hid.dart` — keep in sync.
library;

import 'dart:async';
import 'dart:isolate';

/// Whether Shift is currently held down per the macOS HID state.
///
/// Web: HID polling is unavailable — returns `false` (the pre-TUI status
/// quo: modifier-encoding terminals still deliver Shift+Enter on the wire).
bool isShiftPressedViaHid() => false;

/// Whether HID polling is enabled for the given environment.
///
/// Web: no HID — always `false`, regardless of `FA_TUI_SHIFT_HID`.
bool hidShiftPollingEnabled(Map<String, String> env) => false;

/// One-shot startup probe (native: sacrificial isolate + ~300 ms timeout).
///
/// Web: nothing to probe — HID polling is unavailable.
Future<bool> probeHidShiftPolling({
  void Function(SendPort port)? entry,
  Duration timeout = const Duration(milliseconds: 300),
}) async => false;

/// Resolves the TUI host callback for Shift detection.
///
/// Web: returns `null` — no poller, degradation is the pre-TUI status quo.
Future<bool Function()?> resolveHidShiftPressed({
  Map<String, String>? env,
  bool isMacOS = true,
  void Function(SendPort port)? probeEntry,
  Duration probeTimeout = const Duration(milliseconds: 300),
}) async => null;
