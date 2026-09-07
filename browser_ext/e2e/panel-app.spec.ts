// AC1 (v2.1 panel hosting): panel.html HEAD-probes app/index.html — with the
// bundled fa app build it redirects to the real app; without it the legacy
// v1 fallback UI renders. CI's --with-app job (FA_E2E_WITH_APP=1) covers the
// app branch; the default job pins the fallback.
import { expect } from './helpers';
import { extensionId, skipWithoutChrome, test } from './helpers';

const withApp = process.env.FA_E2E_WITH_APP === '1';

test.describe('panel.html hosting', () => {
  skipWithoutChrome();

  test('the panel page is reachable under the pinned extension id', async ({
    fa,
  }) => {
    // fa.panel already navigated here in the harness; assert the URL shape so
    // a manifest-key drift (id change) fails here first, loudly.
    expect(fa.panel.url()).toBe(
      `chrome-extension://${extensionId()}/panel/panel.html`,
    );
  });

  test('no app build → legacy fallback renders', async ({ fa }) => {
    test.skip(withApp, 'panel/app is built in this run — app branch applies');
    // The HEAD probe resolves async; notice + legacy unhide land after it.
    await expect(fa.panel.locator('#legacy')).toBeVisible();
    await expect(fa.panel.locator('#status')).toBeAttached();
    await expect(fa.panel.locator('#notice')).toContainText(
      'fa app bundle not built',
    );
  });

  test('FA_E2E_WITH_APP=1 → real app renders (canvas, no fatal overlay)', async ({
    fa,
  }) => {
    test.skip(!withApp, 'needs the --with-app build (FA_E2E_WITH_APP=1)');
    await expect(fa.panel).toHaveURL(/\/panel\/app\/index\.html$/);
    // The flutter app paints into flt-glass / flt-scene hosts; the shared
    // observable is a live <canvas> (Flutter web renderer) and a body that
    // never rendered the scaffold-only fatal notice.
    await expect(fa.panel.locator('canvas').first()).toBeVisible({
      timeout: 60_000,
    });
    await expect(fa.panel.locator('body')).not.toContainText(
      'fa app bundle not built',
    );
  });
});
