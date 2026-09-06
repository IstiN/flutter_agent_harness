// Offscreen documents + external entry points (issue #30, IT-B3/IT-B4):
// OffscreenManager's lifecycle and lifetime cap on the injected clock, the
// chunked() slicing math, E22 degrade paths, and EntryPointHub's
// normalization / buffering / delivery tagging. FakeChrome's event streams
// are synchronous broadcast controllers, so no pump is needed anywhere.
import 'dart:async';

import 'package:test/test.dart';

import '../src/chrome_api.dart' hide OmniboxInput;
import '../src/background/entry_points.dart';
import '../src/background/offscreen.dart';
import '../src/fake_chrome.dart';

/// Facade stub whose createDocument always fails with a non-reason code —
/// proves the manager surfaces the facade's code verbatim (E22).
final class _BrokenOffscreen implements OffscreenApi {
  @override
  Future<void> createDocument({
    required String url,
    required Set<String> reasons,
    required String justification,
  }) async {
    throw ChromeApiException('quota_exceeded', 'offscreen budget exhausted');
  }

  @override
  Future<void> closeDocument() async {}

  @override
  Future<bool> hasDocument() async => false;
}

void main() {
  group('IT-B3: OffscreenManager (offscreen documents, E22)', () {
    test('IT-B3: open sets hasDocument; invalid reason degrades with the '
        'facade code', () async {
      final chrome = FakeChrome();
      final manager = OffscreenManager(chrome.offscreen);
      expect(manager.hasDocument, isFalse);

      await expectLater(
        manager.open(reason: 'NOT_IN_MV3_SET', justification: 'parse'),
        throwsA(
          isA<OffscreenUnavailableException>().having(
            (e) => e.code,
            'code',
            'invalid_reason',
          ),
        ),
      );
      expect(manager.hasDocument, isFalse);

      final handle = await manager.open(
        reason: 'DOM_PARSER',
        justification: 'parse a fetched page',
      );
      expect(manager.hasDocument, isTrue);
      expect(await chrome.offscreen.hasDocument(), isTrue);
      await handle.close();
    });

    test('IT-B3: within() success returns the work result and closes the '
        'document', () async {
      final chrome = FakeChrome();
      final manager = OffscreenManager(
        chrome.offscreen,
        delay: (_) => Future<void>.value(),
      );
      final handle = await manager.open(
        reason: 'DOM_SCRAPING',
        justification: 'research extraction',
      );

      final result = await handle.within(
        const Duration(minutes: 1),
        () async => 'payload',
      );

      expect(result, 'payload');
      expect(manager.hasDocument, isFalse);
      expect(await chrome.offscreen.hasDocument(), isFalse);
    });

    test('IT-B3: work exceeding the cap is aborted, throws with elapsed and '
        'reason, and the document closes', () async {
      var nowMs = 1000;
      final chrome = FakeChrome();
      final manager = OffscreenManager(
        chrome.offscreen,
        nowMs: () => nowMs,
        delay: (_) => Future<void>.value(),
      );
      final handle = await manager.open(
        reason: 'IFRAME_SCRIPTING',
        justification: 'read cross-frame dom',
      );
      final never = Completer<String>();
      final scoped = handle.within(
        const Duration(seconds: 30),
        () => never.future,
      );

      // Drive the injected clock past the cap while the work completer is
      // still pending — expiry must be detected without wall timers.
      nowMs = 1000 + 30 * 1000 + 1;

      await expectLater(
        scoped,
        throwsA(
          isA<OffscreenLifetimeExceededException>()
              .having((e) => e.elapsedMs, 'elapsedMs', 30 * 1000 + 1)
              .having((e) => e.reason, 'reason', 'IFRAME_SCRIPTING'),
        ),
      );
      expect(manager.hasDocument, isFalse);
      expect(await chrome.offscreen.hasDocument(), isFalse);
    });

    test('IT-B3: chunked() slicing — remainder, empty input, exact '
        'multiple', () async {
      final chunks = await OffscreenManager.chunked(
        List<int>.generate(10, (i) => i),
        3,
      ).toList();
      expect(chunks, [
        [0, 1, 2],
        [3, 4, 5],
        [6, 7, 8],
        [9],
      ]);

      expect(
        await OffscreenManager.chunked(const <int>[], 3).toList(),
        isEmpty,
      );
      expect(await OffscreenManager.chunked([1, 2, 3, 4], 2).toList(), [
        [1, 2],
        [3, 4],
      ]);
      await expectLater(
        OffscreenManager.chunked([1], 0).toList(),
        throwsArgumentError,
      );
    });

    test('IT-B3: close is idempotent — double close is safe', () async {
      final chrome = FakeChrome();
      final manager = OffscreenManager(chrome.offscreen);
      await manager.close(); // never opened: still safe

      final handle = await manager.open(
        reason: 'AUDIO_PLAYBACK',
        justification: 'play result audio',
      );
      await handle.close();
      await handle.close();

      expect(manager.hasDocument, isFalse);
      expect(await chrome.offscreen.hasDocument(), isFalse);
    });

    test('IT-B3: createDocument failure degrades to '
        'OffscreenUnavailableException with the facade code', () async {
      final manager = OffscreenManager(_BrokenOffscreen());

      await expectLater(
        manager.open(reason: 'DOM_PARSER', justification: 'parse'),
        throwsA(
          isA<OffscreenUnavailableException>().having(
            (e) => e.code,
            'code',
            'quota_exceeded',
          ),
        ),
      );
      expect(manager.hasDocument, isFalse);
    });

    test('IT-B3: a document leaked by a previous run is adopted, not a '
        'wedge', () async {
      final chrome = FakeChrome();
      await chrome.offscreen.createDocument(
        url: 'offscreen.html',
        reasons: {'DOM_PARSER'},
        justification: 'previous service-worker life',
      );

      final manager = OffscreenManager(chrome.offscreen);
      final handle = await manager.open(
        reason: 'DOM_PARSER',
        justification: 'new run',
      );
      expect(manager.hasDocument, isTrue);
      await handle.close();
      expect(await chrome.offscreen.hasDocument(), isFalse);
    });
  });

  group('IT-B4: EntryPointHub (external entry points, E24)', () {
    test('IT-B4: omnibox entry strips the fa keyword and delivers one '
        'OmniboxInput', () async {
      final chrome = FakeChrome();
      final hub = EntryPointHub(chrome);
      final inputs = <ExternalInput>[];
      final subscription = hub.inputs.listen(inputs.add);

      await chrome.enterOmnibox('fa check this');

      expect(inputs, hasLength(1));
      final input = inputs.single;
      expect(input, isA<OmniboxInput>());
      expect(input.text, 'check this');
      expect(input.source, 'omnibox');
      expect(input.delivery, DeliveryMode.queued);

      // Non-keyword input passes through untouched.
      await chrome.enterOmnibox('no keyword here');
      expect((inputs.last as OmniboxInput).text, 'no keyword here');

      await subscription.cancel();
      await hub.dispose();
    });

    test('IT-B4: command hotkey becomes a CommandInput', () async {
      final chrome = FakeChrome();
      final hub = EntryPointHub(chrome);
      final inputs = <ExternalInput>[];
      final subscription = hub.inputs.listen(inputs.add);

      await chrome.pressCommand('ask-fa');

      expect(inputs, hasLength(1));
      final input = inputs.single;
      expect(input, isA<CommandInput>());
      expect((input as CommandInput).commandName, 'ask-fa');
      expect(input.source, 'command');
      expect(input.text, 'ask-fa');

      await subscription.cancel();
      await hub.dispose();
    });

    test('IT-B4: context-menu click on a selection carries selectionText, '
        'pageUrl and the untrusted marker', () async {
      final chrome = FakeChrome();
      final hub = EntryPointHub(chrome);
      final inputs = <ExternalInput>[];
      final subscription = hub.inputs.listen(inputs.add);
      await chrome.contextMenus.create(
        id: 'ask-fa-about',
        title: 'Ask fa about "%s"',
        contexts: ['selection'],
      );

      await chrome.clickMenu(
        menuItemId: 'ask-fa-about',
        selectionText: 'tariff ruling',
        pageUrl: 'https://example.gov/hts/chapter-99',
      );

      expect(inputs, hasLength(1));
      final input = inputs.single as ContextMenuInput;
      expect(input.menuItem, 'ask-fa-about');
      expect(input.selectionText, 'tariff ruling');
      expect(input.pageUrl, 'https://example.gov/hts/chapter-99');
      expect(input.text, 'tariff ruling');
      expect(input.source, 'context_menu');
      expect(input.pageContext['untrusted'], isTrue);
      expect(input.pageContext['selectionText'], 'tariff ruling');
      expect(
        input.pageContext['pageUrl'],
        'https://example.gov/hts/chapter-99',
      );

      await subscription.cancel();
      await hub.dispose();
    });

    test('IT-B4: events fired before any listener attach are buffered, '
        'replayed in order, and never duplicated', () async {
      final chrome = FakeChrome();
      final hub = EntryPointHub(chrome);

      // Fire before anyone listens.
      await chrome.pressCommand('ask-fa');
      await chrome.enterOmnibox('fa second');

      final first = <ExternalInput>[];
      hub.inputs.listen(first.add); // replay happens inside listen()
      expect(first, hasLength(2));
      expect(first[0], isA<CommandInput>());
      expect((first[1] as OmniboxInput).text, 'second');

      // A late listener gets no replay — the buffered events stay at one
      // delivery total.
      final second = <ExternalInput>[];
      hub.inputs.listen(second.add);
      expect(second, isEmpty);

      // Live delivery reaches both listeners, each exactly once.
      await chrome.pressCommand('ask-fa');
      expect(first, hasLength(3));
      expect(second, hasLength(1));

      await hub.dispose();
    });

    test('IT-B4: setActive tags delivery — steer during a run, queued '
        'after', () async {
      final chrome = FakeChrome();
      final hub = EntryPointHub(chrome);
      final inputs = <ExternalInput>[];
      final subscription = hub.inputs.listen(inputs.add);

      hub.setActive(true);
      expect(hub.hasActiveRun, isTrue);
      await chrome.pressCommand('ask-fa');
      expect(inputs.single.delivery, DeliveryMode.steer);

      hub.setActive(false);
      await chrome.pressCommand('ask-fa');
      expect(inputs.last.delivery, DeliveryMode.queued);

      await subscription.cancel();
      await hub.dispose();
    });

    test('IT-B4: every event across all three entries is delivered exactly '
        'once', () async {
      final chrome = FakeChrome();
      final hub = EntryPointHub(chrome);
      final seen = <ExternalInput>[];
      final subscription = hub.inputs.listen(seen.add);
      await chrome.contextMenus.create(
        id: 'm',
        title: 'Ask fa',
        contexts: ['selection'],
      );

      await chrome.pressCommand('ask-fa');
      await chrome.enterOmnibox('fa one');
      await chrome.clickMenu(
        menuItemId: 'm',
        selectionText: 'sel',
        pageUrl: 'https://x.test/p',
      );
      await chrome.pressCommand('ask-fa');
      await chrome.enterOmnibox('fa two');

      expect(seen, hasLength(5));
      expect(
        [for (final input in seen) input.source],
        ['command', 'omnibox', 'context_menu', 'command', 'omnibox'],
        reason: 'each of the five triggers delivered exactly once, in order',
      );

      await subscription.cancel();
      await hub.dispose();
    });
  });
}
