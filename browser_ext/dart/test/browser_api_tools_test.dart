// BrowserApiToolSurface (browser_api_tools.dart): spec table (UT-T4),
// per-tool schema validation + happy path + coded error mapping over
// FakeChrome (UT-T1), the inject_js edge matrix — world whitelist,
// timeout/allFrames bounds, result budget, E2 structured errors and E3
// retryable mapping (UT-T5), restricted-page refusals with tab management
// still allowed (E1/E17), and the targeted refusals ('active_tab',
// 'no_longer_available', 'no_app_page'). Issue #30.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/src/agent/tool_registry.dart';
import 'package:flutter_agent_harness/src/approval/approval.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

import '../src/browser_api_tools.dart';
import '../src/chrome_api.dart';
import '../src/fake_chrome.dart';

/// Chrome that fails every call with the same coded error: lets the sweep
/// prove EVERY tool maps a raw ChromeApiException to a thrown
/// BrowserApiToolException (code rides the error, never a leak).
final class _ThrowingChrome implements ChromeApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw ChromeApiException('no_tab', 'no tab with id 0');
}

const _expectedNames = [
  'tabs_open',
  'tabs_close',
  'tabs_update',
  'tabs_query',
  'tabs_move',
  'tabs_group',
  'tabs_ungroup',
  'tabs_reload',
  'tabs_discard',
  'windows_open',
  'windows_update',
  'windows_close',
  'windows_list',
  'groups_update',
  'groups_close',
  'sessions_recent',
  'sessions_restore',
  'history_search',
  'bookmarks_list',
  'bookmarks_add',
  'bookmarks_update',
  'bookmarks_remove',
  'downloads_start',
  'downloads_search',
  'downloads_cancel',
  'cookies_get',
  'cookies_set',
  'cookies_remove',
  'inject_js',
  'inject_css',
  'cdp_eval',
  'page_screenshot',
  'app_screenshot',
  'nav_wait',
];

/// Minimal VALID args per tool: enough to pass validation so the call
/// reaches the (throwing) facade in the error-mapping sweep.
const _minArgs = <String, Map<String, Object?>>{
  'tabs_open': {'url': 'https://x.example/'},
  'tabs_close': {
    'tabIds': [1],
  },
  'tabs_update': {'tabId': 1},
  'tabs_query': {},
  'tabs_move': {'tabId': 1, 'index': 0},
  'tabs_group': {
    'tabIds': [1],
  },
  'tabs_ungroup': {
    'tabIds': [1],
  },
  'tabs_reload': {'tabId': 1},
  'tabs_discard': {'tabId': 1},
  'windows_open': {},
  'windows_update': {'windowId': 1},
  'windows_close': {'windowId': 1},
  'windows_list': {},
  'groups_update': {'groupId': 1},
  'groups_close': {'groupId': 1},
  'sessions_recent': {},
  'sessions_restore': {'sessionId': 's1'},
  'history_search': {'text': 'x'},
  'bookmarks_list': {},
  'bookmarks_add': {'title': 't', 'url': 'https://x.example/'},
  'bookmarks_update': {'id': '1'},
  'bookmarks_remove': {'id': '1'},
  'downloads_start': {'url': 'https://x.example/f.bin'},
  'downloads_search': {},
  'downloads_cancel': {'id': 1},
  'cookies_get': {'url': 'https://x.example/', 'name': 'c'},
  'cookies_set': {'url': 'https://x.example/', 'name': 'c', 'value': 'v'},
  'cookies_remove': {'url': 'https://x.example/', 'name': 'c'},
  'inject_js': {'tabId': 1, 'code': '1+1', 'world': 'ISOLATED'},
  'inject_css': {'tabId': 1, 'css': 'body{}'},
  'cdp_eval': {'tabId': 1, 'expression': '1'},
  'page_screenshot': {},
  'app_screenshot': {},
  'nav_wait': {'tabId': 1, 'timeoutMs': 1000},
};

ToolRegistry _reg(ChromeApi chrome) {
  final reg = ToolRegistry();
  registerBrowserApiTools(reg, chrome);
  return reg;
}

/// A registry wired to a FakeChrome with canned script/CDP answers.
(ToolRegistry, FakeChrome) _cannedReg({
  Object? Function(String funcSource, List<Object?> args)? resultsFor,
  Object? Function(String method, Map<String, Object?> params)? cdpResponder,
  int? resultBudget,
}) {
  final chrome = FakeChrome(resultsFor: resultsFor, cdpResponder: cdpResponder);
  final tools = BrowserApiToolSurface(
    chrome,
    resultBudget: resultBudget ?? defaultResultBudgetBytes,
  ).tools();
  return (ToolRegistry()..registerAll(tools), chrome);
}

Future<String> _run(
  ToolRegistry reg,
  String name, [
  Map<String, Object?> args = const {},
]) async {
  final result = await reg[name].execute(
    Map<String, dynamic>.of(args),
    null,
    null,
  );
  return result.content.whereType<TextContent>().map((c) => c.text).join('\n');
}

Map<String, Object?> _jsonOf(String text) =>
    jsonDecode(text) as Map<String, Object?>;

TypeMatcher<BrowserApiToolException> _err(String code) =>
    isA<BrowserApiToolException>().having((e) => e.code, 'code', code);

TypeMatcher<BrowserApiToolException> _errMsg(String code, Object message) =>
    _err(code).having((e) => e.message, 'message', message);

Object? _validArg(String prop, String type) {
  if (prop == 'world') return 'ISOLATED';
  return switch (type) {
    'string' => 'x',
    'integer' => 1,
    'boolean' => true,
    'array' => [1],
    _ => null,
  };
}

void main() {
  late FakeChrome chrome;
  late ToolRegistry reg;

  setUp(() {
    chrome = FakeChrome(clock: () => 1730000000000);
    reg = _reg(chrome);
  });

  // -------------------------------------------------------------------------
  group('specs table (UT-T4)', () {
    test('34 tools with the exact contracted names', () {
      final specs = browserApiToolSpecs();
      expect(specs.map((s) => s.name), unorderedEquals(_expectedNames));
      expect(specs.map((s) => s.name).toSet().length, 34);
    });

    test('every spec: tier, visibility core, alwaysPrompts, permissions', () {
      const reads = {
        'tabs_query',
        'windows_list',
        'sessions_recent',
        'history_search',
        'bookmarks_list',
        'downloads_search',
        'cookies_get',
        'nav_wait',
        'app_screenshot',
      };
      const execs = {'inject_js', 'cdp_eval', 'page_screenshot'};
      for (final s in browserApiToolSpecs()) {
        expect(
          s.tier,
          reads.contains(s.name)
              ? ApprovalTier.read
              : execs.contains(s.name)
              ? ApprovalTier.exec
              : ApprovalTier.write,
          reason: '${s.name}: wrong tier',
        );
        expect(s.visibility, BrowserToolVisibility.core, reason: s.name);
        expect(s.alwaysPrompts, s.name == 'inject_js', reason: s.name);
        expect(s.permissions, isNotEmpty, reason: s.name);
      }
      // The one always-prompting tool runs MAIN-world page code.
      expect(
        browserApiToolSpecs().firstWhere((s) => s.name == 'inject_js').tier,
        ApprovalTier.exec,
      );
    });

    test('registry contents match the spec table exactly (name + tier)', () {
      expect(
        reg.names.toSet(),
        browserApiToolSpecs().map((s) => s.name).toSet(),
      );
      expect(reg.length, 34);
      final specs = {for (final s in browserApiToolSpecs()) s.name: s};
      for (final tool in reg.agentTools) {
        expect(tool.tier, specs[tool.name]!.tier, reason: tool.name);
        expect(tool.name, isIn(_expectedNames));
      }
    });
  });

  // -------------------------------------------------------------------------
  group('schema validation sweep (UT-T1)', () {
    test('every tool: missing args → structured bad_args (or a mapped '
        'facade error when nothing is required), never a crash', () async {
      final throwReg = _reg(_ThrowingChrome());
      for (final spec in browserApiToolSpecs()) {
        final schema = throwReg[spec.name].parameters;
        final required = (schema['required']! as List).cast<String>();
        if (required.isEmpty) {
          await expectLater(
            _run(throwReg, spec.name),
            throwsA(_err('no_tab')),
            reason: '${spec.name}: {} should reach the facade',
          );
        } else {
          await expectLater(
            _run(throwReg, spec.name),
            throwsA(_err('bad_args')),
            reason: '${spec.name}: {} should fail validation',
          );
        }
      }
    });

    test('every tool: wrong-typed required args → error naming the '
        'argument', () async {
      final throwReg = _reg(_ThrowingChrome());
      for (final spec in browserApiToolSpecs()) {
        final schema = throwReg[spec.name].parameters;
        final required = (schema['required']! as List).cast<String>();
        final props = schema['properties']! as Map<String, Object?>;
        for (final prop in required) {
          final type = (props[prop]! as Map)['type']! as String;
          final wrong = switch (type) {
            'string' => 42,
            'integer' => 'nope',
            'boolean' => 'nope',
            'array' => 'nope',
            _ => Object(),
          };
          final args = <String, Object?>{
            for (final p in required)
              p: p == prop
                  ? wrong
                  : _validArg(p, (props[p]! as Map)['type']! as String),
          };
          await expectLater(
            _run(throwReg, spec.name, args),
            throwsA(
              isA<BrowserApiToolException>()
                  .having((e) => e.code, 'code', anyOf('bad_args', 'bad_world'))
                  .having((e) => e.message, 'message', contains(prop)),
            ),
            reason: '${spec.name}.$prop = $wrong',
          );
        }
      }
    });

    test('every tool maps a raw ChromeApiException to a thrown coded tool '
        'error — no leak', () async {
      final throwReg = _reg(_ThrowingChrome());
      for (final spec in browserApiToolSpecs()) {
        await expectLater(
          _run(throwReg, spec.name, _minArgs[spec.name]!),
          throwsA(
            isA<BrowserApiToolException>()
                .having((e) => e.code, 'code', 'no_tab')
                .having((e) => e.isRetryable, 'isRetryable', false),
          ),
          reason: spec.name,
        );
      }
    });
  });

  // -------------------------------------------------------------------------
  group('happy path per tool (UT-T1)', () {
    test('tabs_open', () async {
      final out = await _run(reg, 'tabs_open', {'url': 'https://a.example/'});
      expect(out, contains('opened tab'));
      expect(await chrome.tabs.query(url: 'https://a.example/'), hasLength(1));
    });

    test('tabs_close', () async {
      final a = await chrome.tabs.create(url: 'https://a.example/');
      final b = await chrome.tabs.create(url: 'https://b.example/');
      await _run(reg, 'tabs_close', {
        'tabIds': [a.id, b.id],
      });
      expect(await chrome.tabs.query(), isEmpty);
    });

    test('tabs_update', () async {
      final t = await chrome.tabs.create(url: 'https://a.example/');
      await _run(reg, 'tabs_update', {
        'tabId': t.id,
        'pinned': true,
        'muted': true,
      });
      final after = await chrome.tabs.get(t.id);
      expect(after.pinned, isTrue);
      expect(after.muted, isTrue);
    });

    test('tabs_query', () async {
      await chrome.tabs.create(url: 'https://a.example/page');
      await chrome.tabs.create(url: 'https://b.example/page');
      final out = await _run(reg, 'tabs_query', {'url': '*a.example*'});
      final list = jsonDecode(out) as List<Object?>;
      expect(list, hasLength(1));
      expect((list.single! as Map)['url'], 'https://a.example/page');
    });

    test('tabs_move', () async {
      final a = await chrome.tabs.create(url: 'https://a.example/');
      final b = await chrome.tabs.create(url: 'https://b.example/');
      await _run(reg, 'tabs_move', {'tabId': b.id, 'index': 0});
      final win = await chrome.windows.get(b.windowId);
      expect(win.tabIds.first, b.id);
      expect(win.tabIds, contains(a.id));
      expect(win.tabIds.last, a.id);
    });

    test('tabs_group', () async {
      final a = await chrome.tabs.create(url: 'https://a.example/');
      final b = await chrome.tabs.create(url: 'https://b.example/');
      final out = await _run(reg, 'tabs_group', {
        'tabIds': [a.id, b.id],
        'title': 'research',
        'color': 'blue',
      });
      expect(out, contains('group'));
      final groups = await chrome.groups.query(title: 'research');
      expect(groups, hasLength(1));
      expect(groups.single.color, 'blue');
      expect((await chrome.tabs.get(a.id)).groupId, groups.single.id);
    });

    test('tabs_ungroup', () async {
      final a = await chrome.tabs.create(url: 'https://a.example/');
      await chrome.tabs.group(tabIds: [a.id], title: 'g');
      await _run(reg, 'tabs_ungroup', {
        'tabIds': [a.id],
      });
      expect(await chrome.tabs.get(a.id).then((t) => t.groupId), isNull);
    });

    test('tabs_reload', () async {
      final a = await chrome.tabs.create(url: 'https://a.example/');
      final out = await _run(reg, 'tabs_reload', {
        'tabId': a.id,
        'bypassCache': true,
      });
      expect(out, contains('reloaded'));
    });

    test('tabs_discard (background tab)', () async {
      final a = await chrome.tabs.create(url: 'https://a.example/');
      await chrome.tabs.create(url: 'https://b.example/'); // becomes active
      await _run(reg, 'tabs_discard', {'tabId': a.id});
      expect((await chrome.tabs.get(a.id)).discarded, isTrue);
    });

    test('windows_open', () async {
      final before = await chrome.windows.getAll();
      await _run(reg, 'windows_open', {'url': 'https://a.example/'});
      final after = await chrome.windows.getAll();
      expect(after.length, before.length + 1);
    });

    test('windows_update', () async {
      await chrome.tabs.create(url: 'https://a.example/'); // ensures a window
      final w = (await chrome.windows.getAll()).first;
      await _run(reg, 'windows_update', {
        'windowId': w.id,
        'state': 'maximized',
      });
    });

    test('windows_close', () async {
      final w = await chrome.windows.create(url: 'https://a.example/');
      await _run(reg, 'windows_close', {'windowId': w.id});
      expect(
        (await chrome.windows.getAll()).map((x) => x.id),
        isNot(contains(w.id)),
      );
    });

    test('windows_list', () async {
      await chrome.tabs.create(url: 'https://a.example/'); // ensures a window
      final out = await _run(reg, 'windows_list');
      final list = jsonDecode(out) as List<Object?>;
      expect(list, isNotEmpty);
      expect((list.first! as Map)['tabIds'], isA<List>());
    });

    test('groups_update', () async {
      final a = await chrome.tabs.create(url: 'https://a.example/');
      final gid = await chrome.tabs.group(tabIds: [a.id]);
      await _run(reg, 'groups_update', {'groupId': gid, 'title': 'renamed'});
      final groups = await chrome.groups.query(title: 'renamed');
      expect(groups, hasLength(1));
      expect(groups.single.id, gid);
    });

    test('groups_close', () async {
      final a = await chrome.tabs.create(url: 'https://a.example/');
      final gid = await chrome.tabs.group(tabIds: [a.id]);
      await _run(reg, 'groups_close', {'groupId': gid});
      expect(await chrome.groups.query(), isEmpty);
      expect(await chrome.tabs.query(), isEmpty);
    });

    test('sessions_recent', () async {
      final a = await chrome.tabs.create(url: 'https://a.example/');
      await chrome.tabs.close(a.id);
      final out = await _run(reg, 'sessions_recent');
      final list = jsonDecode(out) as List<Object?>;
      expect(list, hasLength(1));
      expect(
        ((list.single! as Map)['tab']! as Map)['url'],
        'https://a.example/',
      );
    });

    test('sessions_restore', () async {
      final a = await chrome.tabs.create(url: 'https://a.example/');
      await chrome.tabs.close(a.id);
      final sessions = await chrome.sessions.getRecentlyClosed();
      final out = await _run(reg, 'sessions_restore', {
        'sessionId': sessions.single.sessionId,
      });
      final parsed = _jsonOf(out);
      expect(parsed['ok'], true);
      expect(
        ((parsed['restored']! as Map)['tab']! as Map)['url'],
        'https://a.example/',
      );
    });

    test('history_search', () async {
      chrome.seedHistory(
        url: 'https://docs.example/flutter',
        title: 'Flutter docs',
      );
      final out = await _run(reg, 'history_search', {'text': 'flutter'});
      expect(out, contains('https://docs.example/flutter'));
    });

    test('bookmarks_list', () async {
      await chrome.bookmarks.create(title: 'GH', url: 'https://github.com');
      final out = await _run(reg, 'bookmarks_list');
      expect(out, contains('https://github.com'));
    });

    test('bookmarks_add', () async {
      final out = await _run(reg, 'bookmarks_add', {
        'title': 'GH',
        'url': 'https://github.com',
        'parentId': '2',
      });
      expect(out, contains('added bookmark'));
      expect(
        await chrome.bookmarks.tree().then((t) => t[1].children.single.url),
        'https://github.com',
      );
    });

    test('bookmarks_update', () async {
      final n = await chrome.bookmarks.create(
        title: 'GH',
        url: 'https://github.com',
      );
      await _run(reg, 'bookmarks_update', {'id': n.id, 'title': 'GitHub'});
      final tree = await chrome.bookmarks.tree();
      expect(tree[0].children.single.title, 'GitHub');
    });

    test('bookmarks_remove', () async {
      final n = await chrome.bookmarks.create(
        title: 'GH',
        url: 'https://github.com',
      );
      await _run(reg, 'bookmarks_remove', {'id': n.id});
      final tree = await chrome.bookmarks.tree();
      expect(tree[0].children, isEmpty);
    });

    test('downloads_start', () async {
      final out = await _run(reg, 'downloads_start', {
        'url': 'https://x.example/f.bin',
      });
      expect(out, contains('started download'));
      expect(await chrome.downloads.search(query: 'f.bin'), hasLength(1));
    });

    test('downloads_search', () async {
      await chrome.downloads.download(url: 'https://x.example/f.bin');
      final out = await _run(reg, 'downloads_search', {'query': 'x.example'});
      final list = jsonDecode(out) as List<Object?>;
      expect(list, hasLength(1));
    });

    test('downloads_cancel', () async {
      final id = await chrome.downloads.download(
        url: 'https://x.example/f.bin',
      );
      await _run(reg, 'downloads_cancel', {'id': id});
      final items = await chrome.downloads.search();
      expect(items.single.state, 'interrupted');
    });

    test('cookies_get', () async {
      await chrome.cookies.set(
        url: 'https://x.example/',
        name: 'c',
        value: 'v',
      );
      final out = await _run(reg, 'cookies_get', {
        'url': 'https://x.example/',
        'name': 'c',
      });
      expect((_jsonOf(out)['cookie']! as Map)['value'], 'v');
      final missing = await _run(reg, 'cookies_get', {
        'url': 'https://x.example/',
        'name': 'nope',
      });
      expect(_jsonOf(missing)['cookie'], isNull);
    });

    test('cookies_set', () async {
      await _run(reg, 'cookies_set', {
        'url': 'https://x.example/',
        'name': 'c',
        'value': 'v',
      });
      final c = await chrome.cookies.get(url: 'https://x.example/', name: 'c');
      expect(c!.value, 'v');
    });

    test('cookies_remove', () async {
      await chrome.cookies.set(
        url: 'https://x.example/',
        name: 'c',
        value: 'v',
      );
      await _run(reg, 'cookies_remove', {
        'url': 'https://x.example/',
        'name': 'c',
      });
      expect(
        await chrome.cookies.get(url: 'https://x.example/', name: 'c'),
        isNull,
      );
    });

    test('inject_css', () async {
      final t = await chrome.tabs.create(url: 'https://a.example/');
      await _run(reg, 'inject_css', {
        'tabId': t.id,
        'css': 'body { color: red }',
      });
      expect(chrome.cssCalls.single.css, 'body { color: red }');
    });

    test('nav_wait resolves on a matching main-frame navigation', () async {
      final t = await chrome.tabs.create(url: 'https://a.example/');
      final fut = _run(reg, 'nav_wait', {
        'tabId': t.id,
        'urlContains': 'done',
        'timeoutMs': 2000,
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await chrome.navCompleted(tabId: t.id, url: 'https://a.example/other');
      await chrome.navCompleted(tabId: t.id, url: 'https://a.example/done');
      expect(await fut, contains('done'));
    });
  });

  // -------------------------------------------------------------------------
  group('inject_js (UT-T1 happy + UT-T5 edges)', () {
    test('happy path: canned result with frameId, ISOLATED recorded', () async {
      final t = await chrome.tabs.create(url: 'https://a.example/');
      final out = await _run(reg, 'inject_js', {
        'tabId': t.id,
        'code': '() => document.title',
        'world': 'ISOLATED',
      });
      final parsed = _jsonOf(out);
      expect(parsed['ok'], true);
      final entry =
          (parsed['results']! as List).single! as Map<String, Object?>;
      expect(entry['frameId'], 0);
      expect(entry['result'], {'recorded': true});
      expect(entry.containsKey('truncated'), isFalse);
      expect(chrome.scriptCalls.single.world, 'ISOLATED');
    });

    test('MAIN world passes through to scripting', () async {
      final t = await chrome.tabs.create(url: 'https://a.example/');
      await _run(reg, 'inject_js', {
        'tabId': t.id,
        'code': '1',
        'world': 'MAIN',
      });
      expect(chrome.scriptCalls.single.world, 'MAIN');
    });

    test('world whitelist: ISOLATED/MAIN pass, main/worker/missing/typed '
        'wrong → bad_world naming the argument', () async {
      final t = await chrome.tabs.create(url: 'https://a.example/');
      await _run(reg, 'inject_js', {
        'tabId': t.id,
        'code': '1',
        'world': 'ISOLATED',
      });
      await _run(reg, 'inject_js', {
        'tabId': t.id,
        'code': '1',
        'world': 'MAIN',
      });
      for (final world in ['main', 'worker', null, 42]) {
        final args = <String, Object?>{
          'tabId': t.id,
          'code': '1',
          'world': ?world,
        };
        await expectLater(
          _run(reg, 'inject_js', args),
          throwsA(_errMsg('bad_world', contains('world'))),
          reason: 'world=$world',
        );
      }
    });

    test('allFrames bounds: bool only', () async {
      final t = await chrome.tabs.create(url: 'https://a.example/');
      for (final bad in ['yes', 1]) {
        await expectLater(
          _run(reg, 'inject_js', {
            'tabId': t.id,
            'code': '1',
            'world': 'ISOLATED',
            'allFrames': bad,
          }),
          throwsA(_errMsg('bad_args', contains('allFrames'))),
        );
      }
    });

    test('timeoutMs bounds: 1..120000, default 30000', () async {
      final t = await chrome.tabs.create(url: 'https://a.example/');
      for (final bad in [0, -5, 120001, 'fast']) {
        await expectLater(
          _run(reg, 'inject_js', {
            'tabId': t.id,
            'code': '1',
            'world': 'ISOLATED',
            'timeoutMs': bad,
          }),
          throwsA(_errMsg('bad_args', contains('timeoutMs'))),
          reason: 'timeoutMs=$bad',
        );
      }
      await _run(reg, 'inject_js', {
        'tabId': t.id,
        'code': '1',
        'world': 'ISOLATED',
        'timeoutMs': 120000,
      });
    });

    test('frameIds fan out one result entry per frame', () async {
      final t = await chrome.tabs.create(url: 'https://a.example/');
      final out = await _run(reg, 'inject_js', {
        'tabId': t.id,
        'code': '1',
        'world': 'ISOLATED',
        'frameIds': [0, 2],
      });
      final results = (_jsonOf(out)['results']! as List)
          .cast<Map<String, Object?>>();
      expect(results.map((e) => e['frameId']), [0, 2]);
    });

    test(
      'result budget: oversized frame result truncates with flag (E4)',
      () async {
        final (bReg, bChrome) = _cannedReg(
          resultsFor: (source, args) => {'k': 'v' * 500},
          resultBudget: 32,
        );
        final t = await bChrome.tabs.create(url: 'https://a.example/');
        final out = await _run(bReg, 'inject_js', {
          'tabId': t.id,
          'code': '1',
          'world': 'ISOLATED',
        });
        final entry =
            (_jsonOf(out)['results']! as List).single! as Map<String, Object?>;
        expect(entry['truncated'], true);
        expect(
          utf8.encode(entry['result']! as String).length,
          lessThanOrEqualTo(32),
        );
      },
    );

    test('E2 trio: page throw / rejected promise → structured {ok:false}, '
        'never a raw exception', () async {
      final (throwReg, throwChrome) = _cannedReg(
        resultsFor: (source, args) => throw Exception('page blew up'),
      );
      final (apiErrReg, apiChrome) = _cannedReg(
        resultsFor: (source, args) =>
            throw ChromeApiException('page_error', 'bang'),
      );
      final t = await throwChrome.tabs.create(url: 'https://a.example/');
      final args = {'tabId': t.id, 'code': '1', 'world': 'ISOLATED'};

      final raw = _jsonOf(await _run(throwReg, 'inject_js', args));
      expect(raw['ok'], false);
      expect((raw['error']! as Map)['code'], 'page_error');
      expect((raw['error']! as Map)['message'], contains('page blew up'));

      final t2 = await apiChrome.tabs.create(url: 'https://a.example/');
      final coded = _jsonOf(
        await _run(apiErrReg, 'inject_js', {
          'tabId': t2.id,
          'code': '1',
          'world': 'ISOLATED',
        }),
      );
      expect(coded['ok'], false);
      expect((coded['error']! as Map)['code'], 'page_error');
      expect((coded['error']! as Map)['message'], 'bang');
    });

    test('E2: non-serializable result keeps the facade code', () async {
      final (nReg, nChrome) = _cannedReg(
        resultsFor: (source, args) => Object(),
      );
      final t = await nChrome.tabs.create(url: 'https://a.example/');
      final out = await _run(nReg, 'inject_js', {
        'tabId': t.id,
        'code': '1',
        'world': 'ISOLATED',
      });
      final parsed = _jsonOf(out);
      expect(parsed['ok'], false);
      expect((parsed['error']! as Map)['code'], 'result_not_serializable');
    });

    test('E3: execution_context_destroyed throws retryable=true', () async {
      final (eReg, eChrome) = _cannedReg(
        resultsFor: (source, args) =>
            throw ChromeApiException('execution_context_destroyed', 'gone'),
      );
      final t = await eChrome.tabs.create(url: 'https://a.example/');
      await expectLater(
        _run(eReg, 'inject_js', {
          'tabId': t.id,
          'code': '1',
          'world': 'ISOLATED',
        }),
        throwsA(
          _err(
            'execution_context_destroyed',
          ).having((e) => e.isRetryable, 'isRetryable', true),
        ),
      );
    });
    test(
      'timeoutMs is enforced: a hung page fails with retryable timeout',
      () async {
        // The fake's executeScript cannot hang (resultsFor is consumed
        // synchronously), so inject a scripting seam that never completes.
        final hangingReg = ToolRegistry()
          ..registerAll(
            BrowserApiToolSurface(_HangingScriptChrome(chrome)).tools(),
          );
        final t = await chrome.tabs.create(url: 'https://a.example/');
        await expectLater(
          _run(hangingReg, 'inject_js', {
            'tabId': t.id,
            'code': '1',
            'world': 'ISOLATED',
            'timeoutMs': 40,
          }),
          throwsA(
            _err('timeout').having((e) => e.isRetryable, 'isRetryable', true),
          ),
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  group('cdp_eval + screenshots', () {
    test('cdp_eval returns the evaluated value', () async {
      final (cReg, c) = _cannedReg(
        cdpResponder: (method, params) => {
          'result': {'value': 42},
        },
      );
      final t = await c.tabs.create(url: 'https://a.example/');
      final out = await _run(cReg, 'cdp_eval', {
        'tabId': t.id,
        'expression': '6*7',
      });
      final parsed = _jsonOf(out);
      expect(parsed['ok'], true);
      expect(parsed['value'], 42);
      expect(c.cdpCalls.single.method, 'Runtime.evaluate');
    });

    test('cdp_eval detaches what it attached', () async {
      final (cReg, c) = _cannedReg(
        cdpResponder: (method, params) => {
          'result': {'value': 1},
        },
      );
      final t = await c.tabs.create(url: 'https://a.example/');
      await _run(cReg, 'cdp_eval', {'tabId': t.id, 'expression': '1'});
      // A fresh attach succeeding proves the tool released the target.
      await c.debugger.attach(t.id);
      await c.debugger.detach(t.id);
    });

    test(
      'cdp_eval reuses a foreign session instead of double-attaching',
      () async {
        final (cReg, c) = _cannedReg(
          cdpResponder: (method, params) => {
            'result': {'value': 1},
          },
        );
        final t = await c.tabs.create(url: 'https://a.example/');
        await c.debugger.attach(t.id); // foreign session up front
        await _run(cReg, 'cdp_eval', {'tabId': t.id, 'expression': '1'});
        // The foreign session survived the tool call — detaching is ours.
        await c.debugger.detach(t.id);
      },
    );

    test('cdp_eval surfaces page throws as page_error', () async {
      final (cReg, c) = _cannedReg(
        cdpResponder: (method, params) => {
          'exceptionDetails': {'text': 'ReferenceError'},
        },
      );
      final t = await c.tabs.create(url: 'https://a.example/');
      await expectLater(
        _run(cReg, 'cdp_eval', {'tabId': t.id, 'expression': 'nope'}),
        throwsA(_err('page_error')),
      );
    });

    test(
      'page_screenshot returns base64 PNG via Page.captureScreenshot',
      () async {
        final png = base64Encode([1, 2, 3, 4]);
        final (cReg, c) = _cannedReg(
          cdpResponder: (method, params) =>
              method == 'Page.captureScreenshot' ? {'data': png} : null,
        );
        final t = await c.tabs.create(url: 'https://a.example/');
        final out = await _run(cReg, 'page_screenshot', {
          'tabId': t.id,
          'fullPage': true,
        });
        final parsed = _jsonOf(out);
        expect(parsed['pngBase64'], png);
        expect(c.cdpCalls.single.method, 'Page.captureScreenshot');
        expect(c.cdpCalls.single.params['captureBeyondViewport'], true);
      },
    );

    test('page_screenshot defaults to the active tab', () async {
      final png = base64Encode([9, 9]);
      final (cReg, c) = _cannedReg(
        cdpResponder: (method, params) => {'data': png},
      );
      await c.tabs.create(url: 'https://a.example/'); // active in window 1
      final out = await _run(cReg, 'page_screenshot');
      expect(_jsonOf(out)['tabId'], 1);
    });

    test('app_screenshot prefers /app/, falls back to /panel/ (E14 '
        'otherwise)', () async {
      final png = base64Encode([7]);
      Future<String> shot(FakeChrome c) async {
        final shotReg = ToolRegistry()
          ..registerAll(BrowserApiToolSurface(c).tools());
        return _jsonOf(await _run(shotReg, 'app_screenshot'))['url']! as String;
      }

      final appChrome = FakeChrome(
        clock: () => 1730000000000,
        cdpResponder: (method, params) => {'data': png},
      );
      await appChrome.tabs.create(
        url: 'chrome-extension://fa/panel/index.html',
      );
      await appChrome.tabs.create(url: 'chrome-extension://fa/app/index.html');
      expect(await shot(appChrome), contains('/app/'));

      final panelChrome = FakeChrome(
        clock: () => 1730000000000,
        cdpResponder: (method, params) => {'data': png},
      );
      await panelChrome.tabs.create(url: 'https://a.example/');
      await panelChrome.tabs.create(
        url: 'chrome-extension://fa/panel/index.html',
      );
      expect(await shot(panelChrome), contains('/panel/'));

      await expectLater(
        _run(reg, 'app_screenshot'),
        throwsA(_err('no_app_page')),
      );
    });
  });

  // -------------------------------------------------------------------------
  group('restricted pages (E1/E17)', () {
    const restrictedUrls = [
      'chrome://settings',
      'https://chromewebstore.google.com/detail/x',
      'chrome-extension://fa/app/index.html',
    ];

    test('inject_js / inject_css / cdp_eval / page_screenshot refuse with '
        'restricted_page', () async {
      for (final url in restrictedUrls) {
        final t = await chrome.tabs.create(url: url);
        await expectLater(
          _run(reg, 'inject_js', {
            'tabId': t.id,
            'code': '1',
            'world': 'ISOLATED',
          }),
          throwsA(_err('restricted_page')),
          reason: url,
        );
        await expectLater(
          _run(reg, 'inject_css', {'tabId': t.id, 'css': 'a{}'}),
          throwsA(_err('restricted_page')),
          reason: url,
        );
        await expectLater(
          _run(reg, 'cdp_eval', {'tabId': t.id, 'expression': '1'}),
          throwsA(_err('restricted_page')),
          reason: url,
        );
        await expectLater(
          _run(reg, 'page_screenshot', {'tabId': t.id}),
          throwsA(_err('restricted_page')),
          reason: url,
        );
      }
    });

    test(
      'refusals carry the reason; tab management stays allowed (E17)',
      () async {
        final t = await chrome.tabs.create(url: 'chrome://settings');
        try {
          await _run(reg, 'inject_js', {
            'tabId': t.id,
            'code': '1',
            'world': 'MAIN',
          });
          fail('inject_js should have been refused');
        } on BrowserApiToolException catch (e) {
          expect(e.message, contains('chrome: pages are restricted'));
        }
        expect(
          await _run(reg, 'tabs_open', {'url': 'https://ok.example/'}),
          contains('opened'),
        );
        await _run(reg, 'tabs_move', {'tabId': t.id, 'index': 0});
        await _run(reg, 'tabs_close', {
          'tabIds': [t.id],
        });
      },
    );
  });

  // -------------------------------------------------------------------------
  group('targeted refusals', () {
    test('tabs_discard refuses the active tab with active_tab', () async {
      final t = await chrome.tabs.create(url: 'https://a.example/'); // active
      await expectLater(
        _run(reg, 'tabs_discard', {'tabId': t.id}),
        throwsA(_errMsg('active_tab', contains('active tab'))),
      );
      // Inactive sibling still discards.
      final u = await chrome.tabs.create(url: 'https://b.example/');
      await chrome.tabs.update(t.id, active: true);
      await _run(reg, 'tabs_discard', {'tabId': u.id});
      expect((await chrome.tabs.get(u.id)).discarded, isTrue);
    });

    test(
      'sessions_restore: absent session → no_longer_available (E19)',
      () async {
        await expectLater(
          _run(reg, 'sessions_restore', {'sessionId': 's-gone'}),
          throwsA(
            _errMsg('no_longer_available', contains('no longer available')),
          ),
        );
      },
    );

    test(
      'app_screenshot: no app page → no_app_page, never blank success',
      () async {
        await chrome.tabs.create(url: 'https://a.example/');
        await expectLater(
          _run(reg, 'app_screenshot'),
          throwsA(_err('no_app_page')),
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  group('policy functions', () {
    test('restrictedReason covers the contracted set', () {
      expect(
        restrictedReason('chrome://settings'),
        'chrome: pages are restricted',
      );
      expect(restrictedReason('edge://version'), 'edge: pages are restricted');
      expect(restrictedReason('about:blank'), 'about: pages are restricted');
      expect(
        restrictedReason('chrome-extension://fa/app/index.html'),
        contains('chrome-extension'),
      );
      expect(
        restrictedReason('https://chromewebstore.google.com/detail/x'),
        contains('Web Store'),
      );
      expect(
        restrictedReason('https://chrome.google.com/webstore/category/x'),
        contains('Web Store'),
      );
      expect(restrictedReason('file:///docs/report.pdf'), contains('PDF'));
      expect(restrictedReason('file:///docs/report.PDF'), contains('PDF'));
      expect(restrictedReason('https://example.com/page'), isNull);
      expect(restrictedReason('file:///docs/notes.txt'), isNull);
    });

    test('truncateResult passes small results, clamps oversized ones (E4)', () {
      var r = truncateResult({'a': 1}, 1000);
      expect(r.truncated, isFalse);
      expect(r.result, {'a': 1});

      r = truncateResult('x' * 100, 16);
      expect(r.truncated, isTrue);
      expect(utf8.encode(r.result! as String).length, lessThanOrEqualTo(16));

      // Multi-byte runes never push past the byte budget.
      r = truncateResult('🦄' * 50, 10);
      expect(r.truncated, isTrue);
      expect(utf8.encode(r.result! as String).length, lessThanOrEqualTo(10));
    });
  });
}

/// ChromeApi whose executeScript never completes: exercises the real
/// Future.timeout path in inject_js (E3 companion). Only tabs + scripting
/// are wired; every other member is a loud failure.
final class _HangingScriptChrome implements ChromeApi {
  _HangingScriptChrome(this._inner);
  final ChromeApi _inner;

  @override
  TabsApi get tabs => _inner.tabs;

  @override
  ScriptingApi get scripting => _HangingScripting();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '_HangingScriptChrome only serves tabs/scripting: $invocation',
  );
}

final class _HangingScripting implements ScriptingApi {
  @override
  Future<List<ScriptResult>> executeScript({
    required int tabId,
    String? world,
    bool? allFrames,
    List<int>? frameIds,
    required String funcSource,
    List<Object?>? args,
  }) => Completer<List<ScriptResult>>().future; // never completes

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
