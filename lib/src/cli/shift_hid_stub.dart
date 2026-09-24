/// Web stub for the HID Shift poller: the browser has no HID keyboard
/// state and no WindowServer attach, so polling is always off.
/// Signatures mirror `shift_hid_io.dart`.
library;

import 'dart:async';
import 'dart:isolate' show SendPort;

/// Never pressed on the web.
bool isShiftPressedViaHid() => false;

/// Always off on the web.
bool hidShiftPollingEnabled(Map<String, String> env) => false;

/// No isolate probes on the web — report the session as unhealthy for
/// HID polling so callers keep the feature disabled.
Future<bool> probeHidShiftPolling({
  void Function(SendPort port)? entry,
  Duration timeout = const Duration(milliseconds: 300),
}) async => false;

/// Resolves to null: the web TUI runs without Shift-accelerator wiring.
Future<bool Function()?> resolveHidShiftPressed({
  Map<String, String>? env,
  bool isMacOS = true,
  void Function(SendPort port)? probeEntry,
  Duration probeTimeout = const Duration(milliseconds: 300),
}) async => null;
