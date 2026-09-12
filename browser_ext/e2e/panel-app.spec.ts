// AC1 (v2.1 panel hosting): panel.html HEAD-probes app/index.html — with the
// bundled fa app build it redirects to the real app; without it the legacy
// v1 fallback UI renders. Guards key on the BUNDLE FILE (what the probe and
// the harness settle-wait key on), never on FA_E2E_WITH_APP: a local
// --with-app build without the env var still redirects.
import { expect } from './helpers';
import { appBundlePresent, extensionId, skipWithoutChrome, test } from './helpers';


test.describe('panel.html hosting', () => {
  skipWithoutChrome();

  test('the panel page is reachable under the pinned extension id', async ({
    fa,
  }) => {
    // fa.panel already navigated here in the harness (and, with an app
    // bundle, settled on the redirect); assert the extension-origin URL so
    // a manifest-key drift (id change) fails here first, loudly — either
    // final flavor passes, the transient pre-redirect URL is never asserted.
    expect(fa.panel.url()).toMatch(
      new RegExp(`^chrome-extension://${extensionId()}/panel/`),
    );
  });

  test('no app build → legacy fallback renders', async ({ fa }) => {
    test.skip(
      appBundlePresent,
      'app bundle built — panel redirects to it, fallback unreachable',
    );
    // The HEAD probe resolves async; notice + legacy unhide land after it.
    await expect(fa.panel.locator('#legacy')).toBeVisible();
    await expect(fa.panel.locator('#status')).toBeAttached();
    await expect(fa.panel.locator('#notice')).toContainText(
      'fa app bundle not built',
    );
  });

  test('app build present → real app renders (canvas, no fatal overlay)', async ({
    fa,
  }) => {
    test.skip(
      !appBundlePresent,
      'needs the --with-app build (browser_ext/panel/app/ missing)',
    );
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
