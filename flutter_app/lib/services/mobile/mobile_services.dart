// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:fa/services/mobile/mobile_consent.dart';

/// The compile-time build flavor (`--dart-define=FA_FLAVOR=store|god`).
const mobileFlavor = String.fromEnvironment('FA_FLAVOR', defaultValue: 'store');

/// Whether the Android mobile natives are wired in this build (the
/// `dev.fa1.app/mobile*` embedder handlers exist on Android only).
bool get mobilePlatformSupported => !kIsWeb && Platform.isAndroid;

// ---------------------------------------------------------------------------
// own-app log tail — the mobile.logs backend
// ---------------------------------------------------------------------------

/// The ring the log backend reads: the last [_mobileLogRingSize] lines the
/// app itself logged.
///
/// wire: `AppLog.i` in `flutter_app/lib/services/app_log.dart` is the feed
/// point — one `addMobileLogLine(...)` call there fills this ring. The ring
/// stays standalone until then (app_log.dart is owned elsewhere), so
/// mobile.logs reports an empty buffer honestly instead of failing.
const _mobileLogRingSize = 200;
final ListQueue<String> _mobileLogLines = ListQueue<String>();

/// Feeds one line into the mobile log ring (the app log's hook).
void addMobileLogLine(String line) {
  if (_mobileLogLines.length == _mobileLogRingSize) {
    _mobileLogLines.removeFirst();
  }
  _mobileLogLines.addLast(line);
}

/// Clears the ring — tests only.
@visibleForTesting
void resetMobileLogLines() => _mobileLogLines.clear();

/// [MobileLogsBackend] over the app's own ring (other apps' logs are
/// invisible to a third-party package by Android design).
final class MobileLogService implements MobileLogsBackend {
  const MobileLogService();

  @override
  Future<String> recentLines({int lines = 100}) async {
    final all = _mobileLogLines.toList(growable: false);
    final start = all.length > lines ? all.length - lines : 0;
    return all.sublist(start).join('\n');
  }
}

// ---------------------------------------------------------------------------
// launch + inventory — works in BOTH flavors
// ---------------------------------------------------------------------------

/// [MobileLaunchBackend] over `dev.fa1.app/mobile_launch`.
final class MobileLaunchService implements MobileLaunchBackend {
  /// [queryAllPackages] is the sync gate for the QUERY_ALL_PACKAGES
  /// inventory: the store build answers `null` without touching the
  /// channel (the launch tool then gives the sideload reason); god probes
  /// the embedder. Defaults from the compile-time flavor; tests inject.
  const MobileLaunchService({bool? queryAllPackages})
      : _queryAllPackages = queryAllPackages ?? (mobileFlavor == 'god');

  final bool _queryAllPackages;

  static const _channel = MethodChannel('dev.fa1.app/mobile_launch');

  @override
  Future<void> launch({String? packageName, String? deepLink}) async {
    if (packageName == null && deepLink == null) {
      throw StateError('nothing to launch — pass a package or deep link');
    }
    final target = packageName ?? deepLink;
    try {
      await _channel.invokeMethod<void>('launch', {
        'packageName': ?packageName,
        'deepLink': ?deepLink,
      });
    } on MissingPluginException {
      // Store build: the handler answers notImplemented — nothing resolves.
      throw StateError('nothing resolves for $target');
    } on PlatformException catch (e) {
      throw StateError(e.message ?? 'nothing resolves for $target');
    }
  }

  @override
  Future<List<MobileAppEntry>> launcherApps() async =>
      [for (final row in await _appRows('launcherApps')) _appOf(row!)];

  /// Null when this build lacks QUERY_ALL_PACKAGES (store flavor) — the
  @override
  Future<List<MobileAppEntry>>? allPackages() {
    if (!_queryAllPackages) return null;
    return _channel.invokeListMethod<dynamic>('allPackages').then(
          (rows) =>
              [for (final row in rows ?? const <dynamic>[]) _appOf(row!)],
          onError: (Object e) {
            if (e is MissingPluginException) return const <MobileAppEntry>[];
            throw e;
          },
        );
  }

  /// Channel rows; empty when the native side is absent/notImplemented.
  static Future<List<dynamic>> _appRows(String method) async {
    try {
      return await _channel.invokeListMethod<dynamic>(method) ?? const [];
    } on MissingPluginException {
      return const [];
    }
  }

  static MobileAppEntry _appOf(Map<Object?, Object?> row) => MobileAppEntry(
        packageName: row['packageName']?.toString() ?? '',
        label: row['label']?.toString(),
      );
}

// ---------------------------------------------------------------------------
// observe + gestures — god tier only (accessibility + projection)
// ---------------------------------------------------------------------------

/// Translates channel failures into the named states the tools answer
/// with: native codes pass through, a missing handler (store build / no
/// embedder, e.g. plain unit tests) is the offline state.
Future<T> _guard<T>(Future<T> Function() run) async {
  try {
    return await run();
  } on PlatformException catch (e) {
    throw switch (e.code) {
      MobileErrorCode.projectionReconsent => MobileAutomationException.reconsent(),
      MobileErrorCode.shizukuNotRunning => MobileAutomationException.shizukuNotRunning(),
      // automation-offline and any native-specific code: keep the code and
      // the native message (it names the recovery path).
      _ => MobileAutomationException(e.code, e.message ?? MobileErrorCode.automationOffline),
    };
  } on MissingPluginException {
    throw MobileAutomationException.offline();
  }
}

/// [MobileAutomationBackend] over `dev.fa1.app/mobile_automation`.
final class MobileAutomationService implements MobileAutomationBackend {
  const MobileAutomationService();

  static const _channel = MethodChannel('dev.fa1.app/mobile_automation');

  @override
  Future<String> dumpHierarchy() =>
      _guard(() async => await _channel.invokeMethod<String>('dumpHierarchy') ?? '');

  @override
  Future<MobileScreenshot> screenshot() => _guard(() async {
        final png = await _channel.invokeMethod<Uint8List>('screenshot');
        return MobileScreenshot(pngBytes: png ?? Uint8List(0));
      });

  @override
  Future<void> tap(MobileTapTarget target) => _guard(() => switch (target) {
        MobileTapById(:final elementId) =>
          _channel.invokeMethod<void>('tap', {'elementId': elementId}),
        MobileTapAtPoint(:final x, :final y) =>
          _channel.invokeMethod<void>('tap', {'x': x, 'y': y}),
      });

  @override
  Future<void> swipe({
    required int fromX,
    required int fromY,
    required int toX,
    required int toY,
    int durationMs = 300,
  }) =>
      _guard(() => _channel.invokeMethod<void>('swipe', {
            'fromX': fromX,
            'fromY': fromY,
            'toX': toX,
            'toY': toY,
            'durationMs': durationMs,
          }));

  @override
  Future<void> text({
    String? elementId,
    required String text,
    bool clear = false,
  }) =>
      _guard(() => _channel.invokeMethod<void>('text', {
            'elementId': ?elementId,
            'text': text,
            'clear': clear,
          }));
}

// ---------------------------------------------------------------------------
// Shizuku shell bridge — god tier, opt-in
// ---------------------------------------------------------------------------

/// [MobileShellBackend] over `dev.fa1.app/mobile_shell`.
final class MobileShellService implements MobileShellBackend {
  MobileShellService() {
    unawaited(_probe());
  }

  static const _channel = MethodChannel('dev.fa1.app/mobile_shell');

  bool _running = false;

  /// The binder state is async on the channel but the contract's getter is
  /// sync: answer with the last probe's result — refreshed at construction
  /// and after every [run]. An absent native side stays `false`.
  @override
  bool get isRunning => _running;

  /// Re-probes the binder state — exposed so tests can await it.
  @visibleForTesting
  Future<void> probe() => _probe();

  Future<void> _probe() async {
    try {
      _running = await _channel.invokeMethod<bool>('isRunning') ?? false;
    } catch (_) {
      // Absent handler, notImplemented, malformed payload — no bridge.
      _running = false;
    }
  }

  @override
  Future<MobileShellResult> run(String command, {int? timeoutMs}) async {
    try {
      final result = await _guard(
        () => _channel.invokeMapMethod<String, dynamic>('run', {
          'command': command,
          'timeoutMs': ?timeoutMs,
        }),
      );
      _running = true;
      return MobileShellResult(
        exitCode: (result?['exitCode'] as num?)?.toInt() ?? -1,
        stdout: result?['stdout']?.toString() ?? '',
        stderr: result?['stderr']?.toString() ?? '',
      );
    } on MobileAutomationException catch (e) {
      if (e.code == MobileErrorCode.shizukuNotRunning) _running = false;
      rethrow;
    } on MissingPluginException {
      _running = false;
      throw MobileAutomationException.shizukuNotRunning();
    }
  }
}

// ---------------------------------------------------------------------------
// control plane — the consent UI's toggles
// ---------------------------------------------------------------------------

/// Control queries over `dev.fa1.app/mobile`: flavor introspection plus the
/// accessibility / projection-consent toggles the consent UI drives. The
/// store flavor's native side answers notImplemented for the toggles.
final class MobileControl implements MobileControlContract {
  const MobileControl({MethodChannel? channel})
      : _channel = channel ?? _defaultChannel;
  static const _defaultChannel = MethodChannel('dev.fa1.app/mobile');

  final MethodChannel _channel;

  /// The native-reported flavor, falling back to the compile-time const.
  @override
  Future<String> flavor() async {
    try {
      return await _channel.invokeMethod<String>('flavor') ?? mobileFlavor;
    } on MissingPluginException {
      return mobileFlavor;
    }
  }

  /// Whether the accessibility service is currently enabled.
  @override
  Future<bool> accessibilityEnabled() async =>
      await _channel.invokeMethod<bool>('accessibilityEnabled') ?? false;

  /// Opens the system accessibility settings (the recovery path the tools'
  /// offline answer points at).
  @override
  Future<void> openAccessibilitySettings() =>
      _channel.invokeMethod<void>('openAccessibilitySettings');

  /// Turns the accessibility service off.
  @override
  Future<void> disableAccessibility() =>
      _channel.invokeMethod<void>('disableAccessibility');

  /// (Re-)shows the MediaProjection consent dialog; true when granted.
  @override
  Future<bool> projectionConsent() async =>
      await _channel.invokeMethod<bool>('projectionConsent') ?? false;
}

MobileControl? _defaultControl;

/// The process-wide control instance (lazily created). The consent UI and
/// diagnostics share this one; tests inject their own [MobileControl].
MobileControl get defaultMobileControl => _defaultControl ??= const MobileControl();

// ---------------------------------------------------------------------------
// the tier wiring
// ---------------------------------------------------------------------------

/// Builds the `mobile.*` tools for [flavor] (default: [mobileFlavor]).
///
/// store: launch/logs only — the capability floor gates the automation and
/// shell surfaces with the honest sideload reason. god: the full set; the
/// Shizuku bridge answers its named not-running state at call time when the
/// user has not opted in (the floor says the wiring exists, the bridge says
/// whether it is awake).
List<AgentTool> mobileToolsForFlavor({String? flavor}) {
  const logs = MobileLogService();
  return switch (flavor ?? mobileFlavor) {
    'god' => mobileTools(
        launch: MobileLaunchService(queryAllPackages: true),
        logs: logs,
        automation: const MobileAutomationService(),
        shell: MobileShellService(),
      ),
    _ => mobileTools(
        launch: const MobileLaunchService(),
        logs: logs,
      ),
  };
}
