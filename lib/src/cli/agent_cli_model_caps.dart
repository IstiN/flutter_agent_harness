// The learned per-model message-cap surface (gh-1680), split out of
// `agent_cli.dart` to keep that file under the repo's 2800-line size
// gate. Same library (a `part of`), so the members stay library-private
// while every part file sees them.
part of 'agent_cli.dart';

extension _AgentCliModelCaps on AgentCli {
  /// gh-1680: the learned per-model message-cap store. Loaded lazily from
  /// `<homeDir>/.fah/model_caps.json` (a sibling of the per-provider
  /// `model_cache.json`); an in-memory empty store when the host has no
  /// home directory. The ONLY built-in knowledge anywhere in the repair
  /// path is the error-text classifier — no provider/model table lives in
  /// source.
  ModelCapsStore get _modelCaps => _modelCapsStore ??= _loadModelCaps();

  ModelCapsStore _loadModelCaps() {
    final home = config.homeDir;
    if (home == null || home.isEmpty) return ModelCapsStore();
    return ModelCapsStore.load('$home/.fah/model_caps.json');
  }

  /// The loop-facing policy wrapping [_modelCaps] with persistence on
  /// learn (see [_CliMessageCapPolicy]).
  MessageCapPolicy get _messageCapPolicy =>
      _messageCapPolicyInstance ??= _CliMessageCapPolicy(this);

  /// Persists the learned-cap store after a refusal was recorded (the
  /// next process boots with the cap — AC2). Best-effort.
  void _persistModelCaps() {
    final home = config.homeDir;
    if (home == null || home.isEmpty) return;
    _modelCaps.persist('$home/.fah/model_caps.json');
  }
}

/// gh-1680: the CLI's [MessageCapPolicy] — delegates to the learned store
/// and persists after every learned refusal, so the cap the provider
/// taught this process is boot-loaded by the next one (AC2). Kept out of
/// [AgentCli]'s fields so the store can stay lazily loaded.
final class _CliMessageCapPolicy implements MessageCapPolicy {
  _CliMessageCapPolicy(this._cli);

  final AgentCli _cli;
  @override
  int? learnedCapFor(Model model) => ModelCapsStore.learnedCapOr(
    _cli._modelCaps.recordFor(model.provider, model.id),
    _cli.config.modelsConfig?.overrides
        .lookup(model.provider, model.id)
        ?.messageCap,
  );

  @override
  void learnFromRefusal(Model model, MessageCapRefusal refusal) {
    _cli._modelCaps.learnFromRefusal(model, refusal);
    _cli._persistModelCaps();
  }
}
