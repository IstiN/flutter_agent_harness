/// Tool approval: capability tiers, per-tool policy, and session modes.
///
/// Shaped after oh-my-pi's approval model (`packages/coding-agent/src/tools/
/// approval.ts` + `docs/approval-mode.md`), reduced to a static per-tool
/// [ApprovalTier] plus a critical-pattern interceptor for `bash`
/// (`bash_interceptor.dart`). The check runs inside the agent loop's
/// `beforeToolCall` phase (see `approval_hook.dart`), so a denied call never
/// executes: it becomes an error tool result the model can react to.
///
/// Policy model:
///
/// - Every tool has an [ApprovalTier]: [ApprovalTier.read] (reads data),
///   [ApprovalTier.write] (mutates workspace state), [ApprovalTier.exec]
///   (runs code / shells out). Tools that do not declare a tier — custom and
///   plugin tools — default to [ApprovalTier.exec], the safe choice.
/// - The session runs in one [ApprovalMode]:
///   [ApprovalMode.alwaysAsk] prompts for every call, [ApprovalMode.write]
///   auto-allows read-tier and prompts for write/exec, [ApprovalMode.yolo]
///   auto-allows everything.
/// - Per-tool [ApprovalPolicy] overrides (`allow`/`deny`/`prompt`) and the
///   session always-allow set (filled by "approve always" decisions) take
///   precedence over the mode.
/// - Deliberate deviation from omp: a `bash` command matching a critical
///   pattern forces a prompt regardless of mode or allow-policy (omp
///   auto-approves those in yolo). Only an explicit per-tool `deny` outranks
///   the interceptor.
library;

import 'dart:async';

import 'bash_interceptor.dart';

/// How much damage a tool call can do, worst case.
enum ApprovalTier {
  /// Reads data without mutating workspace state (`read`, `ls`).
  read,

  /// Mutates workspace/session state without executing arbitrary code
  /// (`write`, `edit`).
  write,

  /// Executes code, shells out, or performs similarly broad actions
  /// (`bash`). Default for tools that do not declare a tier.
  exec,
}

/// The resolved policy for one tool call.
enum ApprovalPolicy {
  /// Execute without asking.
  allow,

  /// Refuse execution; the model receives an error tool result.
  deny,

  /// Ask the user (via the [ApprovalPrompt] callback) before executing.
  prompt,
}

/// Session-wide approval posture.
enum ApprovalMode {
  /// Prompt for every tool call, read-tier included.
  alwaysAsk,

  /// Auto-allow read-tier calls; prompt for write- and exec-tier calls.
  write,

  /// Auto-allow every call (critical `bash` patterns still prompt).
  yolo,
}

/// The user's answer to an approval prompt.
enum ApprovalDecision {
  /// Execute this one call; ask again next time.
  approveOnce,

  /// Execute this call and auto-allow the tool for the rest of the session
  /// (critical `bash` patterns still prompt).
  approveAlways,

  /// Refuse execution; the model receives an error tool result.
  deny,
}

/// One approval prompt, handed to the [ApprovalPrompt] callback.
final class ApprovalRequest {
  const ApprovalRequest({
    required this.toolName,
    required this.tier,
    required this.arguments,
    required this.reason,
  });

  /// Name of the tool about to run.
  final String toolName;

  /// The tool's capability tier.
  final ApprovalTier tier;

  /// The raw (not yet schema-validated) tool call arguments.
  final Map<String, dynamic> arguments;

  /// Why approval is required (mode, per-tool prompt policy, or the critical
  /// pattern that matched).
  final String reason;
}

/// Renders an approval prompt and resolves with the user's [ApprovalDecision].
///
/// Surfaces (CLI, Flutter, web) inject their own UI through this callback.
typedef ApprovalPrompt =
    FutureOr<ApprovalDecision> Function(ApprovalRequest request);

/// The outcome of an [ApprovalManager.authorize] check.
final class ApprovalOutcome {
  const ApprovalOutcome._(this.allowed, this.reason);

  /// The call may execute.
  const ApprovalOutcome.allowed() : this._(true, null);

  /// The call is refused; [reason] goes into the error tool result.
  const ApprovalOutcome.denied(String reason) : this._(false, reason);

  /// Whether the tool call may execute.
  final bool allowed;

  /// Denial reason shown to the model (and user); `null` when allowed.
  final String? reason;
}

/// Holds the approval state of a session and resolves policy per tool call.
///
/// Resolution order (see the library doc for the model):
///
/// 1. An explicit per-tool `deny` override refuses the call.
/// 2. A critical `bash` pattern forces a prompt (even under yolo).
/// 3. A per-tool `allow`/`prompt` override applies.
/// 4. The session always-allow set (from "approve always" answers) applies.
/// 5. The session [mode] compares against the tool's tier.
///
/// When resolution lands on [ApprovalPolicy.prompt] and no [prompt] callback
/// is installed, the call is DENIED with a "no approval UI" reason — the
/// safe default for headless/non-interactive runs.
final class ApprovalManager {
  /// Creates a manager. [overrides] and [alwaysAllow] seed the per-tool
  /// policy map and the session always-allow set (both are copied).
  ApprovalManager({
    this.mode = ApprovalMode.yolo,
    Map<String, ApprovalPolicy> overrides = const {},
    Set<String> alwaysAllow = const {},
    this.prompt,
  }) : _overrides = Map.of(overrides),
       _alwaysAllow = Set.of(alwaysAllow);

  /// The active session mode. Mutable at runtime (`/approval`, settings UI).
  ApprovalMode mode;

  /// The prompt surface. When `null`, any call resolving to
  /// [ApprovalPolicy.prompt] is denied (safe default).
  ApprovalPrompt? prompt;

  final Map<String, ApprovalPolicy> _overrides;
  final Set<String> _alwaysAllow;

  /// Names in the session always-allow set, sorted.
  List<String> get alwaysAllowedTools =>
      List.unmodifiable(_alwaysAllow.toList()..sort());

  /// The per-tool override for [toolName], or `null` when unset.
  ApprovalPolicy? overrideFor(String toolName) => _overrides[toolName];

  /// Sets (or replaces) the per-tool override for [toolName].
  void setOverride(String toolName, ApprovalPolicy policy) {
    _overrides[toolName] = policy;
  }

  /// Removes the per-tool override for [toolName].
  void clearOverride(String toolName) {
    _overrides.remove(toolName);
  }

  /// Adds [toolName] to the session always-allow set.
  void allowAlways(String toolName) {
    _alwaysAllow.add(toolName);
  }

  /// Whether [toolName] is in the session always-allow set.
  bool isAlwaysAllowed(String toolName) => _alwaysAllow.contains(toolName);

  /// Resolves the policy for one tool call and, when it lands on
  /// [ApprovalPolicy.prompt], awaits the user's decision via [prompt].
  Future<ApprovalOutcome> authorize({
    required String toolName,
    required ApprovalTier tier,
    required Map<String, dynamic> arguments,
  }) async {
    // 1. An explicit deny wins over everything, the interceptor included.
    if (_overrides[toolName] == ApprovalPolicy.deny) {
      return ApprovalOutcome.denied(
        'Tool "$toolName" is denied by the configured approval policy.',
      );
    }

    // 2. Critical bash patterns force a prompt regardless of mode or
    //    allow-policy — even under yolo and after "approve always".
    if (toolName == bashToolName) {
      final command = arguments['command'];
      final label = command is String
          ? matchCriticalBashCommand(command)
          : null;
      if (label != null) {
        return _requestDecision(
          toolName: toolName,
          tier: tier,
          arguments: arguments,
          reason: 'Critical pattern detected: $label',
        );
      }
    }

    // 3. Remaining per-tool overrides.
    switch (_overrides[toolName]) {
      case ApprovalPolicy.allow:
        return const ApprovalOutcome.allowed();
      case ApprovalPolicy.prompt:
        return _requestDecision(
          toolName: toolName,
          tier: tier,
          arguments: arguments,
          reason: 'Tool "$toolName" is set to always ask for approval',
        );
      case ApprovalPolicy.deny || null:
        break; // deny was handled first; nothing overrides here.
    }

    // 4. Session always-allow ("approve always" answers, `/allow`).
    if (_alwaysAllow.contains(toolName)) {
      return const ApprovalOutcome.allowed();
    }

    // 5. Session mode vs. tool tier.
    switch (mode) {
      case ApprovalMode.yolo:
        return const ApprovalOutcome.allowed();
      case ApprovalMode.write:
        if (tier == ApprovalTier.read) return const ApprovalOutcome.allowed();
        return _requestDecision(
          toolName: toolName,
          tier: tier,
          arguments: arguments,
          reason: 'Mode "write" requires approval for ${tier.name}-tier tools',
        );
      case ApprovalMode.alwaysAsk:
        return _requestDecision(
          toolName: toolName,
          tier: tier,
          arguments: arguments,
          reason: 'Mode "always-ask" requires approval for every tool call',
        );
    }
  }

  Future<ApprovalOutcome> _requestDecision({
    required String toolName,
    required ApprovalTier tier,
    required Map<String, dynamic> arguments,
    required String reason,
  }) async {
    final callback = prompt;
    if (callback == null) {
      return ApprovalOutcome.denied(
        'Tool "$toolName" requires approval ($reason), but no approval UI is '
        'available. The call was denied.',
      );
    }
    final decision = await callback(
      ApprovalRequest(
        toolName: toolName,
        tier: tier,
        arguments: arguments,
        reason: reason,
      ),
    );
    switch (decision) {
      case ApprovalDecision.approveOnce:
        return const ApprovalOutcome.allowed();
      case ApprovalDecision.approveAlways:
        _alwaysAllow.add(toolName);
        return const ApprovalOutcome.allowed();
      case ApprovalDecision.deny:
        return ApprovalOutcome.denied(
          'The user denied the "$toolName" tool call.',
        );
    }
  }
}

/// The CLI/config spelling of an [ApprovalMode] (`always-ask`, `write`,
/// `yolo`).
extension ApprovalModeLabel on ApprovalMode {
  /// The stable lowercase label used in config files and slash commands.
  String get label => switch (this) {
    ApprovalMode.alwaysAsk => 'always-ask',
    ApprovalMode.write => 'write',
    ApprovalMode.yolo => 'yolo',
  };
}

/// Parses a CLI/config label into an [ApprovalMode]; `null` when unknown.
ApprovalMode? approvalModeFromLabel(String? value) {
  return switch (value?.trim()) {
    'always-ask' || 'alwaysAsk' => ApprovalMode.alwaysAsk,
    'write' => ApprovalMode.write,
    'yolo' => ApprovalMode.yolo,
    _ => null,
  };
}
