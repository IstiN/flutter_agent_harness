/// A self-hosted DAP/1 hub in pure Dart: relays end-to-end-encrypted,
/// pubkey-ACL'd channels (DM and presence included) between agent
/// clients. The hub is a zero-knowledge router — it never sees
/// plaintext, holding only ciphertext frames, public keys and hashes.
///
/// This is the pure Dart core: no `dart:io`. Serve real WebSockets via
/// `package:dap_hub/io.dart` ([DapHubServer]); bind any other transport
/// by implementing [DapConnection].
///
/// Wire contract: DAP/1 (docs/protocol.md in the dap project).
library;

export 'src/config.dart';
export 'src/connection.dart';
export 'src/frames.dart' show DapCodes, DapFrame, DapProtoError;
export 'src/hub.dart';
export 'src/persistence.dart';
export 'src/session.dart' show ClientSession, DapAuthKind, maxQueuedBytes;
