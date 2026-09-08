// DAP/1 wire frame parsing and the spec error codes.
//
// Port of the Go hub's frames.go. Signature verification always works on
// the raw decoded map (never a typed struct), so frames stay plain maps
// here too — this file holds only the codes, the op resolution and small
// typed accessors.

/// Error codes from the DAP/1 spec.
abstract final class DapCodes {
  static const badSignature = 'bad_signature';
  static const staleTs = 'stale_ts';
  static const replayedNonce = 'replayed_nonce';
  static const notAuthenticated = 'not_authenticated';
  static const accessDenied = 'access_denied';
  static const unknownChannel = 'unknown_channel';
  static const unknownAgent = 'unknown_agent';
  static const mailboxFull = 'mailbox_full';
  static const badFrame = 'bad_frame';
}

/// A parsed client frame: the raw object map (used for signature
/// canonicalization) with typed convenience accessors.
extension type DapFrame(Map<String, Object?> raw) {
  /// The dispatch key. Standard frames carry `op`; the frozen enroll wire
  /// shape uses `t` (`{"t":"enroll"}`). Empty when neither holds a string.
  String get op {
    final op = raw['op'];
    if (op is String && op.isNotEmpty) return op;
    final t = raw['t'];
    return t is String ? t : '';
  }

  String get sig => raw['sig'] as String? ?? '';
  int get ts => (raw['ts'] as num?)?.toInt() ?? 0;
  String get pubkey => raw['pubkey'] as String? ?? '';
  String get x25519 => raw['x25519'] as String? ?? '';
  String get name => raw['name'] as String? ?? '';
  String get nonce => raw['nonce'] as String? ?? '';
  String get channel => raw['channel'] as String? ?? '';
  String get chanPubkey => raw['chanPubkey'] as String? ?? '';
  String get to => raw['to'] as String? ?? '';
  String get id => raw['id'] as String? ?? '';
  String get ciphertext => raw['ciphertext'] as String? ?? '';
  String get agentId => raw['agentId'] as String? ?? '';
}

/// An error carrying a spec error code (the Go port's protoError).
final class DapProtoError implements Exception {
  const DapProtoError(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// Builds a hub→client spec error frame.
Map<String, Object?> errorFrame(String code, String message) =>
    {'op': 'error', 'code': code, 'msg': message};
