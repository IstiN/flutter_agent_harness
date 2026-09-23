import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:flutter_agent_harness/src/cli/tui_chrome.dart';
import 'package:flutter_agent_harness/src/cli/tui_theme.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    FaThemeController.instance
      ..reset()
      ..profile = ColorProfile.trueColor;
  });

  tearDown(() {
    FaThemeController.instance
      ..reset()
      ..profile = ColorProfile.trueColor;
  });

  test('P1: success tint survives TranscriptMarkdown (round-1 blocker)',
      () {
    final card = tuiToolCard(
      const ToolCardSegments(title: 'bash', description: 'cargo test'),
      TuiCardPhase.success,
      60,
    );
    final tx = TranscriptMarkdown(width: 60);
    final painted = tx.sync(card);
    print('stored:  ${card.first}');
    print('painted: ${painted.first}');
    expect(painted.first, startsWith(FaThemeController.instance.toolSuccessBgSgr()));
    expect(painted.first, contains('cargo test'));
  });

  test('P2: /theme switch repaints the stored card with the NEW theme tint',
      () {
    final card = tuiToolCard(
      const ToolCardSegments(title: 'bash', description: 'boom'),
      TuiCardPhase.error,
      60,
    );
    final storedLead = card.first.substring(0, card.first.indexOf('b'));
    // Switch to the light palette, then view the stored row.
    FaThemeController.instance.activate('ohmypi-light');
    final fmt = AnsiMarkdown(width: 60);
    final repainted = fmt.formatLine(card.first);
    print('stored lead: $storedLead');
    print('repainted:   $repainted');
    expect(
      repainted,
      startsWith(FaThemeController.instance.toolErrorBgSgr()),
      reason: 'stored default-theme card must repaint via the boot-default '
          'role fallback with the CURRENT theme tint',
    );
  });

  test('P3: unknown (config-palette) tint lead degrades to bubble repaint',
      () {
    // A lead prefix no built-in palette ever painted.
    const alien = '\x1b[48;2;1;2;3mtext\x1b[0m';
    final out = AnsiMarkdown(width: 40).formatLine(alien);
    print('alien repaint: $out');
    expect(out, startsWith(tuiUserMessageBgSgr()));
  });

  test('P4: over-wide stored card row never crashes and never shrinks',
      () {
    final card = tuiToolCard(
      const ToolCardSegments(title: 'bash', description: 'x' * 100),
      TuiCardPhase.success,
      60,
    );
    expect(tuiTextWidth(
      card.first.replaceAll(AnsiMarkdown.ansiSgrPattern, ''),
      ), greaterThan(60), reason: 'oversize description is only padded, '
      'never chopped — card rows stay single-line by contract');
    final out = AnsiMarkdown(width: 40).formatLine(card.first);
    expect(out, isNotEmpty);
  });

  test('P5: pi palette has no toolPendingBg — pending cards lose the band',
      () {
    FaThemeController.instance.activate('pi');
    final pending = tuiToolCard(
      const ToolCardSegments(title: 'bash', description: 'x'),
      TuiCardPhase.running,
      40,
    );
    final settled = tuiToolCard(
      const ToolCardSegments(title: 'bash', description: 'x'),
      TuiCardPhase.success,
      40,
    );
    print('pi pending (lead): ${pending.first.substring(0, 24)}');
    print('pi settled (lead): ${settled.first.substring(0, 24)}');
    expect(pending.first.startsWith('\x1b[48'), isFalse,
        reason: 'pi palette defines no toolPendingBg — pending/running '
            'cards render plain while settled cards keep a tint');
    expect(settled.first.startsWith('\x1b[48'), isTrue);
  });
}
