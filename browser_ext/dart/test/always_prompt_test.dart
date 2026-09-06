// alwaysPrompts enforcement (PR #33 review): the spec table's
// always-prompting tools must reach the approval gate as per-tool prompt
// overrides (the host seeds them via alwaysPromptOverrides), so the gate
// asks on every call in every session mode — yolo and an always-allow
// grant included — and denies (never silently runs) when no approval UI
// can answer.
import 'package:flutter_agent_harness/src/approval/approval.dart';
import 'package:test/test.dart';

import '../src/browser_api_tools.dart';

ApprovalManager _manager(
  ApprovalMode mode, {
  void Function(ApprovalRequest request)? onPrompt,
}) => ApprovalManager(
  mode: mode,
  overrides: alwaysPromptOverrides(),
  prompt: onPrompt == null
      ? null
      : (request) async {
          onPrompt(request);
          return ApprovalDecision.approveOnce;
        },
);

const _injectJsArgs = {'tabId': 1, 'code': '() => 1', 'world': 'MAIN'};

void main() {
  group('alwaysPromptOverrides through the approval gate', () {
    test('inject_js is the one always-prompting tool', () {
      expect(alwaysPromptOverrides().keys, {'inject_js'});
    });

    test('yolo mode still prompts (the mode no longer auto-allows)', () async {
      var prompts = 0;
      final m = _manager(ApprovalMode.yolo, onPrompt: (_) => prompts++);
      final outcome = await m.authorize(
        toolName: 'inject_js',
        tier: ApprovalTier.exec,
        arguments: _injectJsArgs,
      );
      expect(prompts, 1);
      expect(outcome.allowed, isTrue);
    });

    test('an always-allow grant does not silence the prompt', () async {
      var prompts = 0;
      final m = _manager(ApprovalMode.yolo, onPrompt: (_) => prompts++);
      m.allowAlways('inject_js');
      final outcome = await m.authorize(
        toolName: 'inject_js',
        tier: ApprovalTier.exec,
        arguments: _injectJsArgs,
      );
      expect(prompts, 1);
      expect(outcome.allowed, isTrue);
    });

    test('no approval UI denies instead of silently running', () async {
      final outcome = await _manager(ApprovalMode.yolo).authorize(
        toolName: 'inject_js',
        tier: ApprovalTier.exec,
        arguments: _injectJsArgs,
      );
      expect(outcome.allowed, isFalse);
      expect(outcome.reason, contains('no approval UI'));
    });

    test('unattended mode never silently runs a must-prompt tool', () async {
      final outcome = await _manager(ApprovalMode.unattended).authorize(
        toolName: 'inject_js',
        tier: ApprovalTier.exec,
        arguments: _injectJsArgs,
      );
      expect(outcome.allowed, isFalse);
    });

    test(
      'other browser tools keep the mode behavior (yolo auto-allows)',
      () async {
        var prompted = false;
        final m = _manager(ApprovalMode.yolo, onPrompt: (_) => prompted = true);
        final outcome = await m.authorize(
          toolName: 'tabs_query',
          tier: ApprovalTier.read,
          arguments: const {},
        );
        expect(prompted, isFalse);
        expect(outcome.allowed, isTrue);
      },
    );
  });
}
