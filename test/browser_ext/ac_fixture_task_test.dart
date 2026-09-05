// AC3 + AC4 + AC5 + AC16 + AC17 — the browser-op contract against the real
// fixture app (test/browser_ext/fixture/), driven through the extension
// service worker dispatcher (faSw.dispatch):
//
//   AC3:  navigate/read_dom/click/type/select/press_key/wait_for work end to
//         end on a real page (counter, form greeting, SPA pushState route).
//   AC4:  screenshot returns a non-trivial PNG (magic bytes + size).
//   AC5:  chrome:// pages are refused with code `restricted_page`.
//   AC16: trusted clicks carry path `cdp` and produce isTrusted events in
//         the page (window.__events); the dom path stays path `dom` /
//         isTrusted false.
//   AC17: agent-opened tabs land in the labelled task group and task_end
//         closes ONLY them; a user tab (CDP-opened) survives.
//
// Requires a REAL Chrome and a prior scripts/build_browser_ext.sh run (see
// ac_load_and_agent_test.dart). No Chrome → loud ChromeLaunchException; the
// `integration` tag keeps this out of default runs.
@Tags(['integration'])
@TestOn('vm')
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'chrome_driver.dart';

HeadlessChrome? _chrome;
FixtureServer? _fixture;

/// Non-null once setUpAll succeeded; tests only run after that.
HeadlessChrome get chrome => _chrome!;
FixtureServer get fixture => _fixture!;
late String userTargetId; // AC17: opened via CDP, never agent-tracked.

void main() {
  setUpAll(() async {
    _chrome = await HeadlessChrome.launch();
    _fixture = FixtureServer(
      Directory('test/browser_ext/fixture').resolveSymbolicLinksSync(),
    );
    await _fixture!.start();
    userTargetId = (await chrome.openTab('about:blank'))['targetId'] as String;
    // A task id makes ops.navigate TRACK + GROUP the tabs it opens (AC17);
    // without one the SW records nothing — this is the same seam the
    // bridge-connected flow exercises via beginTask on `connected`.
    await evaluateInServiceWorker(
      chrome,
      "globalThis.faSw.beginTask('ci-ac17')",
      awaitPromise: true,
    );
  });

  tearDownAll(() async {
    await _chrome?.dispose();
    await _fixture?.stop();
  });

  /// The tab ops.navigate opened (the only fixture page besides nothing
  /// else — the user tab is about:blank).
  Future<String> agentPageTargetId() async {
    final target = await chrome.waitForTarget(
      (t) =>
          t['type'] == 'page' &&
          (t['url'] as String? ?? '').startsWith(fixture.url),
    );
    return target['id'] as String;
  }

  /// Evaluates [expression] in the fixture page's main world.
  Future<dynamic> pageEvaluate(
    String expression, {
    bool awaitPromise = false,
  }) async {
    final session = await chrome.attachToTarget(await agentPageTargetId());
    return session.evaluate(expression, awaitPromise: awaitPromise);
  }

  test(
    'AC3: navigate → read_dom → click → type → select → press → wait_for',
    () async {
      // navigate opens a TRACKED tab (task started in setUpAll).
      final nav = await dispatchOp(chrome, 'navigate', {'url': fixture.url});
      expect(nav['ok'], true, reason: '${nav['error']}');
      final tabId = (nav['result'] as Map)['tabId'];

      final dom = await dispatchOp(chrome, 'read_dom', {'tabId': tabId});
      expect(dom['ok'], true, reason: '${dom['error']}');
      expect((dom['result'] as Map)['dom'] as String, contains('#count'));

      final click = await dispatchOp(chrome, 'click', {
        'tabId': tabId,
        'selector': '#counter',
      });
      expect(click['ok'], true, reason: '${click['error']}');
      expect((click['result'] as Map)['path'], 'dom'); // AC16 dom-path pin.
      final count = await pageEvaluate(
        "document.getElementById('count').textContent",
      );
      expect(count, '1');

      final type = await dispatchOp(chrome, 'type', {
        'tabId': tabId,
        'selector': '#name',
        'text': 'Ada',
        'submit': true,
      });
      expect(type['ok'], true, reason: '${type['error']}');
      final greeting = await pageEvaluate(
        "document.getElementById('greeting').textContent",
      );
      expect(greeting, contains('Ada'));

      final select = await dispatchOp(chrome, 'select', {
        'tabId': tabId,
        'selector': '#color',
        'value': 'blue',
      });
      expect(select['ok'], true, reason: '${select['error']}');
      expect(
        await pageEvaluate("document.getElementById('color').value"),
        'blue',
      );

      final press = await dispatchOp(chrome, 'press_key', {
        'tabId': tabId,
        'key': 'Enter',
      });
      expect(press['ok'], true, reason: '${press['error']}');

      final wait = await dispatchOp(chrome, 'wait_for', {
        'tabId': tabId,
        'text': 'Hello',
      });
      expect(wait['ok'], true, reason: '${wait['error']}');

      // Fixture SPA route: dom click on the router link pushes /route2.
      final route = await dispatchOp(chrome, 'click', {
        'tabId': tabId,
        'selector': '#router',
      });
      expect(route['ok'], true, reason: '${route['error']}');
      expect(await pageEvaluate('location.pathname'), '/route2');
      expect(
        await pageEvaluate(
          "document.getElementById('route-marker').textContent",
        ),
        contains('/route2'),
      );
    },
  );

  test('AC4: screenshot returns a non-trivial PNG', () async {
    final tabs = await dispatchOp(chrome, 'tabs');
    final tabId = (tabs['result'] as Map)['tabs'].firstWhere(
      (t) => (t['url'] as String).startsWith(fixture.url),
    )['id'];

    final shot = await dispatchOp(chrome, 'screenshot', {
      'tabId': tabId,
      'trusted': true, // CDP path: works on a background tab, no activation.
    });
    expect(shot['ok'], true, reason: '${shot['error']}');
    expect((shot['result'] as Map)['path'], 'cdp');

    final png = base64Decode((shot['result'] as Map)['pngBase64'] as String);
    expect(png.length, greaterThan(1000), reason: 'PNG suspiciously small');
    expect(
      [png[0], png[1], png[2], png[3]],
      [0x89, 0x50, 0x4E, 0x47],
      reason: 'not a PNG header',
    );
  });

  test('AC5: chrome:// navigation is refused with restricted_page', () async {
    final res = await dispatchOp(chrome, 'navigate', {
      'url': 'chrome://version',
    });
    expect(res['ok'], false);
    expect(res['code'], 'restricted_page');
  });

  test('AC16: trusted click produces isTrusted events (cdp path)', () async {
    final tabs = await dispatchOp(chrome, 'tabs');
    final tabId = (tabs['result'] as Map)['tabs'].firstWhere(
      (t) => (t['url'] as String).startsWith(fixture.url),
    )['id'];
    final before = await pageEvaluate('window.__events.length');

    final trusted = await dispatchOp(chrome, 'click', {
      'tabId': tabId,
      'selector': '#counter',
      'trusted': true,
    });
    expect(trusted['ok'], true, reason: '${trusted['error']}');
    expect((trusted['result'] as Map)['path'], 'cdp');

    final last =
        await pageEvaluate('window.__events[window.__events.length - 1]')
            as Map;
    expect(
      last['trusted'],
      true,
      reason: 'chrome.debugger input must be indistinguishable from real',
    );
    expect(last['target'], 'counter');
    expect(await pageEvaluate('window.__events.length'), before + 1);
    // The trusted click really fired the handler: counter advanced again.
    expect(
      await pageEvaluate("document.getElementById('count').textContent"),
      '2',
    );
  });

  test('AC17: task_end closes agent tabs, user tab survives', () async {
    final tabs = await dispatchOp(chrome, 'tabs');
    final list = (tabs['result'] as Map)['tabs'] as List;
    final agentTab = list.firstWhere(
      (t) => (t['url'] as String).startsWith(fixture.url),
    );
    final userTab = list.firstWhere((t) => t['id'] != agentTab['id']);

    // Agent tab sits in the labelled task group; the user tab is ungrouped.
    expect(agentTab['groupId'] as int, greaterThanOrEqualTo(0));
    expect(userTab['groupId'], -1);
    final groups =
        await evaluateInServiceWorker(
              chrome,
              'chrome.tabGroups.query({})',
              awaitPromise: true,
            )
            as List;
    expect(
      groups.map((g) => g['title'] as String),
      contains(startsWith('fa — ')),
      reason: 'task group must carry the fa — label',
    );

    final end = await dispatchOp(chrome, 'task_end');
    expect(end['ok'], true, reason: '${end['error']}');

    // Agent tab is gone; the CDP-opened user tab outlives the task.
    await pollUntil(
      () => chrome.jsonList(),
      (targets) => !targets.any(
        (t) =>
            t['type'] == 'page' &&
            (t['url'] as String? ?? '').startsWith(fixture.url),
      ),
      description: 'agent tab closed by task_end',
    );
    final survivors = await chrome.jsonList();
    expect(
      survivors.any((t) => t['id'] == userTargetId),
      true,
      reason: 'the user tab must survive task_end (AC17)',
    );
  });
}
