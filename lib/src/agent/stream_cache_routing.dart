// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Per-call prompt-cache routing and request shape for the provider
/// stream functions (gh-2101, GOAL #2394) — the values the
/// `StreamFunction` contract has no slot for, carried in a zone. Lives
/// beside the agent loop, which re-exports it.
library;

import 'dart:async';

/// Per-call prompt-cache routing overrides, consulted by the provider
/// stream functions built with `providerStreamFunction`.
///
/// The `StreamFunction` contract has no options slot, so per-call routing
/// (pi's `sessionId`/`cacheRetention` stream options) travels in a zone:
/// [StreamCacheRouting.runWith] installs values for every provider call
/// started inside its body — including async work such as fallback-chain
/// attempts, which run in the zone they were created in. Adapters read
/// [StreamCacheRouting.current] when a call starts; a `null` field keeps
/// the call's own defaults.
///
/// Since gh-2101 the values come from the run's `CompactionCachePolicy`
/// (lib/src/compaction/cache_policy.dart): one run-scoped routing id with
/// `short` retention, never the session's id; cache-less providers ignore
/// it. Since GOAL #2394 the session-affine hand-over call installs an
/// all-null record instead (`CompactionCachePolicy.sessionAffine`): every
/// field falls through to the values the session's own main requests
/// resolve (the resolver's bound id, the factory defaults) — the same
/// cache bucket, never a literal — and `hasExplicitRouting` tells the
/// resolver's binding whether to yield.
final class StreamCacheRouting {
  StreamCacheRouting._();

  static final Object _zoneKey = Object();
  static final Object _shapeKey = Object();

  /// The routing values active in the current zone, or `null` when no
  /// override is in effect (calls then use their built-in defaults).
  static ({String? sessionId, String? cacheRetention})? get current {
    final value = Zone.current[_zoneKey];
    return value is ({String? sessionId, String? cacheRetention})
        ? value
        : null;
  }

  /// Whether the active override names a routing value — the resolver's
  /// bound session id yields only to an EXPLICIT override (gh-2101 affine
  /// ids); an all-null record (the #2394 session-affine fallthrough) is
  /// no opinion and the resolver's binding stands, exactly as for the
  /// session's main requests.
  static bool get hasExplicitRouting {
    final routing = current;
    return routing != null &&
        (routing.sessionId != null || routing.cacheRetention != null);
  }

  /// The request-shape overrides active in the current zone (GOAL #2394
  /// hand-over call), or `null` when the call rides the adapter defaults.
  static StreamCallShape? get callShape {
    final value = Zone.current[_shapeKey];
    return value is StreamCallShape ? value : null;
  }

  /// Runs [body] with [sessionId]/[cacheRetention] overriding the cache
  /// routing of provider calls started inside it. An override is explicit:
  /// code that binds default routing values (the model-roles resolver)
  /// yields to an active override instead of replacing it. The optional
  /// [shape] installs the call's request shape (tool choice, output
  /// budget, history breakpoint, pinned Copilot initiator) the catalog
  /// builders thread into the adapter options.
  static T runWith<T>(
    T Function() body, {
    String? sessionId,
    String? cacheRetention,
    StreamCallShape? shape,
  }) {
    return runZoned(
      body,
      zoneValues: {
        _zoneKey: (sessionId: sessionId, cacheRetention: cacheRetention),
        _shapeKey: ?shape,
      },
    );
  }
}

/// The request shape of one provider call that the `StreamFunction`
/// contract has no slot for (GOAL #2394): the compaction hand-over call
/// sets all four; ordinary calls carry none of them.
final class StreamCallShape {
  /// Creates the shape; every field `null` keeps the adapter default.
  const StreamCallShape({
    this.toolChoice,
    this.maxTokens,
    this.prefixLength,
    this.copilotInitiator,
  });

  /// `tool_choice` for adapters that support it (`'none'` on the
  /// hand-over call — the reply must be text, never tool calls).
  final String? toolChoice;

  /// The explicit output-token budget (`compaction.handOver.maxTokens`).
  final int? maxTokens;

  /// The number of leading messages that form the cached history prefix —
  /// the breakpoint position adapters with explicit breakpoints place the
  /// history cache_control on (S0's last message, not the instruction).
  final int? prefixLength;

  /// The pinned Copilot `x-initiator` (`agent`/`user`) — the value S0 rode.
  final String? copilotInitiator;
}
