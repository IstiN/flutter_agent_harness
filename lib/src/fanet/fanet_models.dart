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

/// A DAP session minted by `POST /api/networks/{id}/dap-sessions`.
final class FanetDapSession {
  /// Creates a DAP session value.
  const FanetDapSession({
    required this.dapUrl,
    required this.agentName,
    required this.clientSecret,
    this.env,
  });

  /// WebSocket URL of the DAP hub to connect to.
  final String dapUrl;

  /// The agent identity reserved for this session on the hub.
  final String agentName;

  /// The secret proving ownership of [agentName] when connecting.
  final String clientSecret;

  /// Suggested environment variables for the CLI process, if the server
  /// provided any.
  final Map<String, String>? env;

  /// Parses the mint response, ignoring extra fields.
  ///
  /// Throws a [FormatException] when a required field (`dapUrl`,
  /// `agentName`, `clientSecret`) is missing or not a non-empty string, or
  /// when `env` is present but not a JSON object.
  factory FanetDapSession.fromJson(Map<String, Object?> json) {
    String required(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw FormatException(
          'fa_network DAP session response is missing "$key": $json',
        );
      }
      return value;
    }

    final envJson = json['env'];
    Map<String, String>? env;
    if (envJson != null) {
      if (envJson is! Map) {
        throw FormatException(
          'fa_network DAP session "env" must be a JSON object: $json',
        );
      }
      env = {
        for (final entry in envJson.entries)
          entry.key.toString(): entry.value.toString(),
      };
    }
    return FanetDapSession(
      dapUrl: required('dapUrl'),
      agentName: required('agentName'),
      clientSecret: required('clientSecret'),
      env: env,
    );
  }
}
