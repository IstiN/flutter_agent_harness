/// SW-side glue between the v2 UI protocol server (ui_port_server.dart)
/// and the agent host: pass-throughs for the agent seam plus the settings
/// mapping. Pure Dart (compiled into the SW; tests drive it with a fake
/// backend) — the js_interop plumbing lives in agent_main.dart.
library;

import 'dart:async';

import 'settings_merge.dart';
import 'ui_port_server.dart';
import 'ui_protocol.dart';

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

  /// `session_new`: archive the live JSONL and start a fresh session in
  /// place. Throws when not booted or while a turn runs (busy).
  Future<void> newSession();

  /// The live tool list with enabled flags (panel Tools section).
  List<UiToolState> toolsList();

  /// Applies per-tool enabled flags from the panel.
  void toolsPut(List<UiToolState> tools);

  /// One-shot host capability request (`ext_request`: cookies.get_all /
  /// fetch / tabs.create). Throws on unknown ops and param problems —
  /// the port server wraps that into a structured ext_result.
  Future<Map<String, dynamic>> extRequest(
    String op,
    Map<String, dynamic> params,
  );
}

/// chrome.storage keys the settings flow reads and writes — identical to
/// the v1 panel provider.save flow, so panel settings stay one source of
/// truth regardless of which surface wrote them.
const uiSettingsKeys = {'faProvider', 'faApproval', 'faDap', 'faBrowserTools'};

/// [UiHostConnector] over a lazily-resolved host. The backend resolves at
/// CALL time (not construction) because the SW boots asynchronously: ports
/// can connect before `AgentHost.boot` finishes, and those early messages
/// must still land on the live host.
final class UiHostAdapter implements UiHostConnector {
  UiHostAdapter({
    required this.backend,
    required this.onSettings,
    this.persist,
    this.merge,
  });

  final UiHostBackend? Function() backend;
  final void Function(Map<String, Object?> settings) onSettings;
  final Future<void> Function(String key, Object? value)? persist;

  /// Optional field-level merge applied before a put is stored/persisted
  /// (`faProvider` uses it so a partial panel save cannot wipe stored
  /// values — see settings_merge.dart).
  final Object? Function(String key, Object? incoming, Object? stored)? merge;

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
      final m = merge;
      final value = m == null
          ? settings[key]
          : m(key, settings[key], _settings[key]);
      _settings[key] = value;
      changed = true;
      final sink = persist;
      if (sink != null) {
        unawaited(sink(key, value).catchError((Object _) {}));
      }
    }
    if (changed) onSettings(Map.of(_settings));
  }

  @override
  List<UiToolState> toolsList() => backend()?.toolsList() ?? const [];

  @override
  void toolsPut(List<UiToolState> tools) => backend()?.toolsPut(tools);

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

  @override
  Future<void> newSession() async {
    final host = backend();
    if (host == null) throw StateError('host not booted');
    await host.newSession();
  }

  @override
  Future<Map<String, dynamic>> extRequest(
    String op,
    Map<String, dynamic> params,
  ) async {
    final host = backend();
    if (host == null) throw 'host not booted';
    return host.extRequest(op, params);
  }
}

/// The [UiHostAdapter.merge] hook for `faProvider`: field-level merge so a
/// panel save without a model (or without retyping the key) keeps the
/// stored values instead of wiping the provider.
Object? faProviderMergeHook(String key, Object? incoming, Object? stored) =>
    key == 'faProvider'
    ? mergeProvider(
        stored is Map ? Map<Object?, Object?>.from(stored) : null,
        incoming is Map ? Map<Object?, Object?>.from(incoming) : const {},
      )
    : incoming;
