/// Response payload models for the fa_network REST API.
///
/// All `fromJson` constructors are tolerant: unknown fields are ignored so
/// the client keeps working when the server adds fields, and optional
/// fields may be absent.
library;

/// Result of `POST /api/networks/{id}/join`: the bearer token used for all
/// authenticated fa_network calls.
final class FanetJoinResult {
  /// Creates a join result.
  const FanetJoinResult({required this.sessionToken});

  /// The session token authenticating this member (Bearer credential).
  final String sessionToken;

  /// Parses the join response, ignoring extra fields such as `network`,
  /// `member`, or `role`.
  ///
  /// Throws a [FormatException] when `sessionToken` is missing or not a
  /// non-empty string.
  factory FanetJoinResult.fromJson(Map<String, Object?> json) {
    final token = json['sessionToken'];
    if (token is! String || token.isEmpty) {
      throw FormatException(
        'fa_network join response is missing "sessionToken": $json',
      );
    }
    return FanetJoinResult(sessionToken: token);
  }
}

/// Validation for fa_network agent names, matching the server-side rule
/// (`^[a-z0-9][a-z0-9-]{2,63}$` — 3–64 chars, lowercase letters, digits and
/// hyphens, must start with a letter or digit). Reused by the UI.
abstract final class FanetAgentName {
  static final _pattern = RegExp(r'^[a-z0-9][a-z0-9-]{2,63}$');

  /// Whether [name] is a valid fa_network agent name. Invalid names are
  /// rejected by the server with `400 invalid_credentials`.
  static bool isValid(String name) => _pattern.hasMatch(name);
}

/// An agent enrolled via `POST /api/networks/{id}/agents/enroll`.
///
/// The [clientSecret] is returned exactly once, at enrollment time, and is
/// never stored or returned again by the server — persist it immediately.
/// To rotate (which also revokes the old secret), simply enroll the same
/// [name] again: re-enrollment returns the same `201` shape with a fresh
/// secret; there is no 409 and no delete endpoint.
final class FanetAgentEnrollment {
  /// Creates an agent enrollment value.
  const FanetAgentEnrollment({
    required this.name,
    required this.hubUrl,
    required this.clientSecret,
    required this.enrolledAt,
    this.note,
  });

  /// The enrolled agent name (identity on the hub).
  final String name;

  /// WebSocket URL of the DAP hub to connect to.
  final String hubUrl;

  /// The secret proving ownership of [name] when connecting. Returned once;
  /// store it now.
  final String clientSecret;

  /// Enrollment timestamp, RFC3339 UTC (always `Z`, no microseconds). Kept
  /// as a raw string.
  final String enrolledAt;

  /// Server-side advisory note (e.g. the store-the-secret warning), if any.
  final String? note;

  /// Parses the enroll response, ignoring extra fields.
  ///
  /// Throws a [FormatException] when a required field (`name`, `hubUrl`,
  /// `clientSecret`, `enrolledAt`) is missing or not a non-empty string.
  factory FanetAgentEnrollment.fromJson(Map<String, Object?> json) {
    String required(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw FormatException(
          'fa_network agent enrollment response is missing "$key": $json',
        );
      }
      return value;
    }

    final noteJson = json['note'];
    return FanetAgentEnrollment(
      name: required('name'),
      hubUrl: required('hubUrl'),
      clientSecret: required('clientSecret'),
      enrolledAt: required('enrolledAt'),
      note: noteJson is String ? noteJson : null,
    );
  }
}
