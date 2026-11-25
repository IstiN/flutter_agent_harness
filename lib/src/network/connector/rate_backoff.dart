// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Shared rate-limit primitives of the machine connector — the one place
/// the reconnect loop ([ConnectorUpstreamClient]) and the roster PATCH
/// limiter ([RosterPatchLimiter]) agree on what "throttled" means and how
/// long to wait:
/// - [ConnectorThrottleSignal]: a server refusal for rate reasons (HTTP
///   429 / OpenAPI `throttled`), implemented by the REST client's
///   `DeviceEnrollmentThrottledException` and by
///   [ConnectorUpgradeThrottledException] for a refused `/ws` upgrade;
/// - [parseRetryAfter]: the `Retry-After` header in both wire forms;
/// - [withEqualJitter]: 50–100 % jitter on a backoff step so processes
///   sharing a device never retry in lockstep (the `jitterFraction`
///   convention the roles layer uses).
///
/// Pure Dart: no `dart:io`, no Flutter.
library;

/// A server refusal for rate reasons (HTTP 429 / OpenAPI `throttled`).
///
/// The upstream client and the roster limiter read [retryAfter] off ANY
/// such error without knowing which transport produced it; a null hint
/// means "throttled, pick your own backoff".
abstract interface class ConnectorThrottleSignal {
  /// The server's `Retry-After` hint when it sent one; null otherwise.
  ///
  /// NOTE: `dart:io`'s `WebSocket.connect` surfaces only the status code
  /// of a refused upgrade (never its headers), so the IO transport cannot
  /// forward a `Retry-After` from a rejected `/ws` upgrade — the client
  /// then falls back to its jittered ladder.
  Duration? get retryAfter;
}

/// The `/ws` upgrade was refused with HTTP 429 — the front end shedding
/// load or the server's shared REST/WS budget (contract: "limits shared
/// REST/WS"). Thrown by a [ConnectorTransport]; the client retries with
/// backoff.
final class ConnectorUpgradeThrottledException
    implements Exception, ConnectorThrottleSignal {
  const ConnectorUpgradeThrottledException({this.statusCode, this.retryAfter});

  /// The HTTP status of the refused upgrade (429).
  final int? statusCode;

  @override
  final Duration? retryAfter;

  @override
  String toString() =>
      'ConnectorUpgradeThrottledException(statusCode: $statusCode, '
      'retryAfter: $retryAfter)';
}

/// Longest wait a `Retry-After` hint may impose on its own: a garbage or
/// clock-skewed hint must not stall presence/reconnect for hours.
const retryAfterCeiling = Duration(minutes: 10);

final _retryAfterSeconds = RegExp(r'^\s*(\d{1,9})\s*$');
final _retryAfterHttpDate = RegExp(
  r'^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
);
const _httpDateMonths = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Parses an HTTP `Retry-After` header value (RFC 9110 §10.2.3): either
/// delta-seconds or an HTTP-date resolved against [now]. Returns null for
/// an absent/unparseable value and for a date already in the past (no
/// wait), and clamps to [retryAfterCeiling].
Duration? parseRetryAfter(String? header, {required DateTime now}) {
  if (header == null || header.isEmpty) return null;
  final seconds = _retryAfterSeconds.firstMatch(header);
  if (seconds != null) {
    return _clampRetryAfter(Duration(seconds: int.parse(seconds.group(1)!)));
  }
  final date = _retryAfterHttpDate.firstMatch(header);
  if (date == null) return null;
  final month = _httpDateMonths.indexOf(date.group(2)!);
  if (month < 0) return null;
  final at = DateTime.utc(
    int.parse(date.group(3)!),
    month + 1,
    int.parse(date.group(1)!),
    int.parse(date.group(4)!),
    int.parse(date.group(5)!),
    int.parse(date.group(6)!),
  );
  final wait = at.difference(now.toUtc());
  if (wait <= Duration.zero) return null;
  return _clampRetryAfter(wait);
}

Duration _clampRetryAfter(Duration wait) =>
    wait > retryAfterCeiling ? retryAfterCeiling : wait;

/// [nominal] with "equal jitter": uniformly inside `[50 %, 100 %]` of the
/// step as [jitterFraction] sweeps 0..1 (the `Random().nextDouble`
/// convention). Two clients stuck in an eviction ping-pong therefore
/// spread their reconnects instead of alternating in lockstep, and a
/// ladder step can only shrink — never past half.
Duration withEqualJitter(Duration nominal, double jitterFraction) {
  if (nominal <= Duration.zero) return nominal;
  final clamped = jitterFraction.clamp(0.0, 1.0);
  return Duration(
    microseconds: (nominal.inMicroseconds * (0.5 + 0.5 * clamped)).round(),
  );
}
