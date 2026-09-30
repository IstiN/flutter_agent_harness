/// AC7 hiding-assertion helper (issue #1079): a capability that is `off` on
/// a profile is INVISIBLE — absent from tool schemas, prompt sections, and
/// every model/user-facing string. On a 🔀 profile only the available
/// transports surface.
///
/// Slice 1 asserts at the plan level and over real emitted text (CLI help).
/// Slice 2 plugs live schema/prompt emission into the same three helpers —
/// the assertions do not change, only the surface they run against.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Asserts [capability] is hidden in [plan]: a [HiddenCapability] entry with
/// a non-empty reason, zero surface tokens, and zero prompt sections.
void expectCapabilityHidden(HostWiringPlan plan, HostCapability capability) {
  final spec = hostCapabilityCatalog[capability]!;
  final entry = plan.planFor(capability);
  expect(
    entry,
    isA<HiddenCapability>(),
    reason: '${capability.id} must be hidden on "${plan.profile.name}"',
  );
  final reason = (entry as HiddenCapability).reason;
  expect(
    reason,
    isNotEmpty,
    reason:
        '${capability.id} hidden without a reason on '
        '"${plan.profile.name}" — off is never silent',
  );
  expect(
    plan.surfacedTokens.intersection(spec.surface.tokens),
    isEmpty,
    reason:
        '"${plan.profile.name}" hides ${capability.id} but surfaces its '
        'tokens ${spec.surface.tokens} — the hide-if-off invariant is broken',
  );
  expect(
    plan.promptSections.intersection(spec.surface.promptSectionIds),
    isEmpty,
    reason:
        '"${plan.profile.name}" hides ${capability.id} but still emits '
        'its prompt sections ${spec.surface.promptSectionIds}',
  );
  // No transport-qualified token of a hidden capability may leak either.
  for (final t in hostCapabilityTransports[capability]!.all) {
    expect(
      plan.surfacedTokens,
      isNot(contains('${capability.id}:$t')),
      reason:
          'hidden ${capability.id} leaks transport token '
          '${capability.id}:$t on "${plan.profile.name}"',
    );
  }
}

/// Positive control for [expectCapabilityHidden]: asserts [capability] is
/// wired in [plan] and surfaces, over exactly [transports] (null = the
/// capability has no transport dimension).
void expectCapabilitySurfaces(
  HostWiringPlan plan,
  HostCapability capability, {
  Set<String>? transports,
}) {
  final spec = hostCapabilityCatalog[capability]!;
  final entry = plan.planFor(capability);
  expect(
    entry,
    isA<WiredCapability>(),
    reason: '${capability.id} must be wired on "${plan.profile.name}"',
  );
  final wiredTransports = (entry as WiredCapability).transports;
  if (transports != null) {
    expect(
      wiredTransports,
      equals(transports),
      reason:
          '${capability.id} on "${plan.profile.name}" must surface '
          'exactly $transports (the 🔀 contract: only available transports)',
    );
    for (final t in hostCapabilityTransports[capability]!.all) {
      final qualified = '${capability.id}:$t';
      expect(
        plan.surfacedTokens.contains(qualified),
        transports.contains(t),
        reason:
            '${capability.id}:$t must '
            '${transports.contains(t) ? "surface" : "stay hidden"} on '
            '"${plan.profile.name}"',
      );
    }
  }
  expect(
    plan.surfacedTokens,
    containsAll(spec.surface.tokens),
    reason:
        '${capability.id} is wired on "${plan.profile.name}" but its '
        'tokens ${spec.surface.tokens} are missing from the surfaced set',
  );
}

/// String-level absence over a real emitted surface (schema text, prompt,
/// help): none of [surface]'s tokens or section ids may appear in [text].
///
/// Tokens match on identifier boundaries, not raw substrings — `jsr` must
/// not "leak" inside `jsr.ext`'s owner or a longer identifier (the catalog
/// vocabulary is full of near-collisions: `mcp`, `cube`, `task`, `lsp`).
/// A token counts as present only when it stands alone: preceded and
/// followed by a non-identifier character (or the text edge).
void expectTextFreeOf(
  String surfaceLabel,
  CapabilitySurface surface,
  String text,
) {
  for (final token in [...surface.tokens, ...surface.promptSectionIds]) {
    final pattern = RegExp(
      '(?:^|[^A-Za-z0-9_])${RegExp.escape(token)}(?:\$|[^A-Za-z0-9_])',
    );
    expect(
      pattern.hasMatch(text),
      isFalse,
      reason:
          '$surfaceLabel references "$token" — a hidden capability '
          'leaked into a model/user-facing string (AC7)',
    );
  }
}
