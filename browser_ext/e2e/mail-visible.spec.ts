// Issue #320 e2e: inbound hub/DAP/bridge mail is VISIBLE in the chat — the
// host announces the attributed user message ("[from <peer>] <text>") at
// ARRIVAL (bubble + event, before the assistant reply), queues mid-run mail
// behind a pending status until the step boundary delivers it, and keeps
// AC18 dedupe (one bubble per delivery).
//
// Drives faAgent.pushMail directly — the host intake seam the bug pinned —
// on the deterministic fake provider: no hub, no LLM. The default PR leg
// runs the legacy panel (no app bundle); with --with-app builds the v2 app
// branch renders instead (covered at unit level by flutter_app relay tests).
import {
  appBundlePresent,
  awaitPanelSettled,
  expect,
  skipWithoutChrome,
  test,
  type FaEvent,
} from './helpers';

skipWithoutChrome();

const MAIL = 'hallo from the hub';
const MAIL_ROW = '[from peer-1] hallo from the hub';

/** User rows carry the host's per-turn `[context] …` header when the turn
 * injected tool-tab context — both surfaces strip it for display; the spec
 * mirrors that before matching. */
function clean(t: string | undefined): string {
  const raw = t ?? '';
  const at = raw.indexOf('\n');
  return raw.startsWith('[context] ') && at > 0 ? raw.slice(at + 1) : raw;
}


test.describe('inbound mail visibility (#320)', () => {
  skipWithoutChrome();

  test('AC1/E4/AC6: idle mail renders the attributed user bubble at arrival '
      + 'before the reply, exactly once — duplicates stay deduped', async ({
    fa,
  }) => {
    await fa.swEval((mode) => {
      const sw = globalThis as unknown as {
        faAgent: { boot(c: unknown): Promise<unknown> };
      };
      return sw.faAgent.boot({ approvalMode: mode });
    }, 'unattended');
    await expect
      .poll(() =>
        fa.swEval(() => {
          const sw = globalThis as unknown as {
            faAgent: { getState(): { booted: boolean } };
          };
          return sw.faAgent.getState().booted;
        }),
      )
      .toBe(true);
    // The panel's push-port binds to the SW instance alive at page load;
    // booting the agent may have revived the SW since, orphaning it.
    // Reload so the panel subscribes on the live instance (real users
    // open the panel after boot all the time).
    await fa.panel.reload();
    await awaitPanelSettled(fa.panel);
    // NOTE: no fa.collectEvents() here — the seam's onEvent is a SINGLE
    // callback (last writer wins); installing the spec collector would
    // overwrite sw/main.js's panel pusher and blind the very DOM under
    // test. Event-level assertions live in the test below.
    await fa.swEval((payload: [string, string]) => {
      const sw = globalThis as unknown as {
        faAgent: { pushMail(from: string, text: string): void };
      };
      sw.faAgent.pushMail(payload[0], payload[1]);
    }, ['peer-1', MAIL]);

    // AC1: the attributed user bubble renders in the legacy transcript,
    // as the FIRST bubble — before the assistant reply.
    const userBubble = fa.panel.locator('.bubble.user', { hasText: MAIL_ROW });
    await expect(userBubble).toHaveCount(1);
    await expect(fa.panel.locator('#transcript > div').first()).toHaveClass(
      /bubble user/,
    );
    await expect(fa.panel.locator('.bubble.assistant')).toHaveCount(1);

    // AC18 dedupe: the same delivery again (at-least-once hub) — no
    // second bubble, no restarted turn.
    await fa.swEval((payload: [string, string]) => {
      const sw = globalThis as unknown as {
        faAgent: { pushMail(from: string, text: string): void };
      };
      sw.faAgent.pushMail(payload[0], payload[1]);
    }, ['peer-1', MAIL]);
    await fa.panel.waitForTimeout(1500);
    await expect(
      fa.panel.locator('.bubble.user', { hasText: MAIL_ROW }),
    ).toHaveCount(1);
    const running = await fa.swEval(() => {
      const sw = globalThis as unknown as {
        faAgent: { getState(): { running: boolean } };
      };
      return sw.faAgent.getState().running;
    });
    expect(running).toBe(false);
  });

  test('AC3: mid-run mail queues behind a pending indicator and renders '
      + 'exactly once at the boundary', async ({ fa }) => {
    await fa.swEval((mode) => {
      const sw = globalThis as unknown as {
        faAgent: { boot(c: unknown): Promise<unknown> };
      };
      return sw.faAgent.boot({ approvalMode: mode });
    }, 'always-ask');
    await expect
      .poll(() =>
        fa.swEval(() => {
          const sw = globalThis as unknown as {
            faAgent: { getState(): { booted: boolean } };
          };
          return sw.faAgent.getState().booted;
        }),
      )
      .toBe(true);
    await fa.collectEvents();

    // Open a deterministic mid-run window: a navigate prompt parks the turn
    // on the always-ask approval gate (fake provider scripts the tool call).
    await fa.sendUser(`navigate ${fa.fixture.url}`);
    const approval = await fa.waitEvent((e) => e.type === 'approval_request');

    // Mail lands mid-run: queued, announced with sender + count.
    const before = await fa.eventCount();
    await fa.swEval((payload: [string, string]) => {
      const sw = globalThis as unknown as {
        faAgent: { pushMail(from: string, text: string): void };
      };
      sw.faAgent.pushMail(payload[0], payload[1]);
    }, ['peer-2', 'queued mid-run hello']);
    await fa.waitEvent(
      (e) =>
        e.type === 'status' &&
        (e.mail as { pending?: number } | undefined)?.pending === 1,
      45_000,
      before - 1,
    );

    // The boundary: approval resolves, the turn drains the mail as steering
    // and the delivered bubble renders exactly once.
    await fa.decide(approval.id!, true);
    await expect.poll(async () => {
      const events = await fa.events();
      return events.filter(
        (e) =>
          e.type === 'message_done' &&
          e.role === 'user' &&
          clean(e.text) === '[from peer-2] queued mid-run hello',
      ).length;
    }).toBe(1);

    // Delivered → the pending indicator is gone from the host state.
    await expect.poll(() =>
      fa.swEval(() => {
        const sw = globalThis as unknown as {
          faAgent: { getState(): { running: boolean; mail?: unknown } };
        };
        const state = sw.faAgent.getState();
        return state.running || state.mail != null;
      }),
    ).toBe(false);
  });
});
