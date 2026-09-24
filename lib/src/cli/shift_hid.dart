/// Conditional facade for the macOS HID Shift-state poller.
///
/// The real implementation (`shift_hid_io.dart`) needs `dart:ffi`
/// (CoreGraphics), which has no web build. The browser gets
/// `shift_hid_stub.dart`, where every probe answers "off" — the TUI
/// Shift-accelerator simply stays disabled.
library;

export 'shift_hid_io.dart' if (dart.library.js_interop) 'shift_hid_stub.dart';
