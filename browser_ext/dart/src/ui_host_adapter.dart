/// SW-side glue between the v2 UI protocol server (ui_port_server.dart)
/// and the agent host: pass-throughs for the agent seam plus the settings
/// mapping. Pure Dart (compiled into the SW; tests drive it with a fake
/// backend) — the js_interop plumbing lives in agent_main.dart.
library;

import 'dart:async';

import 'ui_port_server.dart';

/// The slice of the host the adapter forwards to. An interface (not
/// agent_host.dart directly) so this file and its tests stay free of the
/// js_interop storage chain agent_host pulls in; AgentHost implements it
/// verbatim.
abstract interface class UiHostBackend {
  void sendUser(String text);
  void cancelTurn();
  void decide(String id, bool allow);
  Map<String, dynamic> getState();
  String get sessionId;
  List<Map<String, dynamic>> sessionsList();
}

/// chrome.storage keys the settings flow reads and writes — identical to
/// the v1 panel provider.save flow, so panel settings stay one source of
/// truth regardless of which surface wrote them.
const uiSettingsKeys = {'faProvider', 'faApproval', 'faDap'};

/// [UiHostConnector] over a lazily-resolved host. The backend resolves at
/// CALL time (not construction) because the SW boots asynchronously: ports
/// can connect before `AgentHost.boot` finishes, and those early messages
/// must still land on the live host.
final class UiHostAdapter implements UiHostConnector {
  UiHostAdapter({
    required this.backend,
    required this.onSettings,
    this.persist,
  });

  final UiHostBackend? Function() backend;
  final void Function(Map<String, Object?> settings) onSettings;
  final Future<void> Function(String key, Object? value)? persist;

  /// In-memory mirror of the stored settings. chrome.storage is async,
  /// the protocol's settingsGet is sync — the wiring seeds this snapshot
  /// at boot, and every put updates it before persisting, so reads are
  /// always current.
  final _settings = <String, Object?>{};

  /// Merges the raw stored map (as read at SW boot) into the snapshot.
  void seed(Map<Object?, Object?> raw) {
    for (final key in uiSettingsKeys) {
      if (raw.containsKey(key)) _settings[key] = raw[key];
    }
  }

  @override
  Map<String, dynamic> settingsGet() => Map.of(_settings);

  @override
  void settingsPut(Map<String, dynamic> settings) {
    var changed = false;
    for (final key in uiSettingsKeys) {
      if (!settings.containsKey(key)) continue;
      _settings[key] = settings[key];
      changed = true;
      final sink = persist;
      if (sink != null) {
        unawaited(sink(key, settings[key]).catchError((Object _) {}));
      }
    }
    if (changed) onSettings(Map.of(_settings));
  }

  @override
  void sendUser(String text) => backend()?.sendUser(text);

  @override
  void cancelTurn() => backend()?.cancelTurn();

  @override
  void decide(String approvalId, bool allow) =>
      backend()?.decide(approvalId, allow);

  @override
  Map<String, dynamic> state() =>
      backend()?.getState() ?? const <String, dynamic>{'booted': false};

  @override
  String get sessionId => backend()?.sessionId ?? '';

  @override
  List<Map<String, dynamic>> sessionsList() =>
      backend()?.sessionsList() ?? const [];
}
