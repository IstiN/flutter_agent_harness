/// Chain-gate members of [AgentCli] (issue #2226): the smart wake gate's
/// construction and its persisted chain state (budget spend + loop
/// windows). Same library as agent_cli.dart, so private members resolve.
part of 'agent_cli.dart';

extension AgentCliChainGate on AgentCli {
  /// Builds the policy + its persistence. `late final` field initializer
  /// in the class body calls this, so `config` and the late
  /// [_messagesRoot] are safe: the store's path closure dereferences the
  /// root only at load/save time (both post-wiring), so a fabric-less
  /// session can still reset the streak. Absent `messaging:` section =
  /// the defaults, not a bypass.
  InboxWakePolicy _buildInboxWakePolicy() {
    final messaging = config.messaging ?? const MessagingConfig();
    final store = ChainStateStore(
      env: _env,
      path: () => '$_messagesRoot/_chain/state.json',
      onError: _logDiagnostic,
    );
    final guard = ChainLoopGuard(
      similarityThreshold: messaging.loopDetection.similarityThreshold,
      stuckRounds: messaging.loopDetection.stuckRounds,
      budgetTokens: messaging.chainBudgetTokens,
      enabled: messaging.loopDetection.enabled,
    );
    _chainState = (store, guard);
    return InboxWakePolicy.forConfig(messaging, guard);
  }

  /// Kicks the one-shot chain-state restore; called after the fabric
  /// wiring names [_messagesRoot].
  void _startChainStateRestore() {
    final chain = _chainState;
    if (chain == null) return;
    _chainStateRestored = chain.$1.load().then((snapshot) {
      if (snapshot != null) chain.$2.restore(snapshot);
    });
  }

  /// Persists the chain state after a spend/pause/reset (best-effort).
  Future<void> _persistChainState() async {
    final chain = _chainState;
    if (chain == null) return;
    await chain.$1.save(chain.$2.snapshot());
  }
}
