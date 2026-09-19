/// The injectable backends behind the `mobile.*` tools (issue #622).
///
/// The tool contract lives here (pure Dart); the Android implementations
/// bridge to AccessibilityService / MediaProjection / Shizuku through the
/// app's method channels (`flutter_app/lib/services/mobile/`). Tests run
/// the tools against fakes of exactly these interfaces (UT-gesture-1,
/// UT-shell-1, UT-delta-1).
///
/// Named states are exceptions carrying machine-readable [MobileErrorCode]
/// codes so a driver can raise them and the tools can answer with an
/// honest, named plain-text result — never a hang, never a generic failure
/// (UT-tier-3, AC5, E1).
///
/// Pure Dart: no `dart:io`.
library;

import 'dart:typed_data';

/// Codes of the named mobile automation states.
final class MobileErrorCode {
  /// The accessibility service is off (disabled in system settings or
  /// killed by the battery manager) — surfaced with recovery instructions.
  static const automationOffline = 'automation-offline';

  /// The MediaProjection consent token expired (per boot) — the result
  /// tells the agent to re-trigger the consent dialog.
  static const projectionReconsent = 'projection-reconsent';

  /// Shizuku is not running (user has not started it since boot).
  static const shizukuNotRunning = 'shizuku-not-running';

  /// The observe step exceeded its wall-clock budget.
  static const observeBudgetExceeded = 'observe-budget-exceeded';

  const MobileErrorCode._();
}

/// A named mobile automation failure. The tools catch these and return
/// the message as a plain (non-throwing) result the model can react to.
final class MobileAutomationException implements Exception {
  /// Machine-readable code ([MobileErrorCode]).
  final String code;

  /// Human/LLM-readable description with recovery instructions.
  final String message;

  const MobileAutomationException(this.code, this.message);

  /// The accessibility service is not connected.
  factory MobileAutomationException.offline() =>
      const MobileAutomationException(
        MobileErrorCode.automationOffline,
        'automation offline — re-enable in Settings',
      );

  /// The screen-capture consent token died (reboot kills it).
  factory MobileAutomationException.reconsent() =>
      const MobileAutomationException(
        MobileErrorCode.projectionReconsent,
        'screen capture needs re-consent — the system dialog will be '
        'triggered on the next screenshot request',
      );

  /// Shizuku is not running (named error, no hang, no generic failure).
  factory MobileAutomationException.shizukuNotRunning() =>
      const MobileAutomationException(
        MobileErrorCode.shizukuNotRunning,
        'Shizuku not running — start Shizuku (wireless debugging on '
        'Android 11+, or adb from a computer) and enable the Shizuku '
        'bridge in Fa Settings',
      );

  @override
  String toString() => '$code: $message';
}

/// One filtered, index-addressable element of the on-device screen
/// (artemis's filter idea: keep informative-or-interactive nodes, drop
/// pure containers and zero-area nodes).
final class MobileElement {
  /// Stable index id the model addresses taps/typing by (`e12`).
  final String id;

  /// Visible text (never present for password fields).
  final String? text;

  /// Content description (accessibility label).
  final String? contentDesc;

  /// Short view class, e.g. `Button`.
  final String? className;

  /// Fully-qualified view id, e.g. `com.android.settings:id/search_bar`.
  final String? viewId;

  /// `true` when the element accepts click actions.
  final bool clickable;

  /// `true` when the element is a scrollable container.
  final bool scrollable;

  /// `true` when the element is an editable text field.
  final bool editable;

  /// `true` when the element is checkable (checkbox/switch/radio).
  final bool checkable;

  /// Current check state (meaningful only when [checkable]).
  final bool checked;

  /// Bounds as `[left,top][right,bottom]` (uiautomator format).
  final String bounds;

  /// Resolved center coordinates — the coordinate fallback for taps.
  final int centerX;

  /// Resolved center Y coordinate.
  final int centerY;

  const MobileElement({
    required this.id,
    required this.bounds,
    required this.centerX,
    required this.centerY,
    this.text,
    this.contentDesc,
    this.className,
    this.viewId,
    this.clickable = false,
    this.scrollable = false,
    this.editable = false,
    this.checkable = false,
    this.checked = false,
  });
}

/// The filtered element index of one screen observation.
final class MobileElementIndex {
  /// Package of the foreground window the index was taken from.
  final String packageName;

  /// Kept elements in document order (ids `e1..eN` are positions here).
  final List<MobileElement> elements;

  /// `true` when the raw hierarchy was truncated (element cap hit).
  final bool truncated;

  const MobileElementIndex({
    required this.packageName,
    required this.elements,
    this.truncated = false,
  });

  /// Renders the compact numbered index the model reads:
  /// `[e12] Button "OK" id=… bounds=[40,1200][200,1260] center=(120,1230) clickable`.
  String render() {
    final buffer = StringBuffer('screen package: $packageName\n');
    for (final element in elements) {
      buffer.write(element.render());
      buffer.write('\n');
    }
    if (truncated) buffer.write('(index truncated — scroll and re-observe)\n');
    return buffer.toString();
  }
}

/// Renders one element line for [MobileElementIndex.render].
extension MobileElementRender on MobileElement {
  /// The single-line index entry.
  String render() {
    final label = text ?? contentDesc ?? '';
    final parts = <String>[
      '[$id]',
      ?className,
      if (label.isNotEmpty) '"$label"',
      if (viewId != null) 'id=$viewId',
      'bounds=$bounds',
      'center=($centerX,$centerY)',
      if (clickable) 'clickable',
      if (scrollable) 'scrollable',
      if (editable) 'editable',
      if (checkable) checked ? 'checked' : 'unchecked',
    ];
    return parts.join(' ');
  }
}

/// A screenshot capture: PNG bytes (session-local; never leaves the
/// device except inline to the model under the image registry rules).
final class MobileScreenshot {
  /// PNG-encoded bytes.
  final Uint8List pngBytes;

  const MobileScreenshot({required this.pngBytes});
}

/// One installed app in an inventory listing.
final class MobileAppEntry {
  /// Package id, e.g. `com.android.settings`.
  final String packageName;

  /// User-visible label when resolved.
  final String? label;

  const MobileAppEntry({required this.packageName, this.label});
}

/// The outcome of a Shizuku shell command.
final class MobileShellResult {
  /// Process exit code.
  final int exitCode;

  /// Combined stdout (before stderr, like the bash tool's output shape).
  final String stdout;

  /// Stderr.
  final String stderr;

  const MobileShellResult({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
  });
}

/// How a tap targets an element: by index id or by raw coordinates.
sealed class MobileTapTarget {
  const MobileTapTarget();
}

/// Tap the center of the element with this index id (`e12`).
final class MobileTapById extends MobileTapTarget {
  /// The index id from the latest hierarchy observation.
  final String elementId;

  const MobileTapById(this.elementId);
}

/// Tap raw screen coordinates (the artemis fallback when no element fits).
final class MobileTapAtPoint extends MobileTapTarget {
  /// Screen X coordinate.
  final int x;

  /// Screen Y coordinate.
  final int y;

  const MobileTapAtPoint(this.x, this.y);
}

/// Launch/inventory backend: works in BOTH flavors. The store flavor
/// launches apps and deep links and lists launcher-visible apps; the
/// QUERY_ALL_PACKAGES inventory exists only in god.
abstract interface class MobileLaunchBackend {
  /// Launches an app by package name or opens a deep link URI. Throws
  /// [StateError] with a message when nothing resolves.
  Future<void> launch({String? packageName, String? deepLink});

  /// Apps visible to the launcher (Play-safe: no QUERY_ALL_PACKAGES —
  /// backed by the `<queries>` LAUNCHER intent).
  Future<List<MobileAppEntry>> launcherApps();

  /// The full package inventory; `null` when this build lacks
  /// QUERY_ALL_PACKAGES (the store flavor — the tool answers with the
  /// honest gate reason instead, UT-pkg-1).
  Future<List<MobileAppEntry>>? allPackages();
}

/// Observe-and-act backend: the god tier only (AccessibilityService +
/// MediaProjection). Every call probes the service first (E2) and raises
/// [MobileAutomationException.offline] when it is gone.
abstract interface class MobileAutomationBackend {
  /// Dumps the raw accessibility hierarchy XML (uiautomator shape).
  Future<String> dumpHierarchy();

  /// Captures the screen as PNG (MediaProjection).
  Future<MobileScreenshot> screenshot();

  /// Dispatches a tap at [target] (element center or raw point).
  Future<void> tap(MobileTapTarget target);

  /// Dispatches a swipe gesture.
  Future<void> swipe({
    required int fromX,
    required int fromY,
    required int toX,
    required int toY,
    int durationMs,
  });

  /// Enters [text] into the element with [elementId] (or the focused
  /// node). When [clear] is set the previous value is replaced.
  Future<void> text({String? elementId, required String text, bool clear});
}

/// Own-app log tail backend (all tiers): the app's own buffer — other
/// apps' logs are invisible to a third-party package by Android design.
abstract interface class MobileLogsBackend {
  /// The most recent [lines] log lines, oldest first.
  Future<String> recentLines({int lines});
}

/// The Shizuku shell bridge backend (god flavor, opt-in).
abstract interface class MobileShellBackend {
  /// Whether the Shizuku binder is alive right now. Implementations
  /// MUST answer promptly (bounded bind attempt) — never hang.
  bool get isRunning;

  /// Runs [command] through the Shizuku (adb-shell) process.
  Future<MobileShellResult> run(String command, {int timeoutMs});
}
