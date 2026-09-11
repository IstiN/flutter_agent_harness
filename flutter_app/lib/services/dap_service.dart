// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

export 'dap_service_stub.dart'
    if (dart.library.io) 'dap_service_io.dart'
    if (dart.library.js_interop) 'dap_service_web.dart';

// One snapshot type shared with the CLI (package `DapHubSnapshot`); the
// app-side service interface below stays here.
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show DapHubSnapshot, DapInboundMode;
export 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show DapHubSnapshot, DapInboundMode;

/// A session offered by the named-mode inbound-mail picker.
typedef DapBindableSession = ({String id, String title});

/// One bookmarked hub connection (`faDap.savedConnections` in the
/// extension). [secret] is write-only in spirit: an empty string means an
/// open hub (the password is cleared on switch), a non-empty value rides
/// along when the bookmark becomes active. The UI never echoes it back.
class DapSavedConnection {
  const DapSavedConnection({
    required this.url,
    required this.name,
    this.secret = '',
  });

  final String url;
  final String name;
  final String secret;

  Map<String, Object?> toJson() => {
    'url': url,
    'name': name,
    if (secret.isNotEmpty) 'secret': secret,
  };

  static DapSavedConnection fromJson(Map<Object?, Object?> raw) =>
      DapSavedConnection(
        url: '${raw['url'] ?? ''}'.trim(),
        name: '${raw['name'] ?? ''}'.trim(),
        secret: raw['secret'] is String ? raw['secret'] as String : '',
      );
}

/// Read/write access to the DAP hub connection the app shares with the CLI
/// agents (`~/.dap/config.json`, identity under `~/.dap/keys/fah/`).
///
/// The platform implementation is picked by the conditional export above:
/// the `~/.dap` file-backed service on IO platforms, the service-worker
/// bridge inside the browser extension, and the not-supported stub on a
/// plain web page.
abstract interface class DapHubService {
  /// Loads the resolved settings: URL, name, identity (created on first
  /// use, like the CLI), and channels. No network.
  Future<DapHubSnapshot> load();

  /// Persists the connection to `~/.dap/config.json`. [url] is normalized
  /// (`hub:8787` → `ws://hub:8787/ws`); an empty [name] leaves the saved
  /// name untouched (the persisted format has no clear-name operation).
  Future<void> saveConnection({
    required String url,
    required String name,
    String? secret,
  });

  /// Dials the hub once ([HubPlugin] start → status → dispose) and returns
  /// the snapshot with [DapHubSnapshot.connected] set. Bounded: an
  /// unreachable hub resolves to `false` after the probe timeout instead
  /// of hanging on the client's reconnect loop.
  Future<DapHubSnapshot> probe();

  /// Persists the inbound-mail routing (`boundSession` in the shared
  /// config — `faDap` on the extension, `~/.dap/config.json` on IO):
  /// [mode], plus the target session for [DapInboundMode.named].
  Future<void> saveBinding(
    DapInboundMode mode, {
    String? sessionId,
    String? sessionTitle,
  });

  /// Sessions the named-mode picker offers (live + persisted on this
  /// host). Empty where the host cannot enumerate sessions.
  Future<List<DapBindableSession>> listBindableSessions();
}
