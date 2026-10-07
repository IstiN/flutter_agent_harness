/// The declared host-extension surface (issue #1079 component 4 —
/// `HostExtensionApi`): the sanctioned way a host adds what the SDK does
/// not have — its own tools — THROUGH the builder, with the capability
/// matrix declared at birth.
///
/// A [HostExtension] is a named registrant's contribution: the tools it
/// contributes plus an explicit state for every profile the host can
/// wire. The builder (lib/src/hosts/host_agent_wiring.dart) enforces the
/// three extension invariants:
///
/// - **E6 — declared at birth**: every built-in profile MUST have an
///   explicit state (`on` / `off(reason)`); there is no implicit default.
///   A state for a custom profile is optional at construction but
///   required at wire time for any profile the host actually wires.
/// - **E7 — collisions rejected at build time**: an extension tool id
///   colliding with the SDK core, the gated task surface, or another
///   extension throws [HostWiringException] naming both registrants. (A
///   tool id colliding with a CORE tool would silently override SDK
///   behavior — the one thing this API must never do — so the loud check
///   lives in the builder, not the replace-and-note [ToolRegistry], whose
///   leniency is the child-pool contract, issue #862.)
/// - **E8 — off means hidden with a reason**: on a profile whose state is
///   `off`, the extension's tools never reach the registry and the off
///   reason surfaces through [WiredAgentCore.extensions] for the host's
///   UI — the hide-if-off invariant, extension edition.
///
/// **Additive-only (AC9/UT-5):** the type carries tools and declarations,
/// nothing else — there is no member that could override a core behavior
/// (memory, context management, compaction, the JSONL tool session,
/// trajectory are SDK invariants). The only route to "replace" a core
/// tool is a colliding id, and E7 rejects it at build time.
///
/// Pure Dart: no `dart:io`.
library;

import '../agent/agent_tool.dart';
import 'host_capability_profile.dart';
import 'host_wiring_builder.dart' show builtInProfiles;

/// A host's declared extension: named tools + an explicit per-profile
/// matrix state (E6).
final class HostExtension {
  /// Registrant id — E7 collision reports name both sides; keep it the
  /// thing a host user would recognize (`cli-plugins`, `yoclip`).
  final String name;

  /// The tools contributed on profiles where the extension is `on`.
  final List<AgentTool> tools;

  /// The matrix declaration: profile name → state. Every built-in profile
  /// (the keys of `builtInProfiles`) MUST be present — E6, no implicit
  /// default. Extra keys are custom profiles; they are validated at wire
  /// time (a state must exist for whatever the host actually wires).
  final Map<String, CapabilityState> profileStates;

  /// Validates and builds. Throws [HostProfileViolation] on an E6 gap
  /// (missing built-in profile, blank reason, a transport state — tool
  /// extensions have no transport dimension), an empty name, or an
  /// empty/duplicate tool id.
  HostExtension({
    required this.name,
    List<AgentTool> tools = const [],
    required Map<String, CapabilityState> profileStates,
  }) : tools = List.unmodifiable(tools),
       profileStates = Map.unmodifiable(profileStates) {
    if (name.trim().isEmpty) {
      throw const HostProfileViolation(
        'HostExtension name must not be blank (E7 names registrants — '
        'they need a real id).',
      );
    }
    final missing = builtInProfiles.keys
        .where((profile) => !profileStates.containsKey(profile))
        .toList();
    if (missing.isNotEmpty) {
      throw HostProfileViolation(
        'HostExtension "$name" declares no state for built-in profile(s) '
        '${missing.map((m) => '"$m"').join(', ')} — declare every built-in '
        'profile explicitly (E6: there is no implicit default).',
      );
    }
    for (final entry in profileStates.entries) {
      if (entry.value is CapabilityTransportState) {
        throw HostProfileViolation(
          'HostExtension "$name" declares a transport state for profile '
          '"${entry.key}" — tool extensions have no transport dimension; '
          'declare on or off(reason).',
        );
      }
      if (entry.value.reason case final reason? when reason.trim().isEmpty) {
        throw HostProfileViolation(
          'HostExtension "$name" is off on "${entry.key}" without a reason '
          '— off is never silent (E8).',
        );
      }
    }
    final seen = <String>{};
    for (final tool in tools) {
      if (tool.name.trim().isEmpty) {
        throw HostProfileViolation(
          'HostExtension "$name" contributes a tool with a blank id.',
        );
      }
      if (!seen.add(tool.name)) {
        throw HostProfileViolation(
          'HostExtension "$name" contributes "${tool.name}" twice — the '
          'builder rejects duplicate ids at build time (E7).',
        );
      }
    }
  }

  /// The declared state for [profileName], or null when the profile is a
  /// custom one this extension does not declare (validated at wire time).
  CapabilityState? stateFor(String profileName) => profileStates[profileName];
}

/// The builder's per-extension wiring outcome: the tools that reached the
/// stack, or the off reason (E8) for the host's UI.
final class WiredHostExtension {
  /// The declared extension this outcome belongs to.
  final HostExtension extension;

  /// The tools wired on this profile; empty when hidden.
  final List<AgentTool> tools;

  /// Non-null when the extension is hidden on this profile (E8): the
  /// profile's declared off reason, never empty.
  final String? hiddenReason;

  /// True when the extension is hidden on this profile.
  bool get isHidden => hiddenReason != null;

  const WiredHostExtension({
    required this.extension,
    required this.tools,
    this.hiddenReason,
  });
}
