/// OpenRouter quota adapter (issue #823).
///
/// The one REAL documented quota endpoint: `GET /api/v1/auth/key` returns
/// the key's `usage`, `limit` and `limit_remaining` in USD.
/// - `limit == null`      => prepaid key with no cap (usage still tracked).
/// - `limit_remaining == null` => no explicit remaining (derived from
///   limit - usage when possible); usage+limit both null => unlimited.
///
/// Pure parse + injectable [http.Client]; every failure degrades to an
/// unknown result with a one-line reason (E2/E3) — never throws, never
/// logs payload bytes (secrets invariant).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'quota.dart';

class OpenRouterQuotaAdapter implements QuotaAdapter, QuotaAwareProvider {
  OpenRouterQuotaAdapter({
    required this.client,
    required this.resolveApiKey,
    DateTime Function()? now,
    this.endpoint,
  }) : now = now ?? _defaultNow;

  static const defaultEndpointUrl = 'https://openrouter.ai/api/v1/auth/key';

  final http.Client client;
  final Future<String?> Function() resolveApiKey;
  final DateTime Function() now;
  final Uri? endpoint;

  static DateTime _defaultNow() => DateTime.now().toUtc();

  @override
  Future<QuotaFetchResult> fetch() async {
    final key = await resolveApiKey();
    if (key == null || key.isEmpty) {
      return const QuotaFetchResult.unknown('no api key');
    }
    final uri = endpoint ?? Uri.parse(defaultEndpointUrl);
    final http.Response response;
    try {
      response = await client.get(
        uri,
        headers: {'Authorization': 'Bearer $key', 'Accept': 'application/json'},
      );
    } on http.ClientException catch (e) {
      return QuotaFetchResult.unknown('request failed: ${e.message}');
    } catch (_) {
      return const QuotaFetchResult.unknown('request failed');
    }
    if (response.statusCode != 200) {
      return QuotaFetchResult.unknown('HTTP ${response.statusCode}');
    }
    Object? body;
    try {
      body = jsonDecode(response.body);
    } on FormatException catch (_) {
      return const QuotaFetchResult.unknown('invalid response: not JSON');
    }
    final quota = parseOpenRouterKeyQuota(body, now: now());
    if (quota == null) {
      return const QuotaFetchResult.unknown(
        'invalid response: unexpected shape',
      );
    }
    return QuotaFetchResult.ok(quota);
  }

  @override
  Future<ProviderQuota?> fetchQuota({bool forceRefresh = false}) async =>
      (await fetch()).quota;
}

/// Parses the documented `/api/v1/auth/key` payload. Accepts both the
/// `{"data": {...}}` wrapper and a bare top-level object. Returns null
/// (unknown) on any shape drift — never renders `null` literals (E2).
ProviderQuota? parseOpenRouterKeyQuota(Object? body, {required DateTime now}) {
  if (body is! Map) return null;
  final data = body['data'] is Map ? body['data'] as Map : body;
  final rawUsage = data['usage'];
  final rawLimit = data['limit'];
  final usage = rawUsage is num ? rawUsage.toDouble() : null;
  final limit = rawLimit is num ? rawLimit.toDouble() : null;
  // Both keys present but null => an unlimited / uncapped key: a real,
  // valid answer rendering as `unlimited`. Keys absent or non-numeric =>
  // shape drift, degrade to unknown (E2). (`num?` already admits null —
  // no extra null clause.)
  final present = data.containsKey('usage') || data.containsKey('limit');
  final wellTyped = rawUsage is num? && rawLimit is num?;
  if (!present || !wellTyped) return null;
  return ProviderQuota(
    used: usage,
    limit: limit,
    unit: QuotaUnit.currencyUsd,
    updatedAt: now,
  );
}
