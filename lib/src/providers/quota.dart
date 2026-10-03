/// Provider quota & budget monitoring models (issue #823).
///
/// Pure Dart: no `dart:io`, no network. Adapters take an injectable
/// `http.Client`; the service caches; surfaces (CLI /quota, badge, app
/// meters) render from cache only and never block on a fetch.
///
/// Semantics:
/// - `unknown` (a `QuotaFetchResult` with a null quota and a one-line
///   reason) is DISTINCT from `unmetered` (a real `ProviderQuota` with
///   `isUnmetered: true`): unknown means "we could not ask", unmetered
///   means "there is no billing surface".
/// - A null `limit` means the provider tracks usage but caps nothing
///   (prepaid / unlimited); rendering shows `no cap` / `unlimited`, and
///   such providers are never depleted.
library;

import 'package:http/http.dart' as http;

/// Unit a provider's allowance is measured in.
enum QuotaUnit {
  currencyUsd,
  requests,
  tokens,
  unmetered;

  String toJson() => name;

  static QuotaUnit fromJson(Object? value) => QuotaUnit.values.firstWhere(
        (u) => u.name == value,
        orElse: () => QuotaUnit.currencyUsd,
      );
}

/// A provider's remaining-allowance snapshot at [updatedAt].
class ProviderQuota {
  final double? used;
  final double? limit;
  final QuotaUnit unit;
  final DateTime? resetsAt;
  final bool isUnmetered;
  final DateTime updatedAt;

  ProviderQuota({
    this.used,
    this.limit,
    this.unit = QuotaUnit.currencyUsd,
    this.resetsAt,
    this.isUnmetered = false,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now().toUtc();

  /// DIAL-style providers with no billing surface at all: reported
  /// silently, never an error.
  factory ProviderQuota.unmetered({DateTime? updatedAt}) => ProviderQuota(
        unit: QuotaUnit.unmetered,
        isUnmetered: true,
        updatedAt: updatedAt,
      );

  /// `limit - used`, or null when either side is unknown.
  double? get remaining =>
      (limit != null && used != null) ? limit! - used! : null;

  /// Metered and exhausted. A null limit (no cap) is never depleted.
  bool get isDepleted => limit != null && used != null && used! >= limit!;

  /// True past a declared reset point: the cached limit is stale after a
  /// billing reset and must not persist (E4).
  bool isResetOverdue(DateTime now) =>
      resetsAt != null && now.isAfter(resetsAt!);

  Map<String, Object?> toJson() => {
        'used': used,
        'limit': limit,
        'unit': unit.toJson(),
        if (resetsAt != null) 'resetsAt': resetsAt!.toUtc().toIso8601String(),
        if (isUnmetered) 'isUnmetered': true,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  factory ProviderQuota.fromJson(Map<String, Object?> json) => ProviderQuota(
        used: (json['used'] as num?)?.toDouble(),
        limit: (json['limit'] as num?)?.toDouble(),
        unit: QuotaUnit.fromJson(json['unit']),
        resetsAt: json['resetsAt'] is String
            ? DateTime.parse(json['resetsAt'] as String)
            : null,
        isUnmetered: json['isUnmetered'] == true,
        updatedAt: json['updatedAt'] is String
            ? DateTime.parse(json['updatedAt'] as String)
            : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );

  @override
  String toString() =>
      'ProviderQuota(${formatQuotaUsedLimit(this)}, '
      'reset: ${formatQuotaReset(resetsAt, updatedAt)})';
}

/// Result of one quota fetch: either a parsed [ProviderQuota] or an
/// `unknown` with a one-line reason (E2/E3 — no retry storms, no errors
/// surfaced to the user beyond the reason).
class QuotaFetchResult {
  final ProviderQuota? quota;
  final String? reason;

  const QuotaFetchResult.ok(ProviderQuota this.quota) : reason = null;
  const QuotaFetchResult.unknown(String this.reason) : quota = null;

  bool get isUnknown => quota == null;

  @override
  String toString() =>
      isUnknown ? 'QuotaFetchResult(unknown: $reason)' : 'QuotaFetchResult($quota)';
}

/// Per-provider quota source: pure parse + injectable [http.Client].
/// Adapters never cache (the service does) and never throw — every
/// failure degrades to `QuotaFetchResult.unknown`.
abstract interface class QuotaAdapter {
  Future<QuotaFetchResult> fetch();
}

/// Capability interface for quota-aware surfaces: providers (or their
/// adapter facades) opt in; absence of the capability renders as
/// `unknown` — never an error.
abstract interface class QuotaAwareProvider {
  Future<ProviderQuota?> fetchQuota({bool forceRefresh});
}

/// Resolver-facing view of quota depletion. A depleted provider is a
/// deprioritization hint only — the resolver stays the single decision
/// point and never hard-blocks on quota.
abstract interface class QuotaFeed {
  bool isDepleted(String providerId);
}

/// Formats one amount: `$48.20` / `$150` / `1840`. Currency keeps two
/// decimals unless the value is integral.
String formatQuotaAmount(double? value, QuotaUnit unit) {
  if (value == null) return '…';
  final String body;
  if (unit == QuotaUnit.currencyUsd) {
    body = _trimNumber(value, value % 1 == 0 ? 0 : 2);
    return '\$$body';
  }
  return _trimNumber(value, 0);
}

String _trimNumber(double value, int fractionDigits) =>
    value.toStringAsFixed(fractionDigits);

/// Renders the used/limit column: `unknown` for a null quota (capability
/// absent or fetch failed — never a `null` literal, E2), `unmetered` for
/// billing-free providers, `$48.20/$150` when both sides are known,
/// `$48.20/no cap` for uncapped prepaid, `unlimited` when nothing is
/// reported at all, `…/$150` when only the limit is known.
String formatQuotaUsedLimit(ProviderQuota? quota) {
  if (quota == null) return 'unknown';
  if (quota.isUnmetered || quota.unit == QuotaUnit.unmetered) return 'unmetered';
  final used = formatQuotaAmount(quota.used, quota.unit);
  final limit =
      quota.limit == null ? null : formatQuotaAmount(quota.limit, quota.unit);
  if (quota.used == null && limit == null) return 'unlimited';
  if (limit == null) return '$used/no cap';
  return '$used/$limit';
}

/// Reset countdown: `''` when unknown, `reset overdue` in the past (E4),
/// otherwise the coarsest nonzero unit (`11d` / `5h` / `3m` / `<1m`).
String formatQuotaReset(DateTime? resetsAt, DateTime now) {
  if (resetsAt == null) return '';
  if (!now.isBefore(resetsAt)) return 'reset overdue';
  final delta = resetsAt.difference(now);
  if (delta.inDays >= 1) return '${delta.inDays}d';
  if (delta.inHours >= 1) return '${delta.inHours}h';
  if (delta.inMinutes >= 1) return '${delta.inMinutes}m';
  return '<1m';
}

/// Status-badge string for the ACTIVE provider: `[OR $48/$150 · 11d]`.
/// Cold cache renders `[OR …]`; unmetered providers render nothing
/// (silent — they must not crowd the status line, AC7).
String formatQuotaBadge({
  required String shortName,
  ProviderQuota? quota,
  required DateTime now,
}) {
  if (quota == null) return '[$shortName …]';
  if (quota.isUnmetered || quota.unit == QuotaUnit.unmetered) return '';
  final isCurrency = quota.unit == QuotaUnit.currencyUsd;
  String? short(double? v) =>
      v == null ? null : '${isCurrency ? r'$' : ''}${_trimNumber(v, 0)}';
  final used = short(quota.used);
  final limit = short(quota.limit);
  final ratio = used == null && limit == null
      ? 'unlimited'
      : limit == null
          ? '${used ?? "…"}/no cap'
          : '$used/$limit';
  final reset = formatQuotaReset(quota.resetsAt, now);
  return '[$shortName $ratio${reset.isEmpty ? '' : ' · $reset'}]';
}
