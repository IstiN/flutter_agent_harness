// FakeChrome smoke coverage, one group per ChromeApi sub-facade (issue
// #30): the tab CRUD→group→close roundtrip asserting every Tab field, the
// window lifecycle, sessions close→restore, the scripted/CDP canned-answer
// paths (recorded calls, E2 serialization guard), CRUD for history,
// bookmarks, downloads and cookies, the storage quota, clock-driven
// alarms, permission-denied notifications, the badge, offscreen reason
// validation + lifecycle, the driven entry streams, and system/identity.
//
// Sync broadcast events mean no await-flush: after an awaited drive the
// listener lists are already populated.
import 'package:test/test.dart';

// The package has no lib/ — the SW entry compiles src/ directly.
import '../src/chrome_api.dart';
import '../src/fake_chrome.dart';

/// Matches a ChromeApiException by its stable code (ops.js vocabulary).
Matcher coded(String code) =>
    isA<ChromeApiException>().having((e) => e.code, 'code', code);

BookmarkNode? _find(List<BookmarkNode> nodes, String id) {
  for (final n in nodes) {
    if (n.id == id) return n;
    final hit = _find(n.children, id);
    if (hit != null) return hit;
  }
  return null;
}

void main() {
  group('tabs', () {
    test(
      'create→query→update→group→move→reload→discard→close roundtrip',
      () async {
        final c = FakeChrome(clock: () => 1000);

        // Every Tab field, straight off create.
        final a = await c.tabs.create(url: 'https://example.com/a');
        expect(a.id, 1);
        expect(a.url, 'https://example.com/a');
        expect(a.title, 'https://example.com/a');
        expect(a.pinned, false);
        expect(a.muted, false);
        expect(a.audible, false);
        expect(a.groupId, isNull);
        expect(a.windowId, 1);
        expect(a.active, true);
        expect(a.favIconUrl, isNull);
        expect(a.discarded, false);

        final b = await c.tabs.create(
          url: 'https://example.com/b',
          active: false,
          pinned: true,
          index: 0,
        );
        expect(b.active, false);
        expect(b.pinned, true);
        expect(b.windowId, 1);

        expect((await c.tabs.get(1)).id, 1);
        await expectLater(c.tabs.get(99), throwsA(coded('no_tab')));

        // Chrome match patterns: * wildcard, exact without.
        expect(
          (await c.tabs.query(url: 'https://example.com/*')).map((t) => t.id),
          [2, 1],
        );
        expect((await c.tabs.query(url: 'https://example.com/a')).single.id, 1);
        expect((await c.tabs.query(active: true)).map((t) => t.id), [1]);
        expect((await c.tabs.query(pinned: true)).map((t) => t.id).toSet(), {
          2,
        });

        final upd = await c.tabs.update(1, pinned: true, muted: true);
        expect(upd.pinned, true);
        expect(upd.muted, true);
        expect(upd.audible, false);
        expect((await c.tabs.query(pinned: true)).map((t) => t.id).toSet(), {
          1,
          2,
        });

        final gid = await c.tabs.group(
          tabIds: [1, 2],
          title: 'work',
          color: 'blue',
        );
        final g = (await c.groups.query(title: 'work')).single;
        expect(g.id, gid);
        expect(g.color, 'blue');
        expect(g.windowId, 1);
        expect((await c.tabs.get(2)).groupId, gid);
        expect((await c.groups.update(gid, title: 'deep')).title, 'deep');
        await expectLater(c.tabs.group(tabIds: [99]), throwsA(coded('no_tab')));

        // Order before move: [2, 1] (b was inserted at index 0). Move 1 to front.
        final moved = await c.tabs.move(1, index: 0);
        expect((await c.tabs.query()).map((t) => t.id), [1, 2]);
        expect(moved.windowId, 1);

        final reloaded = await c.tabs.reload(1, bypassCache: true);
        expect(reloaded.url, 'https://example.com/a');

        final dup = await c.tabs.duplicate(2);
        expect(dup.url, 'https://example.com/b');
        expect(dup.id, isNot(2));
        expect(dup.groupId, gid);

        await c.tabs.ungroup([1]);
        expect((await c.tabs.get(1)).groupId, isNull);

        final discarded = await c.tabs.discard(dup.id);
        expect(discarded.discarded, true);
        expect(discarded.audible, false);

        await c.tabs.close(1);
        await expectLater(c.tabs.get(1), throwsA(coded('no_tab')));
        await c.groups.close(gid);
        await expectLater(c.tabs.get(2), throwsA(coded('no_tab')));
        expect(await c.groups.query(title: 'deep'), isEmpty);
      },
    );

    test('lifecycle streams emit create/update/close', () async {
      final c = FakeChrome();
      final created = <Tab>[];
      final removed = <TabRemoved>[];
      final updated = <TabUpdated>[];
      c.tabs.onCreated.listen(created.add);
      c.tabs.onRemoved.listen(removed.add);
      c.tabs.onUpdated.listen(updated.add);

      final t = await c.tabs.create(url: 'https://e.dev/1');
      await c.tabs.update(t.id, url: 'https://e.dev/2');
      await c.tabs.close(t.id);

      expect(created.single.id, t.id);
      expect(removed.single.tabId, t.id);
      expect(removed.single.windowId, 1);
      expect(removed.single.isWindowClosing, false);
      expect(updated.single.tabId, t.id);
      expect(updated.single.changeInfo['url'], 'https://e.dev/2');
      expect(updated.single.changeInfo['status'], 'complete');
    });
  });

  group('windows', () {
    test('create→update(state)→close', () async {
      final c = FakeChrome();
      final w = await c.windows.create(
        url: 'https://w.dev/a',
        width: 800,
        height: 600,
      );
      expect(w.id, 1);
      expect(w.type, 'normal');
      expect(w.state, 'normal');
      expect(w.focused, true);
      expect(w.left, 0);
      expect(w.top, 0);
      expect(w.incognito, false);
      expect(w.tabIds, hasLength(1));
      final tab = await c.tabs.get(w.tabIds.single);
      expect(tab.url, 'https://w.dev/a');
      expect(tab.windowId, w.id);

      final p = await c.windows.create(
        type: 'popup',
        state: 'minimized',
        url: 'https://w.dev/b',
      );
      expect(p.type, 'popup');
      expect(p.state, 'minimized');
      expect(p.focused, true); // focus followed the new window

      final up = await c.windows.update(
        w.id,
        state: 'maximized',
        focused: true,
      );
      expect(up.state, 'maximized');
      expect(up.focused, true);
      expect((await c.windows.getAll()).map((x) => x.id).toSet(), {w.id, p.id});
      // currentWindow follows focus
      expect(
        (await c.tabs.query(
          currentWindow: true,
        )).every((t) => t.windowId == w.id),
        isTrue,
      );

      await c.windows.close(w.id);
      await expectLater(c.windows.get(w.id), throwsA(coded('no_window')));
      await expectLater(c.tabs.get(w.tabIds.single), throwsA(coded('no_tab')));
    });

    test('closing a window lands one restorable window session', () async {
      final c = FakeChrome(clock: () => 9000);
      final w = await c.windows.create(url: 'https://w.dev/only');
      await c.windows.close(w.id);
      final closed = await c.sessions.getRecentlyClosed();
      expect(closed.single.window, isNotNull);
      expect(closed.single.tab, isNull);
      final r = await c.sessions.restore(closed.single.sessionId);
      expect(r.window, isNotNull);
      expect(r.window!.tabIds, hasLength(1));
      expect(
        (await c.tabs.get(r.window!.tabIds.single)).url,
        'https://w.dev/only',
      );
    });
  });

  group('sessions', () {
    test(
      'close a tab → getRecentlyClosed → restore returns a live tab',
      () async {
        final c = FakeChrome(clock: () => 5000);
        final t = await c.tabs.create(url: 'https://a.dev/x');
        await c.tabs.close(t.id);

        final closed = await c.sessions.getRecentlyClosed();
        expect(closed, hasLength(1));
        final e = closed.single;
        expect(e.tab!.url, 'https://a.dev/x');
        expect(e.lastModified, 5); // chrome lastModified is seconds

        final r = await c.sessions.restore(e.sessionId);
        expect(r.tab, isNotNull);
        expect(r.tab!.discarded, false);
        final live = await c.tabs.get(r.tab!.id);
        expect(live.url, 'https://a.dev/x');
        expect(live.active, true);

        // The session was consumed: restoring it again is a coded error.
        await expectLater(
          c.sessions.restore(e.sessionId),
          throwsA(coded('no_session')),
        );
      },
    );
  });

  group('scripting', () {
    test(
      'MAIN-world call recorded with args, canned result surfaces',
      () async {
        final c = FakeChrome(
          resultsFor: (src, args) => {'echo': args.first, 'srcLen': src.length},
        );
        final tab = await c.tabs.create(url: 'https://s.dev/p');

        final res = await c.scripting.executeScript(
          tabId: tab.id,
          world: 'MAIN',
          funcSource: '() => document.title',
          args: ['hi'],
        );
        expect(res, hasLength(1));
        expect(res.single.frameId, 0);
        expect(res.single.result, {'echo': 'hi', 'srcLen': 20});

        final call = c.scriptCalls.single;
        expect(call.tabId, tab.id);
        expect(call.world, 'MAIN');
        expect(call.funcSource, '() => document.title');
        expect(call.args, ['hi']);

        // Default canned answer with no injectable.
        final plain = FakeChrome();
        await plain.tabs.create(url: 'https://s.dev/q');
        final res2 = await plain.scripting.executeScript(
          tabId: 1,
          funcSource: '() => 1',
        );
        expect(res2.single.result, {'recorded': true});
      },
    );

    test('non-serializable result → result_not_serializable (E2)', () async {
      final c = FakeChrome(resultsFor: (_, _) => DateTime.now());
      await c.tabs.create(url: 'https://s.dev/p');
      await expectLater(
        c.scripting.executeScript(tabId: 1, funcSource: '() => new Date()'),
        throwsA(coded('result_not_serializable')),
      );
    });

    test('insertCSS records the call', () async {
      final c = FakeChrome();
      await c.tabs.create(url: 'https://s.dev/p');
      await c.scripting.insertCSS(tabId: 1, css: 'body { color: red }');
      final call = c.cssCalls.single;
      expect(call.tabId, 1);
      expect(call.css, 'body { color: red }');
      expect(call.allFrames, false);
      await expectLater(
        c.scripting.insertCSS(tabId: 42, css: 'a{}'),
        throwsA(coded('no_tab')),
      );
    });
  });

  group('debugger', () {
    test('CDP passthrough with attach lifecycle', () async {
      final c = FakeChrome(
        cdpResponder: (method, params) => method == 'Runtime.evaluate'
            ? {
                'result': {'type': 'number', 'value': 42},
              }
            : {'ok': true},
      );
      await c.tabs.create(url: 'https://d.dev/p');

      await expectLater(
        c.debugger.sendCommand(1, 'Runtime.evaluate'),
        throwsA(coded('not_attached')),
      );
      await c.debugger.attach(1, requiredVersion: '1.3');
      await expectLater(
        c.debugger.attach(1),
        throwsA(coded('already_attached')),
      );

      final out = await c.debugger.sendCommand(1, 'Runtime.evaluate', {
        'expression': '1+1',
      });
      expect(out, {
        'result': {'type': 'number', 'value': 42},
      });
      final call = c.cdpCalls.single;
      expect(call.tabId, 1);
      expect(call.method, 'Runtime.evaluate');
      expect(call.params, {'expression': '1+1'});

      await c.debugger.detach(1);
      await expectLater(
        c.debugger.sendCommand(1, 'Page.captureScreenshot'),
        throwsA(coded('not_attached')),
      );
    });
  });

  group('history', () {
    test('search by text, time window and maxResults', () async {
      final c = FakeChrome(clock: () => 10000);
      c.seedHistory(url: 'https://docs.dev/dap', title: 'DAP guide');
      c.seedHistory(url: 'https://mail.dev/inbox', title: 'Mail');

      final hit = await c.history.search(text: 'dap');
      expect(hit.single.url, 'https://docs.dev/dap');
      expect(hit.single.title, 'DAP guide');
      expect(hit.single.id, isNotEmpty);
      expect(hit.single.lastVisitTs, 10000);

      expect((await c.history.search(text: '')).length, 2);
      expect((await c.history.search(text: '', maxResults: 1)), hasLength(1));
      expect(await c.history.search(text: '', startTime: 10001), isEmpty);
      expect(await c.history.search(text: '', endTime: 9999), isEmpty);
    });
  });

  group('bookmarks', () {
    test('create/update/move/remove over seeded roots', () async {
      final c = FakeChrome();
      final roots = await c.bookmarks.tree();
      expect(roots.map((r) => r.id), ['1', '2']);

      final b = await c.bookmarks.create(
        title: 'Spec',
        url: 'https://spec.dev/x',
      );
      expect(b.id, isNotEmpty);
      expect(b.url, 'https://spec.dev/x');
      final folder = await c.bookmarks.create(title: 'Work');
      expect(folder.url, isNull);
      final nested = await c.bookmarks.create(
        parentId: folder.id,
        title: 'Inner',
        url: 'https://in.dev/',
      );

      final upd = await c.bookmarks.update(
        b.id,
        title: 'Spec v2',
        url: 'https://spec.dev/y',
      );
      expect(upd.title, 'Spec v2');
      expect(upd.url, 'https://spec.dev/y');

      await c.bookmarks.move(b.id, parentId: '2', index: 0);
      final other = (await c.bookmarks.tree()).firstWhere((r) => r.id == '2');
      expect(other.children.first.id, b.id);

      await c.bookmarks.remove(nested.id);
      final f2 = _find(await c.bookmarks.tree(), folder.id)!;
      expect(f2.children, isEmpty);

      await expectLater(c.bookmarks.remove('1'), throwsA(coded('bad_args')));
      await expectLater(
        c.bookmarks.update('zzz', title: 'x'),
        throwsA(coded('no_node')),
      );
      await expectLater(
        c.bookmarks.move(b.id, parentId: 'zzz'),
        throwsA(coded('no_node')),
      );
    });
  });

  group('downloads', () {
    test('download→search→pause→resume→cancel', () async {
      final c = FakeChrome();
      final id = await c.downloads.download(
        url: 'https://cdn.dev/a.bin',
        filename: 'a.bin',
      );
      final it = (await c.downloads.search(query: 'a.bin')).single;
      expect(it.id, id);
      expect(it.url, 'https://cdn.dev/a.bin');
      expect(it.filename, 'a.bin');
      expect(it.state, 'in_progress');
      expect(it.paused, false);

      await c.downloads.pause(id);
      expect((await c.downloads.search()).single.paused, true);
      await c.downloads.resume(id);
      expect((await c.downloads.search()).single.paused, false);

      await c.downloads.cancel(id);
      expect((await c.downloads.search()).single.state, 'interrupted');
      expect(await c.downloads.search(state: 'in_progress'), isEmpty);

      await expectLater(
        c.downloads.pause(id),
        throwsA(coded('not_in_progress')),
      );
      await expectLater(c.downloads.pause(999), throwsA(coded('no_download')));
    });
  });

  group('cookies', () {
    test('set/get/getAll/remove', () async {
      final c = FakeChrome();
      final set = await c.cookies.set(
        url: 'https://shop.dev/cart',
        name: 'sid',
        value: 'v1',
        secure: true,
        httpOnly: true,
      );
      expect(set.domain, 'shop.dev');
      expect(set.path, '/');
      expect(set.secure, true);
      expect(set.httpOnly, true);

      expect(
        (await c.cookies.get(url: 'https://shop.dev/cart', name: 'sid'))!.value,
        'v1',
      );
      await c.cookies.set(
        url: 'https://api.shop.dev/x',
        name: 'sid',
        value: 'v2',
      );

      expect(
        (await c.cookies.getAll(url: 'https://shop.dev/')).map((x) => x.value),
        ['v1'],
      );
      expect(
        (await c.cookies.getAll(
          domain: 'shop.dev',
        )).map((x) => x.value).toSet(),
        {'v1', 'v2'},
      );
      expect(await c.cookies.getAll(name: 'nope'), isEmpty);
      expect(
        await c.cookies.get(url: 'https://shop.dev/', name: 'ghost'),
        isNull,
      );

      await c.cookies.remove(url: 'https://shop.dev/', name: 'sid');
      expect(
        await c.cookies.get(url: 'https://shop.dev/', name: 'sid'),
        isNull,
      );
    });
  });

  group('storage', () {
    test('get/set/remove/clear + onChanged', () async {
      final c = FakeChrome();
      expect(c.storage.quotaBytes, defaultStorageQuotaBytes);
      final changes = <StorageChanged>[];
      c.storage.onChanged.listen(changes.add);

      await c.storage.set({'a': 1});
      await c.storage.set({'b': 'x'});
      expect(await c.storage.get(), {'a': 1, 'b': 'x'});
      expect(await c.storage.get(['a', 'zz']), {'a': 1});

      await c.storage.remove(['a']);
      expect(await c.storage.get(), {'b': 'x'});
      await c.storage.clear();
      expect(await c.storage.get(), isEmpty);

      expect(changes.map((ch) => ch.key).toList(), ['a', 'b', 'a', 'b']);
      expect(changes.last.oldValue, 'x');
      expect(changes.last.newValue, isNull);
    });

    test('quota exceeded raises quota_exceeded and keeps state', () async {
      final small = FakeChrome(clock: () => 0, quotaBytes: 32);
      expect(small.storage.quotaBytes, 32);
      await small.storage.set({'k': 'ok'});
      await expectLater(
        small.storage.set({'big': 'x' * 64}),
        throwsA(coded('quota_exceeded')),
      );
      expect(await small.storage.get(), {'k': 'ok'});
    });
  });

  group('alarms', () {
    test('create → advanceTo fires once, never twice at the same ts', () async {
      final c = FakeChrome(clock: () => 0);
      final fired = <Alarm>[];
      c.alarms.onAlarm.listen(fired.add);

      await c.alarms.create(name: 'tick', periodMinutes: 1);
      await c.advanceTo(60000);
      expect(fired, hasLength(1));
      expect(fired.single.name, 'tick');
      expect(fired.single.scheduledTs, 60000);

      await c.advanceTo(60000); // same ts again → no double fire
      expect(fired, hasLength(1));

      await c.advanceTo(120000);
      expect(fired, hasLength(2));
      expect(fired[1].scheduledTs, 120000);
      expect((await c.alarms.getAll()).single.scheduledTs, 180000);

      // One-shot when-alarm fires once and auto-clears.
      await c.alarms.create(name: 'once', whenMs: 150000);
      await c.advanceTo(150000);
      expect(fired.where((a) => a.name == 'once'), hasLength(1));
      expect((await c.alarms.getAll()).map((a) => a.name), ['tick']);

      expect(await c.alarms.clear('tick'), true);
      expect(await c.alarms.clear('tick'), false);
      await expectLater(
        c.alarms.create(name: 'bad'),
        throwsA(coded('bad_args')),
      );
    });
  });

  group('notifications', () {
    test('denied permission → create returns false', () async {
      final denied = FakeChrome(notificationPermission: 'denied');
      expect(denied.notifications.permission, 'denied');
      expect(
        await denied.notifications.create(id: 'n1', title: 'T', message: 'M'),
        isFalse,
      );
      expect(await denied.notifications.clear('n1'), isFalse);

      final ok = FakeChrome();
      expect(ok.notifications.permission, 'granted');
      expect(
        await ok.notifications.create(
          id: 'n1',
          title: 'T',
          message: 'M',
          iconUrl: 'i.png',
        ),
        isTrue,
      );
      expect(await ok.notifications.clear('n1'), isTrue);
      expect(await ok.notifications.clear('n1'), isFalse);
    });
  });

  group('action', () {
    test('badge and title are recorded', () async {
      final c = FakeChrome();
      await c.action.setBadgeText('3');
      await c.action.setBadgeBackgroundColor('#ff0000');
      await c.action.setTitle('fa agent');
      expect(c.badgeText, '3');
      expect(c.badgeBackgroundColor, '#ff0000');
      expect(c.actionTitle, 'fa agent');
    });
  });

  group('offscreen', () {
    test('invalid reason rejected', () async {
      final c = FakeChrome();
      await expectLater(
        c.offscreen.createDocument(
          url: 'offscreen.html',
          reasons: {'NOT_A_REASON'},
          justification: 'because',
        ),
        throwsA(coded('invalid_reason')),
      );
      await expectLater(
        c.offscreen.createDocument(
          url: 'offscreen.html',
          reasons: {},
          justification: 'because',
        ),
        throwsA(coded('invalid_reason')),
      );
    });

    test('lifecycle create→hasDocument→close', () async {
      final c = FakeChrome();
      expect(await c.offscreen.hasDocument(), isFalse);
      await c.offscreen.createDocument(
        url: 'offscreen.html',
        reasons: {'AUDIO_PLAYBACK', 'DOM_SCRAPING'},
        justification: 'play tts',
      );
      expect(await c.offscreen.hasDocument(), isTrue);
      await expectLater(
        c.offscreen.createDocument(
          url: 'o2.html',
          reasons: {'TESTING'},
          justification: 'x',
        ),
        throwsA(coded('document_exists')),
      );
      await c.offscreen.closeDocument();
      expect(await c.offscreen.hasDocument(), isFalse);
      await expectLater(
        c.offscreen.closeDocument(),
        throwsA(coded('no_document')),
      );
    });
  });

  group('power + idle', () {
    test('keep-awake recorded, idle state driven', () async {
      final c = FakeChrome();
      final states = <String>[];
      c.idle.onStateChanged.listen(states.add);

      await c.power.requestKeepAwake('system');
      expect(c.keepAwakeLevel, 'system');
      await c.power.releaseKeepAwake();
      expect(c.keepAwakeLevel, isNull);
      await expectLater(
        c.power.requestKeepAwake('turbo'),
        throwsA(coded('bad_args')),
      );

      expect(await c.idle.queryState(15), 'active');
      await c.setIdleState('idle');
      expect(await c.idle.queryState(15), 'idle');
      expect(states.single, 'idle');
    });
  });

  group('entry streams', () {
    test(
      'contextMenus/omnibox/commands/webNavigation emit when driven',
      () async {
        final c = FakeChrome();
        final tab = await c.tabs.create(url: 'https://x.dev/p');
        final clicks = <MenuClick>[];
        final omni = <OmniboxInput>[];
        final cmds = <String>[];
        final navs = <NavCompleted>[];
        c.contextMenus.onClicked.listen(clicks.add);
        c.omnibox.onInputEntered.listen(omni.add);
        c.commands.onCommand.listen(cmds.add);
        c.webNavigation.onCompleted.listen(navs.add);

        await c.contextMenus.create(
          id: 'm1',
          title: 'Send to fa',
          contexts: ['selection'],
        );
        await c.clickMenu(
          menuItemId: 'm1',
          selectionText: 'hi',
          pageUrl: 'https://x.dev/p',
          tabId: tab.id,
        );
        expect(clicks.single.menuItemId, 'm1');
        expect(clicks.single.selectionText, 'hi');
        expect(clicks.single.pageUrl, 'https://x.dev/p');
        expect(clicks.single.tab!.id, tab.id);
        await expectLater(
          c.clickMenu(menuItemId: 'gone'),
          throwsA(coded('no_menu')),
        );
        await c.contextMenus.removeAll();
        await expectLater(
          c.clickMenu(menuItemId: 'm1'),
          throwsA(coded('no_menu')),
        );

        await c.enterOmnibox(
          'flutter hooks',
          disposition: 'new_foreground_tab',
        );
        expect(omni.single.text, 'flutter hooks');
        expect(omni.single.disposition, 'new_foreground_tab');

        await c.pressCommand('toggle-panel');
        expect(cmds.single, 'toggle-panel');

        await c.navCompleted(tabId: tab.id, url: 'https://x.dev/q', frameId: 2);
        expect(navs.single.tabId, tab.id);
        expect(navs.single.url, 'https://x.dev/q');
        expect(navs.single.frameId, 2);
      },
    );
  });

  group('system + identity', () {
    test('infos are non-null, auth flow returns the fixed redirect', () async {
      final c = FakeChrome();
      final cpu = await c.system.cpu();
      expect(cpu.arch, isNotEmpty);
      expect(cpu.numProcessors, greaterThan(0));
      expect(cpu.modelName, isNotEmpty);

      final mem = await c.system.memory();
      expect(mem.capacity, greaterThan(0));
      expect(mem.availableCapacity, lessThanOrEqualTo(mem.capacity));

      final st = await c.system.storage();
      expect(st.units, isNotEmpty);
      expect(st.units.single.capacity, greaterThan(0));

      final disp = await c.system.display();
      expect(disp.width, greaterThan(0));
      expect(disp.height, greaterThan(0));
      expect(disp.primary, isTrue);

      final redirect = await c.identity.launchWebAuthFlow(
        url: 'https://prov.example/authorize?x=1',
      );
      expect(redirect, contains('access_token'));
    });
  });
}
