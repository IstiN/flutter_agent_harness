/// The agents-hub projection (issue #277): the LIVE agent fleet — main plus
/// every retained subagent — as a status-ordered tree with per-agent metrics.
///
/// Ported (reduced) from oh-my-pi
/// `packages/coding-agent/src/modes/components/agent-hub-projection.ts`:
/// tree from parent links (orphans surface top-level), STATUS_ORDER sorting
/// (running > waiting > queued > terminal), footer aggregation, collapse,
/// stale-agent eviction, and the observer-measured active duration (running
/// spans accumulated by this projection — the wall time is just
/// `lastActivity - startedAt`, the ACTIVE time is what the observer saw).
///
/// Pure Dart: the host (the CLI hub driver) feeds [HubAgent] snapshots from
/// the existing subagent events and renders [rows]/[footer]; no IO, no
/// timers, clock injectable for tests.
library;

import '../trajectory/formatters.dart' show formatTokens;

/// The hub lifecycle states, coarse enough for one icon per row.
///
/// `waiting` folds our `idle` subagents (waiting-for-input) and parked
/// agents; `queued` is a spawn not yet running.
enum HubStatus { running, waiting, queued, done, failed, aborted }

/// STATUS_ORDER (omp semantics): running first, terminals last.
const Map<HubStatus, int> hubStatusRank = {
  HubStatus.running: 0,
  HubStatus.waiting: 1,
  HubStatus.queued: 2,
  HubStatus.done: 3,
  HubStatus.failed: 4,
  HubStatus.aborted: 5,
};

/// One icon per hub status (the tree rows).
String hubStatusIcon(HubStatus status) => switch (status) {
  HubStatus.running => '🔄',
  HubStatus.waiting => '✋',
  HubStatus.queued => '⏳',
  HubStatus.done => '✅',
  HubStatus.failed => '❌',
  HubStatus.aborted => '🛑',
};

/// One agent row of the hub fleet: the identity plus its live metrics.
/// Nullable metrics are unknown-live (they arrive with events when known)
/// and render as `—` / stay out of the aggregates.
final class HubAgent {
  const HubAgent({
    required this.id,
    required this.name,
    required this.agentType,
    required this.status,
    required this.startedAt,
    required this.lastActivity,
    this.parentId,
    this.isMain = false,
    this.tokens,
    this.requests,
    this.toolCalls,
    this.costUsd,
    this.contextTokens,
    this.contextWindow,
  });

  /// Unique id (`main` for the orchestrator, the agent:// id for children).
  final String id;

  /// Display name.
  final String name;

  /// The agent type (`task`/`explore`/… or `orchestrator` for main).
  final String agentType;

  /// Parent agent id; `null` = top-level. A parent that is itself unknown
  /// surfaces the child top-level (orphan rule).
  final String? parentId;

  /// True for the orchestrator row (always sorted before every other root).
  final bool isMain;

  final HubStatus status;

  /// When this agent started (wall-clock anchor).
  final DateTime startedAt;

  /// Last observed activity (drives stale eviction + recency ties).
  final DateTime lastActivity;

  /// Total tokens (input + output + cache writes).
  final int? tokens;

  /// Model requests made.
  final int? requests;

  /// Tool calls executed.
  final int? toolCalls;

  /// Accrued cost in USD, when the host knows it.
  final double? costUsd;

  /// Context usage: tokens in the window out of [contextWindow].
  final int? contextTokens;
  final int? contextWindow;

  /// Context usage as a percent (0-100), null when unknown.
  double? get contextPercent {
    final used = contextTokens;
    final window = contextWindow;
    if (used == null || window == null || window <= 0) return null;
    return (used / window * 100).clamp(0, 999);
  }

  /// Wall time from start to last activity.
  Duration get wallTime => lastActivity.difference(startedAt);
}

/// One ordered row of the tree: the agent plus its nesting depth.
final class HubRow {
  const HubRow({required this.agent, required this.depth});
  final HubAgent agent;
  final int depth;
}

/// The footer aggregates over the WHOLE fleet — including agents hidden by
/// collapse or scrolled out of the viewport (E1: the aggregates stay exact).
final class HubFooter {
  const HubFooter({
    required this.tokens,
    required this.cost,
    required this.running,
    required this.agents,
  });

  /// Σ tokens over the agents that reported any.
  final int tokens;

  /// Σ cost over the agents that reported any.
  final double cost;

  /// How many agents are [HubStatus.running].
  final int running;

  /// Total fleet size.
  final int agents;
}

/// Status-then-recency-then-id sibling ordering (deterministic).
int _hubOrder(HubAgent a, HubAgent b) {
  final byRank = hubStatusRank[a.status]!.compareTo(hubStatusRank[b.status]!);
  if (byRank != 0) return byRank;
  final byRecency = b.lastActivity.compareTo(a.lastActivity);
  if (byRecency != 0) return byRecency;
  return a.id.compareTo(b.id);
}

/// The live fleet tree. See the library doc.
final class AgentHubProjection {
  AgentHubProjection({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  final _agents = <String, HubAgent>{};

  /// Running-span observer state: when the current running span began, and
  /// the accumulated active time across every completed span.
  final _runningSince = <String, DateTime>{};
  final _active = <String, Duration>{};

  /// Collapsed parent ids: their descendants are hidden from [rows] while
  /// the footer still counts them (E1).
  final collapsed = <String>{};

  /// The fleet, in registration order.
  List<HubAgent> get agents => List.unmodifiable(_agents.values);

  HubAgent? operator [](String id) => _agents[id];

  /// Observer-measured active time for [id]: accumulated running spans
  /// (plus the in-flight span when currently running).
  Duration activeDuration(String id) {
    var total = _active[id] ?? Duration.zero;
    final since = _runningSince[id];
    if (since != null) total += _now().difference(since);
    return total;
  }

  /// Inserts or replaces [agent], tracking the running-span transitions.
  void upsert(HubAgent agent) {
    final now = _now();
    final prev = _agents[agent.id];
    final wasRunning = prev != null && prev.status == HubStatus.running;
    final isRunning = agent.status == HubStatus.running;
    // Keep the observer's accumulated numbers authoritative for identity
    // fields the host snapshot may not re-report.
    if (prev != null && !agent.isMain) {
      agent = HubAgent(
        id: agent.id,
        name: agent.name,
        agentType: agent.agentType,
        status: agent.status,
        startedAt: agent.startedAt,
        lastActivity: agent.lastActivity,
        parentId: agent.parentId,
        isMain: agent.isMain,
        tokens: agent.tokens ?? prev.tokens,
        requests: agent.requests ?? prev.requests,
        toolCalls: agent.toolCalls ?? prev.toolCalls,
        costUsd: agent.costUsd ?? prev.costUsd,
        contextTokens: agent.contextTokens ?? prev.contextTokens,
        contextWindow: agent.contextWindow ?? prev.contextWindow,
      );
    }
    if (isRunning && !wasRunning) {
      _runningSince[agent.id] = now;
    } else if (!isRunning && wasRunning) {
      _active[agent.id] = activeDuration(agent.id);
      _runningSince.remove(agent.id);
    }
    _agents[agent.id] = agent;
  }

  /// Drops [id] (finalizing a running span first).
  void remove(String id) {
    if (_agents[id]?.status == HubStatus.running) {
      _active[id] = activeDuration(id);
      _runningSince.remove(id);
    }
    _agents.remove(id);
    _runningSince.remove(id);
    _active.remove(id);
    collapsed.remove(id);
  }

  /// Evicts every non-running agent idle for longer than [maxIdle] since
  /// its last activity. Returns the evicted ids.
  List<String> evictStale({Duration maxIdle = const Duration(hours: 1)}) {
    final now = _now();
    final evicted = [
      for (final agent in _agents.values)
        if (agent.status != HubStatus.running &&
            now.difference(agent.lastActivity) > maxIdle)
          agent.id,
    ];
    for (final id in evicted) {
      remove(id);
    }
    return evicted;
  }

  /// Collapses/expands [id] (a no-op for unknown ids).
  void toggleCollapsed(String id) {
    if (!collapsed.remove(id)) collapsed.add(id);
  }

  /// The ordered tree rows: main first, children indented under their
  /// parent, orphans top-level, siblings status-ordered, collapsed
  /// branches hidden.
  List<HubRow> rows() {
    final children = <String, List<HubAgent>>{};
    final roots = <HubAgent>[];
    for (final agent in _agents.values) {
      final parent = agent.parentId;
      final parentKnown = parent != null && _agents.containsKey(parent);
      if (parent == null || !parentKnown) {
        roots.add(agent);
      } else {
        children.putIfAbsent(parent, () => []).add(agent);
      }
    }
    // The orchestrator row always leads; the rest follow hub order.
    roots.sort((a, b) {
      if (a.isMain != b.isMain) return a.isMain ? -1 : 1;
      return _hubOrder(a, b);
    });
    for (final list in children.values) {
      list.sort(_hubOrder);
    }
    final rows = <HubRow>[];
    void walk(HubAgent agent, int depth) {
      rows.add(HubRow(agent: agent, depth: depth));
      if (collapsed.contains(agent.id)) return;
      for (final child in children[agent.id] ?? const <HubAgent>[]) {
        walk(child, depth + 1);
      }
    }

    for (final root in roots) {
      walk(root, 0);
    }
    return rows;
  }

  /// The footer aggregates over the whole fleet (E1-exact).
  HubFooter footer() {
    var tokens = 0;
    var cost = 0.0;
    var running = 0;
    for (final agent in _agents.values) {
      tokens += agent.tokens ?? 0;
      cost += agent.costUsd ?? 0;
      if (agent.status == HubStatus.running) running++;
    }
    return HubFooter(
      tokens: tokens,
      cost: cost,
      running: running,
      agents: _agents.length,
    );
  }

  /// Compact token label for the rows/footer (`12`, `12.3k`, `1.2M`).
  String formatHubTokens(int? tokens) => formatTokens(tokens);
}
