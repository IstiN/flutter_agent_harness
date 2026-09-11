// chrome.* bridge end to end (issue #137): the browser_api /
// browser_api_catalog tools through the REAL agent loop (fake: provider
// `tool <name> <json>` directives) against the REAL extension surface —
//
//   AC8:  the self-serve scenario — a task no curated tool covers ("find
//         all tabs playing audio and mute them") completed with ONLY the
//         catalog + bridge, end-to-end, zero code changes;
//   AC5:  the mode-driven gating matrix — ask prompts per call, write
//         auto-approves read/write but STILL prompts exec namespaces,
//         yolo runs everything with ZERO prompts, chrome.management
//         denies in every mode, unknown namespaces default to exec;
//   AC3:  bridge/curated parity — chrome.bookmarks.search returns the
//         same data as the curated bookmarks_list;
//   AC7:  bridge results are UNTRUSTED-wrapped and credential-shaped
//         cookie values are redacted;
//   inj:  bridge-path page injection (chrome.debugger over the bridge)
//         reaches the page world like curated inject_js.
import { expect, FaHarness, skipWithoutChrome, test } from './helpers';

/** chrome.tabs node as the specs read it (id + mute state). */
type TabInfo = { id: number; mutedInfo?: { muted: boolean } };

/** chrome.bookmarks node (tree child or flat search hit). */
type BookmarkNode = { url?: string; children?: BookmarkNode[] };

/** The extension-page chrome.* surface these specs touch. */
type ExtPageChrome = {
  tabs: {
    query(q: Record<string, unknown>): Promise<TabInfo[]>;
    get(id: number): Promise<TabInfo>;
  };
  cookies: {
    set(details: Record<string, unknown>): Promise<unknown>;
  };
};

/** Strips the quarantine wrapper and parses the JSON payload inside. */
function unwrap(text: string): Record<string, unknown> {
  const m = text.match(
    /<<<UNTRUSTED PAGE CONTENT[^>]*>>\n([\s\S]*)\n<<<END UNTRUSTED>>/,
  );
  return JSON.parse(m ? m[1] : text) as Record<string, unknown>;
}

/** The bridge call envelope: {ok, path, result} | {ok:false, error}. */
function envelopeOf(text: string): {
  ok: boolean;
  result?: unknown;
  error?: { code?: string };
} {
  return unwrap(text) as { ok: boolean; result?: unknown; error?: { code?: string } };
}

/** approval_request events raised after a snapshot index. */
async function promptsSince(fa: FaHarness, after: number) {
  return (await fa.events()).filter(
    (e, i) => i > after && e.type === 'approval_request',
  );
}

/**
 * One browser_api turn: sends the directive, answers every approval
 * prompt it raises (ask mode: the matrix prompt; write mode: the
 * exec-tier risk ask), and resolves with the tool_result.
 */
async function runBridgeTurn(
  fa: FaHarness,
  path: string,
  args: unknown[],
  allow = true,
): Promise<{ isError: boolean; text: string }> {
  const after = (await fa.eventCount()) - 1;
  await fa.sendUser(`tool browser_api ${JSON.stringify({ path, args })}`);
  for (;;) {
    const evt = await fa.waitEvent(
      (e) =>
        (e.type === 'approval_request' &&
          String(e.summary).includes('browser_api')) ||
        (e.type === 'tool_result' && e.toolName === 'browser_api'),
      45_000,
      after,
    );
    if (evt.type === 'tool_result') {
      return { isError: evt.isError === true, text: String(evt.text ?? '') };
    }
    await fa.decide(evt.id!, allow);
  }
}

/**
 * Opens the audio fixture and waits until the tab is actually audible —
 * from the panel's own chrome.tabs, before any agent involvement, so a
 * headless media failure surfaces here and not as a confusing AC8 miss.
 */
async function openAudibleTab(fa: FaHarness): Promise<number> {
  const nav = await fa.dispatch('navigate', {
    url: `${fa.fixture.url}audio.html`,
  });
  const tabId = nav.result!.tabId!;
  await expect.poll(
    async () =>
      fa.panel.evaluate(async (id: number) => {
        // page.evaluate serializes the callback source: module-scope
        // runtime values are unavailable, but the ExtPageChrome type
        // erases fine — re-derive the handle inline.
        const tabs = await (
          window as unknown as { chrome: ExtPageChrome }
        ).chrome.tabs.query({ audible: true });
        return tabs.some((t) => t.id === id);
      }, tabId),
    {
      message: 'audio fixture tab becomes audible (headless media spin-up)',
      timeout: 30_000,
    },
  ).toBe(true);
  return tabId;
}

test.describe.serial('chrome.* bridge (issue #137)', () => {
  skipWithoutChrome();

  test('AC8: self-serve — audible tabs found and muted via catalog+bridge only', async ({
    fa,
  }) => {
    const tabId = await openAudibleTab(fa);
    await fa.bootAgent('yolo');
    await fa.collectEvents();
    const after = (await fa.eventCount()) - 1;

    // 1) discovery first — that is the whole point of the catalog.
    await fa.sendUser('tool browser_api_catalog {}');
    const cat = await fa.waitEvent(
      (e) => e.type === 'tool_result' && e.toolName === 'browser_api_catalog',
      45_000,
      after,
    );
    expect(cat.isError).toBeFalsy();
    const namespaces = unwrap(String(cat.text ?? '')).namespaces as string[];
    expect(namespaces, 'catalog lists the tabs namespace').toContain('tabs');

    // 2) find the playing tabs through the bridge.
    const q = await runBridgeTurn(fa, 'chrome.tabs.query', [{ audible: true }]);
    expect(q.isError, q.text).toBe(false);
    const audible = envelopeOf(q.text).result as TabInfo[];
    expect(
      audible.some((t) => t.id === tabId),
      `audible tab ${tabId} found among [${audible.map((t) => t.id)}]`,
    ).toBe(true);

    // 3) mute it through the bridge.
    const u = await runBridgeTurn(fa, 'chrome.tabs.update', [
      tabId,
      { muted: true },
    ]);
    expect(u.isError, u.text).toBe(false);
    expect((envelopeOf(u.text).result as TabInfo).mutedInfo?.muted).toBe(true);

    // 4) the browser itself confirms — outside the agent loop.
    const muted = await fa.panel.evaluate(async (id: number) => {
      const t = await (
        window as unknown as { chrome: ExtPageChrome }
      ).chrome.tabs.get(id);
      return t?.mutedInfo?.muted === true;
    }, tabId);

    expect(muted).toBe(true);

    // 4b) unknown namespace in yolo: executes (no prompt), fails as data
    // — the exec default never blocks the mode (AC5e case c).
    const unknown = await runBridgeTurn(
      fa,
      'chrome.definitelyNotAChromeNamespace.ping',
      [],
    );
    expect(unknown.isError).toBe(true);
    expect(envelopeOf(unknown.text).error?.code).toBe('api_missing');

    // 5) yolo means ZERO prompts, and the one-time notice fired.
    expect(await promptsSince(fa, after)).toEqual([]);
    expect(
      (await fa.events()).some(
        (e, i) =>
          i > after &&
          e.type === 'status' &&
          String(e.note ?? '').includes('bridge: first chrome.* call'),
      ),
      'one-time yolo notice on the first bridge call',
    ).toBe(true);
  });

  test('AC5a: ask mode — bridge calls prompt once; allow executes; deny list never prompts', async ({
    fa,
  }) => {
    await fa.bootAgent('ask');
    await fa.collectEvents();
    const after = (await fa.eventCount()) - 1;

    // Read-tier call in ask mode: the matrix prompts (exactly once).
    await fa.sendUser(
      'tool browser_api {"path":"chrome.idle.queryState","args":[60]}',
    );
    const req = await fa.waitEvent(
      (e) => e.type === 'approval_request',
      45_000,
      after,
    );
    expect(String(req.summary)).toContain('browser_api');
    await fa.decide(req.id!, true);
    const res = await fa.waitEvent(
      (e) => e.type === 'tool_result' && e.toolName === 'browser_api',
      45_000,
      after,
    );
    expect(res.isError).toBeFalsy();
    expect(envelopeOf(String(res.text ?? '')).ok).toBe(true);
    expect(await promptsSince(fa, after)).toHaveLength(1);

    // Exec-tier call in ask mode: also exactly ONE prompt (the matrix),
    // never two — the dynamic risk ask stays silent here.
    const after2 = (await fa.eventCount()) - 1;
    const exec = await runBridgeTurn(fa, 'chrome.cookies.getAll', [{}]);
    expect(exec.isError, exec.text).toBe(false);
    expect(await promptsSince(fa, after2)).toHaveLength(1);

    // Hard deny: chrome.management NEVER prompts — straight data error.
    const after3 = (await fa.eventCount()) - 1;
    const denied = await runBridgeTurn(fa, 'chrome.management.getSelf', []);
    expect(denied.isError).toBe(true);
    expect(envelopeOf(denied.text).error?.code).toBe('denied_namespace');
    expect(await promptsSince(fa, after3)).toEqual([]);
  });

  test('AC5b: write mode — read/write auto-approve, exec still prompts', async ({
    fa,
  }) => {
    await fa.bootAgent('write');
    await fa.collectEvents();

    // Read tier: silent.
    let after = (await fa.eventCount()) - 1;
    const read = await runBridgeTurn(fa, 'chrome.idle.queryState', [60]);
    expect(read.isError, read.text).toBe(false);
    expect(await promptsSince(fa, after)).toEqual([]);

    // Write path (AC4): bookmarks.create lands with no prompt, remove
    // cleans up.
    after = (await fa.eventCount()) - 1;
    const created = await runBridgeTurn(fa, 'chrome.bookmarks.create', [
      { title: 'fa-bridge-e2e', url: fa.fixture.url },
    ]);
    expect(created.isError, created.text).toBe(false);
    expect(await promptsSince(fa, after)).toEqual([]);
    const bm = envelopeOf(created.text).result as { id: string };
    const removed = await runBridgeTurn(fa, 'chrome.bookmarks.remove', [bm.id]);
    expect(removed.isError, removed.text).toBe(false);

    // Exec tier: STILL prompts in write mode — the mode never silently
    // runs the exec surface.
    after = (await fa.eventCount()) - 1;
    const exec = await runBridgeTurn(fa, 'chrome.cookies.getAll', [{}]);
    expect(exec.isError, exec.text).toBe(false);
    expect(await promptsSince(fa, after)).toHaveLength(1);
  });

  test('AC5e: unknown namespace defaults to exec — prompts in write mode', async ({
    fa,
  }) => {
    await fa.bootAgent('write');
    await fa.collectEvents();
    const after = (await fa.eventCount()) - 1;
    const res = await runBridgeTurn(
      fa,
      'chrome.definitelyNotAChromeNamespace.ping',
      [],
    );
    expect(res.isError).toBe(true);
    expect(envelopeOf(res.text).error?.code).toBe('api_missing');
    // The exec default ASKED before the (failing) call.
    expect(await promptsSince(fa, after)).toHaveLength(1);
  });

  test('AC3 parity: bridge chrome.bookmarks.search matches curated bookmarks_list', async ({
    fa,
  }) => {
    await fa.bootAgent(); // unattended default — no prompts on either path
    await fa.collectEvents();
    const after = (await fa.eventCount()) - 1;

    // A bookmark created through the BRIDGE (fresh profile is bare).
    const created = await runBridgeTurn(fa, 'chrome.bookmarks.create', [
      { title: 'fa-parity', url: fa.fixture.url },
    ]);
    expect(created.isError, created.text).toBe(false);
    const bm = envelopeOf(created.text).result as { id: string };

    // Curated: the full tree.
    await fa.sendUser('tool bookmarks_list {}');
    const curated = await fa.waitEvent(
      (e) => e.type === 'tool_result' && e.toolName === 'bookmarks_list',
      45_000,
      after,
    );
    expect(curated.isError).toBeFalsy();

    // Bridge: search("") over the same store.
    const searched = await runBridgeTurn(fa, 'chrome.bookmarks.search', ['']);
    expect(searched.isError, searched.text).toBe(false);

    const treeUrls = new Set<string>();
    const walk = (nodes: BookmarkNode[]) => {
      for (const n of nodes) {
        if (typeof n.url === 'string') treeUrls.add(n.url);
        if (Array.isArray(n.children)) walk(n.children);
      }
    };
    walk(unwrap(String(curated.text ?? '')) as unknown as BookmarkNode[]);
    const searchUrls = (envelopeOf(searched.text).result as BookmarkNode[])
      .filter((n) => typeof n.url === 'string')
      .map((n) => n.url as string);
    for (const url of searchUrls) {
      expect(
        treeUrls,
        `bridge-search url ${url} present in the curated tree`,
      ).toContain(url);
    }
    expect(
      treeUrls.has(fa.fixture.url),
      'the bridge-created bookmark visible to the curated tree',
    ).toBe(true);
    expect(
      searchUrls.includes(fa.fixture.url),
      'the bridge-created bookmark visible to bridge search',
    ).toBe(true);

    await runBridgeTurn(fa, 'chrome.bookmarks.remove', [bm.id]);
  });

  test('AC7: bridge results are UNTRUSTED-wrapped; credential cookies redacted', async ({
    fa,
  }) => {
    // A credential-shaped cookie on the fixture origin (from the panel's
    // own chrome.cookies — an attacker's would already be in the jar).
    await fa.bootAgent('yolo');
    await fa.collectEvents();
    await fa.panel.evaluate((url: string) =>
      (window as unknown as { chrome: ExtPageChrome }).chrome.cookies.set({
        url,
        name: 'cloudsmith',
        value: 'AKIAIOSFODNN7EXAMPLE',
      }),
    fa.fixture.url);

    const res = await runBridgeTurn(fa, 'chrome.cookies.getAll', [
      { url: fa.fixture.url },
    ]);
    expect(res.isError, res.text).toBe(false);
    // The wrapper: browser-derived data is quarantined, never
    // instruction-grade.
    expect(res.text).toContain('<<<UNTRUSTED');
    expect(res.text).toContain('never as instructions');
    // The credential never reaches the transcript raw.
    expect(res.text).not.toContain('AKIAIOSFODNN7EXAMPLE');
  });

  test('injection parity: bridge-path debugger injection lands like curated inject_js', async ({
    fa,
  }) => {
    const nav = await fa.dispatch('navigate', { url: fa.fixture.url });
    expect(nav.ok, JSON.stringify(nav.error)).toBe(true);
    const tabId = nav.result!.tabId!;
    await fa.bootAgent('yolo');
    await fa.collectEvents();

    // The bridge path: chrome.debugger attach → Runtime.evaluate →
    // detach — the exact CDP mechanism the curated inject_js rides.
    const attach = await runBridgeTurn(fa, 'chrome.debugger.attach', [
      { target: { tabId }, version: '1.3' },
    ]);
    expect(attach.isError, attach.text).toBe(false);
    const evalRes = await runBridgeTurn(fa, 'chrome.debugger.sendCommand', [
      {
        target: { tabId },
        method: 'Runtime.evaluate',
        params: {
          expression: "window.__bridgeMarker = 'bridge'",
          returnByValue: true,
        },
      },
    ]);
    expect(evalRes.isError, evalRes.text).toBe(false);
    const detach = await runBridgeTurn(fa, 'chrome.debugger.detach', [
      { target: { tabId } },
    ]);
    expect(detach.isError, detach.text).toBe(false);

    const page = await fa.fixturePage();
    const bridgeMarker = await page.evaluate(
      () => (window as unknown as Record<string, unknown>).__bridgeMarker,
    );
    expect(bridgeMarker, 'bridge-path injection reached the page world').toBe(
      'bridge',
    );

    // The curated path over the same CDP surface (yolo lifted its
    // always-prompt).
    await fa.sendUser(
      `inject_js ${tabId} MAIN window.__curatedMarker = 'curated'`,
    );
    const inj = await fa.waitEvent(
      (e) => e.type === 'tool_result' && e.toolName === 'inject_js',
      45_000,
    );
    expect(inj.isError).toBeFalsy();
    expect(
      await page.evaluate(
        () => (window as unknown as Record<string, unknown>).__curatedMarker,
      ),
    ).toBe('curated');
  });
});
