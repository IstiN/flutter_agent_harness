/// ProviderQuotaService (issue #823): in-memory TTL cache over per-provider
/// quota adapters.
///
/// Contract:
/// - Fake-clock-able via `now`; default TTL 15 min.
/// - `forceRefresh` bypasses the TTL; concurrent callers coalesce to one
///   in-flight fetch per provider (E6 — no endpoint hammering).
/// - NEVER on the chat hot path: `peek` is synchronous and cache-only;
///   on a cold/expired/reset-overdue entry it kicks a background refresh
///   and returns null so surfaces render `…` without blocking (E1). A
///   hanging fetch never blocks a stream (asserted by IT-3).
/// - Past-`resetsAt` entries auto-invalidate (E4); removed providers are
///   pruned via `retainOnly` (E5); 401/unknown results cache for the TTL
///   so an expired key causes ONE attempt per refresh, never a storm (E3).
/// - Cache is process-memory only; payloads and reasons are never logged
///   (secrets invariant).
library;

import 'dart:async';

import 'quota.dart';

class _CacheEntry {
  final QuotaFetchResult result;
  final DateTime fetchedAt;
  _CacheEntry(this.result, this.fetchedAt);
}

class ProviderQuotaService implements QuotaFeed {
  ProviderQuotaService({
    Map<String, QuotaAdapter> adapters = const {},
    Set<String> unmeteredProviders = const {},
    DateTime Function()? now,
    this.ttl = const Duration(minutes: 15),
    this.fetchTimeout = const Duration(seconds: 5),
  }) : _adapters = Map.of(adapters),
       _unmetered = Set.of(unmeteredProviders),
       _now = now ?? _defaultNow;

  static DateTime _defaultNow() => DateTime.now().toUtc();

  final Map<String, QuotaAdapter> _adapters;
  final Set<String> _unmetered;
  final DateTime Function() _now;
  final Duration ttl;

  /// Hard bound on every adapter fetch: a hung endpoint degrades to an
  /// `unknown (timeout)` entry instead of wedging /quota refresh,
  /// pull-to-refresh, or the background kick (review round 1).
  final Duration fetchTimeout;

  final Map<String, _CacheEntry> _cache = {};
  final Map<String, Future<QuotaFetchResult>> _inFlight = {};
  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Fires after every completed fetch or prune; UI surfaces listen to
  /// this instead of polling.
  Stream<void> get changes => _changes.stream;

  DateTime get _clockNow => _now().toUtc();

  /// Synchronous, cache-only read for render paths (badge, /quota, app).
  /// Returns null when the entry is cold/expired — a background refresh
  /// is kicked in that case and the surface renders `…`.
  QuotaFetchResult? peek(String providerId) {
    final now = _clockNow;
    if (_unmetered.contains(providerId)) {
      return QuotaFetchResult.ok(ProviderQuota.unmetered(updatedAt: now));
    }
    if (!_adapters.containsKey(providerId)) {
      return const QuotaFetchResult.unknown('no quota source');
    }
    final entry = _cache[providerId];
    final fresh =
        entry != null &&
        now.difference(entry.fetchedAt) < ttl &&
        !_isResetOverdue(entry, now);
    if (fresh) return entry.result;
    _cache.remove(providerId);
    _kick(providerId);
    return null;
  }

  /// Awaiting read: returns cached when fresh, else fetches (coalesced).
  Future<QuotaFetchResult> quotaFor(
    String providerId, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh) {
      final fresh = peek(providerId);
      if (fresh != null) return fresh;
      final inFlight = _inFlight[providerId];
      if (inFlight != null) return inFlight;
    }
    return refresh(providerId);
  }

  /// Forces one fetch, coalesced with any in-flight fetch (E3: exactly
  /// one attempt per refresh).
  Future<QuotaFetchResult> refresh(String providerId) {
    return _inFlight.putIfAbsent(providerId, () async {
      try {
        final result = await _fetchOnce(providerId);
        if (result != null) {
          _cache[providerId] = _CacheEntry(result, _clockNow);
          _changes.add(null);
        }
        return result ?? _noSource();
      } finally {
        _inFlight.remove(providerId);
      }
    });
  }

  @override
  bool isDepleted(String providerId) {
    final entry = _cache[providerId];
    if (entry == null) return false;
    final now = _clockNow;
    if (now.difference(entry.fetchedAt) >= ttl) return false;
    if (_isResetOverdue(entry, now)) return false;
    return entry.result.quota?.isDepleted ?? false;
  }

  /// Drops cache entries for providers no longer configured (E5).
  void retainOnly(Set<String> providerIds) {
    final before = _cache.length;
    _cache.removeWhere((id, _) => !providerIds.contains(id));
    if (_cache.length != before) _changes.add(null);
  }

  Future<QuotaFetchResult?> _fetchOnce(String providerId) async {
    final adapter = _adapters[providerId];
    if (adapter == null) return null;
    try {
      return await adapter.fetch().timeout(
        fetchTimeout,
        onTimeout: () => const QuotaFetchResult.unknown('timeout'),
      );
    } catch (_) {
      return const QuotaFetchResult.unknown('fetch failed');
    }
  }

  /// True when [providerId] has any quota surface at all — an adapter or
  /// a static unmetered marking. Badge render paths gate on this so
  /// adapter-less providers never show a stuck `[XX …]` badge.
  bool hasSource(String providerId) =>
      _unmetered.contains(providerId) || _adapters.containsKey(providerId);

  void _kick(String providerId) {
    unawaited(refresh(providerId).catchError((_) => _noSource()));
  }

  bool _isResetOverdue(_CacheEntry entry, DateTime now) =>
      entry.result.quota?.isResetOverdue(now) ?? false;

  QuotaFetchResult _noSource() =>
      const QuotaFetchResult.unknown('no quota source');
}
