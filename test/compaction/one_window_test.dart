@TestOn('vm')
library;

/// gh-2492 C6 — the ONE-window catalog/consistency check.
///
/// The #2423 invariant 2 (gh-1742): ONE window per model identity,
/// everywhere. On every host, the SAME resolved value must drive:
/// - the compaction trigger (thresholds scaled from the wiring),
/// - the loop's over-window guard,
/// - BOTH context notices (post-hide, near-limit),
/// - the ctx meter / status line.
///
/// This REG test proves the four consumers agree — for a CATALOG-ONLY
/// identity (the carried window, unverified) and for a REGISTRY-PINNED
/// one (an endpoint detection published mid-session; E4 shrink
/// included). Every consumer funnels the shared seams
/// ([resolveCompactionHostWiring] / [effectiveContextWindow] /
/// [withRegisteredContextWindow]) — a divergence here is a regression.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

Model _model({required int window}) => Model(
  id: 'claude-sonnet-5-5',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test/v1',
  contextWindow: window,
  maxTokens: 4096,
);

/// The four consumer resolutions over one basis.
({int trigger, int guard, int postHide, int nearLimit, int meter}) _consumers({
  required Model model,
  required int? contextWindowCap,
  required int tokens,
}) {
  final wiring = resolveCompactionHostWiring(
    mainModel: model,
    contextWindowCap: contextWindowCap,
  );
  final window = wiring.window;
  // The guard: the loop resolves effectiveContextWindow(model, cap).
  final guard = effectiveContextWindow(model.contextWindow, contextWindowCap);
  // The notices: both take the SAME window the wiring resolved.
  final postHide = postHideNoticeLine(
    hiddenRecords: 3,
    tokensNow: tokens,
    tokensBefore: tokens + 100,
    window: window,
    hasWorkingSet: true,
  );
  final nearLimit = nearLimitNoticeLine(tokens: tokens, window: window);
  // The meter: the status line rides _effectiveContextWindow — the same
  // wiring seam.
  final meter = window;
  return (
    trigger: wiring.settings.reserveTokens,
    guard: guard,
    postHide: postHide.contains('/$window ') ? window : 0,
    nearLimit: nearLimit.contains('/$window') ? window : 0,
    meter: meter,
  );
}

void _assertOneWindow(
  ({int trigger, int guard, int postHide, int nearLimit, int meter}) c,
  int window,
) {
  expect(c.guard, window, reason: 'the over-window guard');
  expect(c.postHide, window, reason: 'the post-hide notice');
  expect(c.nearLimit, window, reason: 'the near-limit notice');
  expect(c.meter, window, reason: 'the ctx meter');
  // The trigger is DERIVED from the same window (the reserve curve —
  // no tuning pin, so the settings are byte-identical to the curve).
  expect(
    c.trigger,
    CompactionSettings.forWindow(window).reserveTokens,
    reason: 'the trigger reserve scales with the window',
  );
}

void main() {
  group('C6 one-window consistency (gh-2492 C6)', () {
    test('catalog-only identity: all four consumers agree on the carried '
        'window', () {
      final model = _model(window: 200000);
      final c = _consumers(
        model: model,
        contextWindowCap: null,
        tokens: 170000,
      );
      _assertOneWindow(c, 200000);
    });

    test('registry-pinned identity: a live detection moves ALL consumers '
        'together', () {
      final carried = _model(window: 131072);
      final registry = ContextWindowRegistry();
      // The endpoint reported a bigger window (the dmtools evidence:
      // 131k catalog vs ≥478k served).
      registry.publish(
        model: carried,
        window: 478000,
        source: ContextWindowSource.endpointReport,
      );
      final resolved = withRegisteredContextWindow(carried, registry);
      expect(resolved.contextWindow, 478000);
      final c = _consumers(
        model: resolved,
        contextWindowCap: null,
        tokens: 400000,
      );
      _assertOneWindow(c, 478000);
    });

    test('E4 shrink: a mid-session registry publish moves ALL consumers '
        'DOWN together (no split-brain window)', () {
      final carried = _model(window: 200000);
      final registry = ContextWindowRegistry();
      registry.publish(
        model: carried,
        window: 64000,
        source: ContextWindowSource.userPin,
      );
      final resolved = withRegisteredContextWindow(carried, registry);
      final c = _consumers(
        model: resolved,
        contextWindowCap: null,
        tokens: 50000,
      );
      _assertOneWindow(c, 64000);
    });

    test('owner cap: the cap clamps every consumer identically', () {
      final model = _model(window: 478000);
      final c = _consumers(
        model: model,
        contextWindowCap: 128000,
        tokens: 100000,
      );
      _assertOneWindow(c, 128000);
    });

    test('the child path resolves the same window as the wiring seam', () {
      // _childContextWindow = effectiveContextWindow(registry ?? carried,
      // cap) — byte-identical to the wiring seam for the same basis.
      final carried = _model(window: 131072);
      final registry = ContextWindowRegistry();
      registry.publish(
        model: carried,
        window: 478000,
        source: ContextWindowSource.endpointReport,
      );
      final resolved = withRegisteredContextWindow(carried, registry);
      final childWindow = effectiveContextWindow(
        registry.windowFor(carried) ?? carried.contextWindow,
        null,
      );
      final wiringWindow = resolveCompactionHostWiring(
        mainModel: resolved,
        contextWindowCap: null,
      ).window;
      expect(childWindow, wiringWindow);
    });
  });
}
