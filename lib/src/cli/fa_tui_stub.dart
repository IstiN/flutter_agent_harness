/// Web-safe stub for `fa_tui.dart` (the dart_tui-based interactive REPL).
///
/// The real TUI needs a raw terminal (`dart:io`, `dart:ffi`), which web
/// builds lack — `agent_cli.dart` is exported from the web-compiled root
/// library, so it imports this file conditionally:
///
/// ```dart
/// import 'fa_tui_stub.dart' if (dart.library.io) 'fa_tui.dart';
/// ```
///
/// The stub mirrors the host-facing API ([FaTuiCallbacks],
/// [FaTuiController]) with no-op behavior; on web `useTui` is always false,
/// so a controller is never actually run. The model/message classes
/// (FaTuiModel, OutputMsg, BusyMsg, OpenPickerMsg, DrainQueueMsg) are
/// VM-only and not part of this surface.
library;

import 'tui_repl.dart' show MenuItem;

/// Host callbacks supplied by [AgentCli] to the dart_tui REPL. See
/// `fa_tui.dart` for field docs.
final class FaTuiCallbacks {
  const FaTuiCallbacks({
    required this.onSubmit,
    required this.onModelSelected,
    required this.buildSlashMenu,
    required this.buildModelMenu,
    required this.statusLine,
    required this.prompt,
    this.onInterrupt,
    this.isShiftPressed,
    this.opensPicker,
    this.onPickerSelected,
    this.onPickerCancelled,
    this.onSteer,
  });

  final Future<void> Function(String line) onSubmit;
  final Future<void> Function(String modelId) onModelSelected;
  final List<MenuItem> Function(String prefix) buildSlashMenu;
  final List<MenuItem> Function(String filter) buildModelMenu;
  final String Function() statusLine;
  final String prompt;
  final void Function()? onInterrupt;
  final bool Function()? isShiftPressed;
  final bool Function(String key)? opensPicker;
  final Future<void> Function(String pickerId, String key)? onPickerSelected;
  final void Function(String pickerId)? onPickerCancelled;
  final Future<void> Function(List<String> messages)? onSteer;
}

/// No-op stand-in for the real TUI controller (never run on web).
final class FaTuiController {
  FaTuiController({required this.callbacks, required this.isExited});

  final FaTuiCallbacks callbacks;
  final bool Function() isExited;

  void sendOutput(String text, {bool newline = false}) {}

  void sendModelsRefresh() {}

  void openModelMenu() {}

  void openPicker(
    String pickerId,
    String title,
    List<MenuItem> items, {
    String? initialKey,
  }) {}

  void sendQuit() {}

  void sendBusy(bool busy) {}

  Future<List<String>> drainQueue() async => const [];

  Future<void> run() async {}
}
