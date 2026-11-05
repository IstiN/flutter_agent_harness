// gh-2059 AC2 + AC4: the panel composer's `/compact` runs a compaction and
// NEVER enters the transcript as a user message (the incident's relay-224
// record: `/compact` rode the wire as literal text), an unknown slash
// command answers locally like the CLI, and the receipts surface as
// `system` panel events (the VISIBLE contract — silence was the bug).
import { expect } from './helpers';
import { appBundlePresent, skipWithoutChrome, test } from './helpers';

test.describe('/compact and unknown-slash parity (gh-2059)', () => {
  skipWithoutChrome();
  // Same legacy-composer caveat as panel-focus: the app build redirects
  // the panel before the composer DOM renders.
  test.skip(
    appBundlePresent,
    'legacy composer only — the app build redirects the panel to app/',
  );

  test('/compact never lands as a user message and emits a system receipt', async ({
    fa,
  }) => {
    await fa.bootAgent();
    await fa.collectEvents();

    const after = (await fa.eventCount()) - 1;
    await fa.panel.fill('#prompt', '/compact');
    await fa.panel.click('#sendPrompt');

    // The receipt — manual compaction answers with a system event whether
    // the pass succeeds (before/after tokens) or fails (visible failure,
    // AC4/AC5); the ONE forbidden outcome is silence plus a fake user row.
    await fa.waitEvent((e) => e.type === 'system', 45_000, after);

    const events = await fa.events();
    const systemTexts = events
      .filter((e) => e.type === 'system')
      .map((e) => String(e.text ?? ''))
      .join('\n');
    // No refusal, no dead end: the receipt mentions compaction either way.
    expect(systemTexts.toLowerCase()).toContain('compact');

    // And the transcript never carries the command as a user row: no
    // user-role message_done and no user bubble with the literal input.
    const userRows = events.filter(
      (e) => e.type === 'message_done' && e.role === 'user',
    );
    expect(userRows).toHaveLength(0);
    const transcript = await fa.panel.evaluate(
      () => document.querySelector('#transcript')?.textContent ?? '',
    );
    expect(transcript).not.toContain('/compact');
  });

  test('an unknown slash command answers locally and is not sent to the model', async ({
    fa,
  }) => {
    await fa.bootAgent();
    await fa.collectEvents();

    const after = (await fa.eventCount()) - 1;
    await fa.panel.fill('#prompt', '/definitely-not-a-command');
    await fa.panel.click('#sendPrompt');

    await fa.waitEvent((e) => e.type === 'system', 45_000, after);
    const events = await fa.events();
    const systemTexts = events
      .filter((e) => e.type === 'system')
      .map((e) => String(e.text ?? ''))
      .join('\n');
    // CLI parity: "unknown command: …".
    expect(systemTexts).toContain('unknown command: /definitely-not-a-command');

    // Nothing reached the model: no assistant reply, no user row.
    const userRows = events.filter(
      (e) => e.type === 'message_done' && e.role === 'user',
    );
    expect(userRows).toHaveLength(0);
    const transcript = await fa.panel.evaluate(
      () => document.querySelector('#transcript')?.textContent ?? '',
    );
    expect(transcript).not.toContain('/definitely-not-a-command');
  });
});
