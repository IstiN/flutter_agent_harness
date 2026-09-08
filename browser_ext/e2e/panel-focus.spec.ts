// Issue #39: send a message from the panel chat and fa's reply steals (or
// never returns) the input focus — the follow-up message needs a fresh click
// on the textarea. The composer must keep/restore focus across send +
// response, for BOTH send gestures (Enter key and Send-button click).
import type { Page } from '@playwright/test';
import { expect } from './helpers';
import { skipWithoutChrome, test } from './helpers';

/** Types one prompt into the panel composer and sends it via `how`. */
async function ask(
  fa: { panel: Page },
  text: string,
  how: 'enter' | 'click',
): Promise<void> {
  await fa.panel.fill('#prompt', text);
  if (how === 'enter') {
    await fa.panel.press('#prompt', 'Enter');
  } else {
    await fa.panel.click('#sendPrompt');
  }
}

test.describe('panel composer focus (issue #39)', () => {
  skipWithoutChrome();

  for (const how of ['enter', 'click'] as const) {
    test(`focus returns to the prompt after the reply (${how})`, async ({
      fa,
    }) => {
      await fa.bootAgent();
      await fa.collectEvents();
      await fa.panel.locator('#legacy').waitFor({ state: 'visible' });

      const after = (await fa.eventCount()) - 1;
      await ask(fa, `focus probe ${how}`, how);

      // The reply landed — the turn is over, typing must work right away.
      await fa.waitEvent(
        (e) => e.type === 'message_done' && e.role === 'assistant',
        45_000,
        after,
      );
      expect(await fa.panel.evaluate(() => document.activeElement?.id)).toBe(
        'prompt',
      );

      // The follow-up needs no click: typing right into the focused field.
      await fa.panel.keyboard.type(' follow-up');
      expect(await fa.panel.inputValue('#prompt')).toBe(' follow-up');
    });
  }
});
