/// CodeMie quota adapter (issue #823) — ships DARK.
///
/// OQ1 lean (b): the exact quota/profile endpoint is NOT pinned yet
/// (`codemie_sso.dart` only knows the `/code-assistant-api` chat paths),
/// so the adapter contract ships endpoint-agnostic and reports `unknown`
/// until the gateway pin lands. Wiring a confirmed endpoint is a
/// one-line change: pass `limitsEndpoint` + a fixture-first parse.
///
/// The provisional parse below follows the pinned GOAL shape (currencyUsd
/// + resetsAt); `// ponytail:` single place to swap when confirmed.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'quota.dart';

class CodeMieQuotaAdapter implements QuotaAdapter, QuotaAwareProvider {
  CodeMieQuotaAdapter({
    required this.client,
    required this.resolveSessionCookie,
    DateTime Function()? now,
    this.limitsEndpoint,
  }) : now = now ?? _defaultNow;

  /// Null (default) => dark: no request is ever made, reason says why.
  final Uri? limitsEndpoint;

  final http.Client client;
  final Future<String?> Function() resolveSessionCookie;
  final DateTime Function() now;

  static DateTime _defaultNow() => DateTime.now().toUtc();

  @override
  Future<QuotaFetchResult> fetch() async {
    final endpoint = limitsEndpoint;
    if (endpoint == null) {
      return const QuotaFetchResult.unknown(
        'endpoint not pinned (OQ1) — dark until confirmed',
      );
    }
    final cookie = await resolveSessionCookie();
    if (cookie == null || cookie.isEmpty) {
      return const QuotaFetchResult.unknown('no session');
    }
    final http.Response response;
    try {
      response = await client.get(
        endpoint,
        headers: {'Cookie': cookie, 'Accept': 'application/json'},
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
    final quota = parseCodeMieQuota(body, now: now());
    if (quota == null) {
      return const QuotaFetchResult.unknown('invalid response: unexpected shape');
    }
    return QuotaFetchResult.ok(quota);
  }

  @override
  Future<ProviderQuota?> fetchQuota({bool forceRefresh = false}) async =>
      (await fetch()).quota;
}

/// Provisional parse for the pinned GOAL shape: `usage` / `limit` in USD
/// plus an ISO `resetsAt`. Absent/garbage fields degrade to unknown (E2).
/// ponytail: swap this single function when OQ1 pins the real payload.
ProviderQuota? parseCodeMieQuota(Object? body, {required DateTime now}) {
  if (body is! Map) return null;
  final usage = body['usage'] is num ? (body['usage'] as num).toDouble() : null;
  final limit = body['limit'] is num ? (body['limit'] as num).toDouble() : null;
  final resetsAt = body['resetsAt'] is String
      ? DateTime.tryParse(body['resetsAt'] as String)
      : null;
  if (usage == null && limit == null && resetsAt == null) return null;
  return ProviderQuota(
    used: usage,
    limit: limit,
    unit: QuotaUnit.currencyUsd,
    resetsAt: resetsAt,
    updatedAt: now,
  );
}
