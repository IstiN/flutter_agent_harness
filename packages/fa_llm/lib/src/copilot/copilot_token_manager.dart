import 'copilot_token.dart';

/// Caches the short-lived Copilot API token and refreshes it proactively.
///
/// Semantics (copilot-proxy-go `internal/auth/github_client.go`): refresh
/// [refreshLead] before expiry, never more often than [minRefreshSpacing],
/// and never two exchanges at once (single-flight). One instance per
/// account entry — state of different entries never intersects.
class CopilotTokenManager {
  final Future<CopilotToken> Function() exchange;
  final DateTime Function() now;
  final Future<void> Function(Duration wait) delay;
  final Duration refreshLead;
  final Duration minRefreshSpacing;

  CopilotToken? _cached;
  Future<CopilotToken>? _inFlight;
  DateTime? _lastExchangeAt;

  CopilotTokenManager({
    required this.exchange,
    DateTime Function()? now,
    Future<void> Function(Duration wait)? delay,
    this.refreshLead = const Duration(minutes: 2),
    this.minRefreshSpacing = const Duration(seconds: 30),
  }) : now = now ?? DateTime.now,
       delay = delay ?? ((wait) => Future<void>.delayed(wait));

  /// Refresh decision as a pure function: refresh when the token is missing
  /// or reaches its expiry minus the lead window.
  static bool shouldRefresh(CopilotToken? token, DateTime now, Duration lead) {
    if (token == null) return true;
    return !now.isBefore(token.expiresAt.subtract(lead));
  }

  /// Returns a valid token, refreshing when the cached one is due to expire.
  Future<String> get() async {
    if (shouldRefresh(_cached, now(), refreshLead)) {
      _cached = await _inFlightExchange();
    }
    return _cached!.token;
  }

  /// Drops the cached token and refreshes (e.g. after a 401/403).
  Future<String> getAgain() async {
    invalidate();
    return get();
  }

  void invalidate() => _cached = null;

  Future<CopilotToken> _inFlightExchange() {
    return _inFlight ??= _exchangeSpacingAware().whenComplete(
      () => _inFlight = null,
    );
  }

  Future<CopilotToken> _exchangeSpacingAware() async {
    final last = _lastExchangeAt;
    if (last != null) {
      final since = now().difference(last);
      if (since < minRefreshSpacing) {
        await delay(minRefreshSpacing - since);
      }
    }
    final token = await exchange();
    _lastExchangeAt = now();
    return token;
  }
}
