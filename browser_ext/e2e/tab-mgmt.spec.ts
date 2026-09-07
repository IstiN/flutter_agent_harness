// Tab management ACs against the REAL chrome tab surface:
//   AC17: tabs the agent opens under a task land in the labelled
//         "fa — <id>" group; task_end closes ONLY those — a user tab
//         (opened outside the agent) survives.
//   sessions_restore: the scripted directive reopens a closed tab by
//         sessionId from the recently-closed list.
import { expect, skipWithoutChrome, test, type FaSwSeam } from './helpers';

/** chrome.tabs/sessions API slice available inside the SW. */
interface ChromeTabs {
  chrome: {
    tabs: {
      get(id: number): Promise<unknown>;
      query(info: { url?: string }): Promise<{ id: number; url?: string }[]>;
      remove(id: number): Promise<void>;
    };
    sessions: {
      getRecentlyClosed(): Promise<
        { tab?: { sessionId?: string; url?: string } }[]
      >;
    };
    tabGroups: { get(id: number): Promise<{ title: string }> };
  };
}

const chromeOf = () => (globalThis as unknown as ChromeTabs).chrome;
const faSw = () => (globalThis as unknown as { faSw: FaSwSeam }).faSw;

test.describe('tab management', () => {
  skipWithoutChrome();

  test('task group labels agent tabs; task_end closes only them', async ({
    fa,
  }) => {
    await fa.bootAgent();

    const taskId = `e2e-${Date.now()}`;
    await fa.swEval((id) => faSw().beginTask(id), taskId);

    // A user tab the agent never opened.
    const userTab = await fa.context.newPage();
    await userTab.goto('about:blank');

    const nav = await fa.dispatch('navigate', { url: fa.fixture.url });
    expect(nav.ok, JSON.stringify(nav.error)).toBe(true);
    const agentTabId = nav.result!.tabId!;

    // The task's tab group carries the "fa — <id>" label.
    const status = await fa.swEval(() => faSw().status());
    expect(status.taskId).toBe(taskId);
    expect(status.groupId).toBeTruthy();
    const groupId = status.groupId!;
    const group = await fa.swEval(
      (id) => chromeOf().tabGroups.get(id),
      groupId,
    );
    expect(group.title).toBe(`fa — ${taskId}`);

    // task_end: agent tab gone, user tab alive.
    const end = await fa.dispatch('task_end', {});
    expect(end.ok, JSON.stringify(end.error)).toBe(true);
    await expect
      .poll(() =>
        fa.swEval(
          (id) =>
            chromeOf()
              .tabs.get(id)
              .then(() => true, () => false),
          agentTabId,
        ),
      )
      .toBe(false);
    expect(userTab.isClosed()).toBe(false);
  });

  test('sessions_restore directive reopens the closed fixture tab', async ({
    fa,
  }) => {
    await fa.bootAgent();
    await fa.collectEvents();

    const nav = await fa.dispatch('navigate', { url: fa.fixture.url });
    expect(nav.ok, JSON.stringify(nav.error)).toBe(true);
    const tabId = nav.result!.tabId!;

    // Close it like a user would, then fish its sessionId out of the
    // recently-closed list (the tool contract takes an explicit id).
    await fa.swEval((id) => chromeOf().tabs.remove(id), tabId);
    const sessionId = await fa.swEval(async (base) => {
      const entries = await chromeOf().sessions.getRecentlyClosed();
      return (
        entries.find((e) => e.tab?.url?.startsWith(base))?.tab?.sessionId ??
        null
      );
    }, fa.fixture.url);
    expect(sessionId).toBeTruthy();

    await fa.sendUser(`sessions_restore ${sessionId}`);
    const result = await fa.waitEvent(
      (e) => e.type === 'tool_result' && e.toolName === 'sessions_restore',
    );
    expect(result.isError, String(result.text)).toBe(false);

    await expect
      .poll(() =>
        fa.swEval(
          async (base) => (await chromeOf().tabs.query({ url: `${base}*` })).length,
          [fa.fixture.url],
        ),
      )
      .toBeGreaterThan(0);
  });
});
