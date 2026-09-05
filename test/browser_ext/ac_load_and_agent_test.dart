// AC1 + AC2 — extension loads in headless Chrome and the embedded Dart
// agent boots and passes its scripted self-test:
//
//   AC1: the MV3 service worker target appears, with no console errors or
//        uncaught exceptions during boot (captured for >= 2s after attach).
//   AC2: globalThis.faAgent exists, reports booted, and selfTest() returns
//        ok:true with a browser_navigate tool result in its transcript.
//
// Requires a REAL Chrome (CI: browser-actions/setup-chrome + CHROME_PATH)
// and a prior `bash scripts/build_browser_ext.sh` (sw/agent.js is a build
// artifact). Without Chrome the suite fails loudly via
// ChromeLaunchException — there is no silent skip; the `integration` tag
// keeps it out of default `dart test` runs.
@Tags(['integration'])
@TestOn('vm')
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:test/test.dart';

import 'chrome_driver.dart';

/// The compiled embedded agent is a build artifact (gitignored).
void _requireBuiltAgent() {
  final agentJs = File('browser_ext/sw/agent.js');
  if (!agentJs.existsSync()) {
    fail(
      'browser_ext/sw/agent.js not found — run scripts/build_browser_ext.sh '
      'first (the embedded agent is a dart2js build artifact).',
    );
  }
}

HeadlessChrome? _chrome;

/// Non-null once setUpAll succeeded; tests only run after that.
HeadlessChrome get chrome => _chrome!;

void main() {
  setUpAll(() async {
    _requireBuiltAgent();
    _chrome = await HeadlessChrome.launch();
  });

  tearDownAll(() => _chrome?.dispose());

  test(
    'AC1: service worker boots with no console errors or exceptions',
    () async {
      final sw = await chrome.attachServiceWorker(
        timeout: const Duration(seconds: 45),
      );
      // Capture BEFORE the wait window so anything still settling lands here.
      await sw.enableErrorCapture();
      await Future<void>.delayed(const Duration(milliseconds: 2500));

      expect(
        sw.exceptions,
        isEmpty,
        reason: 'uncaught exceptions during service-worker boot',
      );
      expect(
        sw.consoleErrors,
        isEmpty,
        reason: 'console.error output during service-worker boot',
      );
    },
  );

  test('AC2: faAgent is present, booted, and selfTest() passes', () async {
    final sw = await chrome.attachServiceWorker();

    final agentType = await sw.evaluate('typeof globalThis.faAgent');
    expect(agentType, 'object');

    final state =
        await sw.evaluate('globalThis.faAgent.getState()', awaitPromise: true)
            as Map<dynamic, dynamic>;
    expect(state['booted'], true);

    final selfTest =
        await sw.evaluate('globalThis.faAgent.selfTest()', awaitPromise: true)
            as Map<dynamic, dynamic>;
    expect(
      selfTest['ok'],
      true,
      reason: 'selfTest transcript: ${selfTest['transcript']}',
    );
    final transcript = (selfTest['transcript'] as List).cast<Map>();
    expect(
      transcript.any(
        (m) =>
            m['role'] == 'toolResult' &&
            m['toolName'] == 'browser_navigate' &&
            m['isError'] != true,
      ),
      true,
      reason: 'the scripted navigate tool call must execute successfully',
    );
  });
}
