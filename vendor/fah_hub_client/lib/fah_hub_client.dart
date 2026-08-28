/// DAP/1 hub client for flutter_agent_harness.
///
/// Signed WebSocket messaging (channels, DMs, presence) with end-to-end
/// encrypted payloads — the hub only ever sees ciphertext. Shaped as an
/// upstreamable PR for IstiN/flutter_agent_harness (`lib/src/hub/` there).
library;

export 'src/fah/messaging.dart';
export 'src/fah/plugin.dart';
export 'src/hub/canonical.dart';
export 'src/hub/channels.dart';
export 'src/hub/dap_settings.dart';
export 'src/hub/hub_client.dart';
export 'src/hub/hub_config.dart';
export 'src/hub/hub_messaging_repository.dart';
export 'src/hub/hub_plugin.dart';
export 'src/hub/identity.dart';
export 'src/hub/payload_crypto.dart';
