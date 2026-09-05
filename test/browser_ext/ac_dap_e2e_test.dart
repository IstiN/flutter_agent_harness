// AC6 — the extension on the DAP hub, end to end:
//
//   * a FakeHub (in-process DAP/1 hub) + a harness-side HubClient; the
//     extension gets faDap config + unattended approvals via chrome.storage
//     and chrome.runtime.reload() — the same path the panel's hub settings
//     use. Its signed hello must land in the hub registry.
//   * presence_query from the harness client lists the browser agent.
//   * a harness DM steers a real agent turn in the SW (transcript grows)
//     and the hub only ever relays ciphertext (no plaintext in frames).
//   * the fake provider's "dm " directive replies through dap_dm, so the
//     harness client receives an extension→local DM.
//
// Requires a REAL Chrome and a prior scripts/build_browser_ext.sh run. No
// Chrome → loud ChromeLaunchException; `integration` tag keeps this out of
// default runs.
@Tags(['integration'])
@TestOn('vm')
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';

import 'package:fa_hub_client/fa_hub_client.dart';
import 'package:test/test.dart';

import '../hub/fake_hub.dart';
import 'chrome_driver.dart';

FakeHub? _hub;
HubClient? _harness;
HeadlessChrome? _chrome;
late String browserAgentId;

/// Non-null once setUpAll succeeded; tests only run after that.
FakeHub get hub => _hub!;
HubClient get harness => _harness!;
HeadlessChrome get chrome => _chrome!;

void main() {
  setUpAll(() async {
    _hub = FakeHub();
    await hub.start();
    _harness = HubClient(
      config: HubConfig(url: hub.url.toString()),
      identity: await HubIdentity.generate(),
      backoff: (_) => const Duration(milliseconds: 5),
    );
    await harness.connect();
    _chrome = await HeadlessChrome.launch();

    // Subscribe BEFORE the reload so the hello cannot slip past us.
    final hello = hub.hellos.first.timeout(const Duration(seconds: 30));
    // faDap config + unattended approvals, then the panel-equivalent reload:
    // the SW reboots, the agent auto-boots from storage, DapIntegration
    // generates (and persists) its identity, and dials the hub.
    await evaluateInServiceWorker(
      chrome,
      'chrome.storage.local.set({faDap: {url: ${jsonEncode(hub.url.toString())}, '
      'name: "browser-fa"}, faApproval: "unattended"})',
      awaitPromise: true,
    );
    // Fire the reload without awaiting: the target is destroyed mid-command,
    // so the evaluate response may never come back.
    final sw = await chrome.attachServiceWorker();
    unawaited(sw.evaluate('chrome.runtime.reload()').catchError((Object _) {}));
    browserAgentId = await hello;
  });

  tearDownAll(() async {
    await _chrome?.dispose();
    await _harness?.disconnect();
    await _hub?.stop();
  });

  /// faAgent.getState(), tolerant of the SW restarting (reload) — probes
  /// that fail while the old worker tears down resolve to null and the
  /// poll retries.
  Future<Map<dynamic, dynamic>?> tryGetState() async {
    try {
      return await evaluateInServiceWorker(
            chrome,
            'globalThis.faAgent.getState()',
            awaitPromise: true,
          )
          as Map<dynamic, dynamic>?;
    } on Object {
      return null; // SW restarting — poll again
    }
  }

  test('extension hello is registered on the hub', () async {
    expect(browserAgentId, hasLength(16));
    expect(hub.rejectedHellos, 0);
  });

  test('presence_query lists the browser agent as online', () async {
    final agents = await pollUntil(
      () => harness.presenceQuery(),
      (agents) => agents.any((a) => a.agentId == browserAgentId && a.online),
      description: 'browser agent visible in presence',
      timeout: const Duration(seconds: 20),
    );
    expect(
      agents.firstWhere((a) => a.agentId == browserAgentId).name,
      'browser-fa',
    );
  });

  test(
    'harness DM steers an encrypted agent turn in the service worker',
    () async {
      // Wait for the post-reload boot before pinning the baseline, so the
      // growth below can only be the DM-steered turn.
      await pollUntil(
        tryGetState,
        (state) => state != null && state['booted'] == true,
        description: 'agent re-booted after reload',
        timeout: const Duration(seconds: 30),
      );
      final baseline =
          (await tryGetState())!['session']['messages'] as int? ?? 0;
      const dm = 'selftest: navigate data:text/html,<h1>dap-e2e</h1>';

      await harness.sendDm(browserAgentId, dm);

      // The steering mail reaches the SW and starts a turn: the transcript
      // (user + assistant + browser_navigate tool result) grows.
      await pollUntil(
        tryGetState,
        (state) =>
            state != null &&
            (state['session']['messages'] as int? ?? 0) > baseline,
        description: 'agent transcript grows after DAP steering',
        timeout: const Duration(seconds: 30),
      );

      // And the hub relayed CIPHERTEXT only — the DM text appears nowhere.
      expect(jsonEncode(hub.relayed), isNot(contains('selftest: navigate')));
      expect(jsonEncode(hub.relayed), isNot(contains('data:text/html')));
    },
  );

  test(
    'extension replies to the harness over DAP (fake dm directive)',
    () async {
      final reply = harness.inbound
          .firstWhere((m) => m.from == browserAgentId && m.plaintext != null)
          .timeout(const Duration(seconds: 30));

      // "dm " directive: the fake provider answers with a dap_dm call to the
      // DM's sender — a real extension→local encrypted reply.
      await harness.sendDm(browserAgentId, 'dm ping-browser-loop');
      final message = await reply;

      expect(message.plaintext, startsWith('fake: dm'));
      expect(message.plaintext, contains('ping-browser-loop'));
      // The reply, too, was ciphertext on the wire.
      expect(jsonEncode(hub.relayed), isNot(contains('ping-browser-loop')));
      expect(hub.deliveredTo, contains(browserAgentId));
    },
  );
}
