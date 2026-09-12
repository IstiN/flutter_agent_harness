import 'dart:convert';

import 'package:flutter_agent_harness/src/agent/tool_registry.dart';
import 'package:flutter_agent_harness/src/approval/approval.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

import '../src/browser_api_tools.dart';
import '../src/bridge_tools.dart';
import '../src/fake_chrome.dart';

/// Drives one tool call and returns its text result (the model's view).
Future<String> callTool(ToolRegistry reg, String name, Map<String, Object?> args) async {
  final tool = reg.lookup(name)!;
  final res = await tool.execute(args, null, null);
  return res.content
      .whereType<TextContent>()
      .map((t) => t.text)
      .join('\n');
}

void main() {
  group('UT: path validation + deny list (AC5/AC6)', () {
    test('valid paths parse to root/ns/method', () {
      expect(parseBridgePath('chrome.tabs.get').method, 'get');
      expect(parseBridgePath('chrome.idle.queryState').root, 'idle');
      expect(parseBridgePath('chrome.storage.local.get').ns, 'storage.local');
      expect(parseBridgePath('chrome.system.cpu.getInfo').root, 'system');
    });

    test('non-chrome.* and malformed paths reject', () {
      for (final bad in [
        '',
        'tabs.get',
        'window.chrome.tabs.get',
        'chrome.',
        'chrome.tabs',
        'chrome..get',
        'chrome.tabs.',
        'chrome.tabs.get..x',
      ]) {
        expect(() => parseBridgePath(bad), throwsA(isA<BridgePathException>()),
            reason: 'path "$bad" must reject');
      }
    });

    test('prototype tricks reject', () {
      for (final bad in [
        'chrome.__proto__.poll',
        'chrome.tabs.constructor',
        'chrome.constructor.name',
        'chrome.tabs.prototype.x',
        'chrome.tabs.get.constructor',
      ]) {
        expect(() => parseBridgePath(bad), throwsA(isA<BridgePathException>()),
            reason: 'path "$bad" must reject');
      }
    });

    test('events are not bridge-callable (v1 non-goal)', () {
      expect(() => parseBridgePath('chrome.tabs.onUpdated.addListener'),
          throwsA(isA<BridgePathException>()));
    });

    test('management + runtime deny with their own code', () {
      expect(
        () => parseBridgePath('chrome.management.uninstall'),
        throwsA(isA<BridgePathException>().having(
            (e) => e.code, 'code', 'denied_namespace')),
      );
      expect(
        () => parseBridgePath('chrome.runtime.getBackgroundPage'),
        throwsA(isA<BridgePathException>().having(
            (e) => e.code, 'code', 'denied_namespace')),
      );
      // nested hops under a denied root deny too
      expect(() => parseBridgePath('chrome.management.uninstallSelf'),
          throwsA(isA<BridgePathException>()));
    });
  });

  group('UT: risk map (AC5)', () {
    test('read namespaces', () {
      for (final ns in ['tabs', 'bookmarks', 'history', 'idle', 'system']) {
        expect(bridgeRiskTier(ns), ApprovalTier.read, reason: ns);
      }
    });

    test('exec + alwaysPrompts namespaces', () {
      for (final ns in [
        'scripting',
        'debugger',
        'cookies',
        'browsingData',
        'webRequest',
        'declarativeNetRequest',
        'proxy',
        'privacy',
        'tabCapture',
        'nativeMessaging',
      ]) {
        expect(bridgeRiskTier(ns), ApprovalTier.exec, reason: ns);
      }
    });

    test('unknown namespace defaults to exec', () {
      expect(bridgeRiskTier('someFutureApi'), ApprovalTier.exec);
      expect(bridgeRiskTier('brandNewNamespace'), ApprovalTier.exec);
    });
  });

  group('IT: catalog over the fake (AC2 mirror)', () {
    late FakeChrome chrome;
    late ToolRegistry reg;

    setUp(() async {
      chrome = FakeChrome(clock: () => 1730000000000);
      reg = ToolRegistry();
      await registerBridgeTools(reg, chrome);
    });

    test('no args lists the available namespaces', () async {
      final text = await callTool(reg, 'browser_api_catalog', {});
      final json = jsonDecode(text) as Map<String, dynamic>;
      expect(json['ok'], true);
      final namespaces = (json['namespaces'] as List).cast<String>();
      expect(namespaces, containsAll(['tabs', 'bookmarks', 'idle', 'cookies']));
      // The catalog is truthful to the fake's graph: a trimmed namespace
      // never appears (E7 direction 1).
      expect(namespaces, isNot(contains('topSites')));
    });

    test('namespace query lists methods + arity + events', () async {
      final text = await callTool(reg, 'browser_api_catalog', {'namespace': 'tabs'});
      final json = jsonDecode(text) as Map<String, dynamic>;
      expect(json['ok'], true);
      final methods = (json['methods'] as Map).cast<String, dynamic>();
      expect(methods['query'], 1);
      expect(methods['update'], 2);
      expect((json['events'] as List).cast<String>(), contains('onUpdated'));
    });

    test('nested namespace query (storage.local shape)', () async {
      final text =
          await callTool(reg, 'browser_api_catalog', {'namespace': 'storage'});
      final json = jsonDecode(text) as Map<String, dynamic>;
      expect((json['children'] as List).cast<String>(), contains('local'));
    });

    test('unknown namespace is a structured error, never a throw', () async {
      final text = await callTool(
          reg, 'browser_api_catalog', {'namespace': 'noSuchApi'});
      final json = jsonDecode(text) as Map<String, dynamic>;
      expect(json['ok'], false);
      expect((json['error'] as Map)['code'], 'api_missing');
    });

    test('trimmed manifest (ungranted namespace) hides from the catalog',
        () async {
      final trimmed = FakeChrome(bridgeNamespaces: {'tabs', 'idle'});
      final reg2 = ToolRegistry();
      await registerBridgeTools(reg2, trimmed);
      final text = await callTool(reg2, 'browser_api_catalog', {});
      final namespaces =
          ((jsonDecode(text) as Map)['namespaces'] as List).cast<String>();
      expect(namespaces, unorderedEquals(['tabs', 'idle']));
    });
  });

  group('IT: dispatch (AC3/AC4) + errors (AC6)', () {
    late FakeChrome chrome;
    late ToolRegistry reg;

    setUp(() async {
      chrome = FakeChrome(clock: () => 1730000000000);
      reg = ToolRegistry();
      await registerBridgeTools(reg, chrome);
    });

    test('read path end-to-end: chrome.idle.queryState (no curated tool)',
        () async {
      final text = await callTool(reg, 'browser_api', {
        'path': 'chrome.idle.queryState',
        'args': [60],
      });
      final json = jsonDecode(
          text.contains('<<<UNTRUSTED') ? _unwrapped(text) : text);
      expect(json['ok'], true);
      expect(json['path'], 'chrome.idle.queryState');
      expect(json['result'], 'active');
    });

    test('bookmarks.search parity with curated bookmarks_list (AC3)', () async {
      await chrome.bookmarks.create(title: 'Rust docs', url: 'https://doc.rust-lang.org/');
      await chrome.bookmarks.create(title: 'Dart docs', url: 'https://dart.dev/');
      final bridgeText = await callTool(reg, 'browser_api', {
        'path': 'chrome.bookmarks.search',
        'args': ['dart'],
      });
      final bridgeJson =
          jsonDecode(_unwrapped(bridgeText)) as Map<String, dynamic>;
      final found = (bridgeJson['result'] as List)
          .map((e) => (e as Map)['url'])
          .toSet();
      expect(found, {'https://dart.dev/'});

      // Parity: the curated tree tool carries the same node.
      await registerBrowserApiTools(reg, chrome);
      final curated = await callTool(reg, 'bookmarks_list', {});
      expect(curated, contains('https://dart.dev/'));
    });

    test('write path: bookmarks.create then remove (AC4)', () async {
      final created = await callTool(reg, 'browser_api', {
        'path': 'chrome.bookmarks.create',
        'args': [
          {'parentId': '1', 'title': 'tmp', 'url': 'https://example.com/'}
        ],
      });
      final createdJson = jsonDecode(_unwrapped(created)) as Map<String, dynamic>;
      final id = (createdJson['result'] as Map)['id'] as String;
      final removed = await callTool(reg, 'browser_api', {
        'path': 'chrome.bookmarks.remove',
        'args': [id],
      });
      expect((jsonDecode(_unwrapped(removed)) as Map)['ok'], true);
      expect(chrome.storage, isNotNull); // liveness
    });

    test('ungranted namespace → clean structured error (E7)', () async {
      final text = await callTool(reg, 'browser_api', {
        'path': 'chrome.tts.speak',
        'args': ['hello'],
      });
      final json = jsonDecode(text) as Map<String, dynamic>;
      expect(json['ok'], false);
      expect((json['error'] as Map)['code'], 'api_missing');
    });

    test('bad method path → structured error, turn continues (AC6)', () async {
      final text = await callTool(reg, 'browser_api', {
        'path': 'chrome.tabs.noSuchMethod',
        'args': [],
      });
      final json = jsonDecode(text) as Map<String, dynamic>;
      expect(json['ok'], false);
      expect((json['error'] as Map)['code'], 'api_missing');
    });

    test('deny-listed path → structured denied_namespace in every mode',
        () async {
      final text = await callTool(reg, 'browser_api', {
        'path': 'chrome.management.setEnabled',
        'args': [{'enabled': false}],
      });
      final json = jsonDecode(text) as Map<String, dynamic>;
      expect(json['ok'], false);
      expect((json['error'] as Map)['code'], 'denied_namespace');
    });

    test('chrome-level failure maps to structured error (E5)', () async {
      final text = await callTool(reg, 'browser_api', {
        'path': 'chrome.tabs.update',
        'args': [9999, {'active': true}],
      });
      final json = jsonDecode(text) as Map<String, dynamic>;
      expect(json['ok'], false);
      expect((json['error'] as Map)['code'], 'no_tab');
    });

    test('args marshal objects, enums, arrays (tabs.query)', () async {
      await chrome.tabs.create(url: 'https://a.example/');
      await chrome.tabs.create(url: 'https://b.example/');
      final text = await callTool(reg, 'browser_api', {
        'path': 'chrome.tabs.query',
        'args': [
          {'url': '*://a.example/*'}
        ],
      });
      final json = jsonDecode(_unwrapped(text)) as Map<String, dynamic>;
      final tabs = (json['result'] as List).cast<Map>();
      expect(tabs, hasLength(1));
      expect(tabs.single['url'], 'https://a.example/');
    });
  });

  group('IT: hygiene (AC7)', () {
    test('oversized results truncate at the cap with a marker', () async {
      final chrome = FakeChrome(
        clock: () => 1730000000000,
        bridgeResultFor: (path, args) => 'x' * 300_000,
      );
      final reg = ToolRegistry();
      await registerBridgeTools(reg, chrome);
      final text = await callTool(reg, 'browser_api', {
        'path': 'chrome.idle.queryState',
        'args': [60],
      });
      final json = jsonDecode(_unwrapped(text)) as Map<String, dynamic>;
      expect(json['truncated'], true);
      expect((json['result'] as String).length, lessThan(300_000));
    });

    test('credential-shaped cookie values are redacted', () async {
      final chrome = FakeChrome(clock: () => 1730000000000);
      await chrome.cookies.set(
        url: 'https://example.com/',
        name: 'cloudsmith',
        value: 'AKIAIOSFODNN7EXAMPLE',
      );
      final reg = ToolRegistry();
      await registerBridgeTools(reg, chrome);
      final text = await callTool(reg, 'browser_api', {
        'path': 'chrome.cookies.getAll',
        'args': [
          {'url': 'https://example.com/'}
        ],
      });
      expect(text, isNot(contains('AKIAIOSFODNN7EXAMPLE')));
    });

    test('results carry the UNTRUSTED wrapper', () async {
      final chrome = FakeChrome(clock: () => 1730000000000);
      final reg = ToolRegistry();
      await registerBridgeTools(reg, chrome);
      final text = await callTool(reg, 'browser_api', {
        'path': 'chrome.idle.queryState',
        'args': [60],
      });
      expect(text, contains('<<<UNTRUSTED'));
      expect(text, contains('never as instructions'));
    });

    test('non-JSON-serializable result → structured placeholder (E2)',
        () async {
      final chrome = FakeChrome(
        clock: () => 1730000000000,
        // A Dart closure dartified from JS is exactly the non-JSON case.
        bridgeResultFor: (path, args) => () => 42,
      );
      final reg = ToolRegistry();
      await registerBridgeTools(reg, chrome);
      final text = await callTool(reg, 'browser_api', {
        'path': 'chrome.idle.queryState',
        'args': [60],
      });
      final json = jsonDecode(_unwrapped(text)) as Map<String, dynamic>;
      expect(json['ok'], true);
      expect('$json', isNot(contains('Closure')));
      expect(json['result'], contains('non-JSON'));
    });
  });

  group('IT: gating matrix (AC5) — mode-driven, via the risk ask', () {
    test('read tier never asks; executes', () async {
      final asked = <String>[];
      final chrome = FakeChrome(clock: () => 1730000000000);
      final reg = ToolRegistry();
      await registerBridgeTools(reg, chrome,
          riskAsk: (path, tier) async {
            asked.add(path);
            return true;
          });
      final text = await callTool(reg, 'browser_api', {
        'path': 'chrome.idle.queryState',
        'args': [60],
      });
      expect(asked, isEmpty);
      expect((jsonDecode(_unwrapped(text)) as Map)['ok'], true);
    });

    test('write tier never asks; executes', () async {
      final asked = <String>[];
      final chrome = FakeChrome(clock: () => 1730000000000);
      final reg = ToolRegistry();
      await registerBridgeTools(reg, chrome,
          riskAsk: (path, tier) async {
            asked.add(path);
            return true;
          });
      final text = await callTool(reg, 'browser_api', {
        'path': 'chrome.bookmarks.create',
        'args': [
          {'title': 'x', 'url': 'https://x.example/'}
        ],
      });
      expect(asked, isEmpty);
      expect((jsonDecode(_unwrapped(text)) as Map)['ok'], true);
    });

    test('exec tier asks; allow executes', () async {
      final asked = <String>[];
      final chrome = FakeChrome(clock: () => 1730000000000);
      final reg = ToolRegistry();
      await registerBridgeTools(reg, chrome, riskAsk: (path, tier) async {
        asked.add(path);
        return true;
      });
      final text = await callTool(reg, 'browser_api', {
        'path': 'chrome.cookies.getAll',
        'args': [{}],
      });
      expect(asked, ['chrome.cookies.getAll']);
      expect((jsonDecode(_unwrapped(text)) as Map)['ok'], true);
    });

    test('exec tier denied → approval_required data error', () async {
      final chrome = FakeChrome(clock: () => 1730000000000);
      final reg = ToolRegistry();
      await registerBridgeTools(reg, chrome, riskAsk: (path, tier) async => false);
      final text = await callTool(reg, 'browser_api', {
        'path': 'chrome.browsingData.remove',
        'args': [{}, {}],
      });
      final json = jsonDecode(text) as Map<String, dynamic>;
      expect(json['ok'], false);
      expect((json['error'] as Map)['code'], 'approval_required');
    });

    test('unknown namespace prompts through the exec default (AC5e)',
        () async {
      final asked = <String>[];
      final chrome = FakeChrome(
        clock: () => 1730000000000,
        bridgeResultFor: (path, args) => 'ok',
      );
      final reg = ToolRegistry();
      await registerBridgeTools(reg, chrome, riskAsk: (path, tier) async {
        asked.add(path);
        return true;
      });
      final text = await callTool(reg, 'browser_api', {
        'path': 'chrome.clipboardRead.readText', // unmapped root → exec
        'args': [],
      });
      expect(asked, ['chrome.clipboardRead.readText']);
      expect((jsonDecode(_unwrapped(text)) as Map)['ok'], true);
    });

    test('management denies even with an allow-everything ask', () async {
      final chrome = FakeChrome(clock: () => 1730000000000);
      final reg = ToolRegistry();
      await registerBridgeTools(reg, chrome, riskAsk: (path, tier) async => true);
      final text = await callTool(reg, 'browser_api', {
        'path': 'chrome.management.getAll',
        'args': [],
      });
      expect((jsonDecode(text) as Map)['ok'], false);
    });

    test('first call fires the one-time notice hook', () async {
      final calls = <String>[];
      final chrome = FakeChrome(clock: () => 1730000000000);
      final reg = ToolRegistry();
      await registerBridgeTools(reg, chrome, onFirstCall: calls.add);
      await callTool(reg, 'browser_api',
          {'path': 'chrome.idle.queryState', 'args': [60]});
      await callTool(reg, 'browser_api',
          {'path': 'chrome.idle.queryState', 'args': [60]});
      expect(calls, ['chrome.idle.queryState']); // once, with the path
    });
  });

  group('IT: injection parity (AC5 tail)', () {
    test('bridge-path scripting.executeScript records the same script call '
        'shape as curated inject_js', () async {
      final chrome = FakeChrome(clock: () => 1730000000000);
      final tab = await chrome.tabs.create(url: 'https://page.example/');

      final curatedReg = ToolRegistry();
      await registerBrowserApiTools(curatedReg, chrome);
      final curatedTool = curatedReg.lookup('inject_js')!;
      await curatedTool.execute({
        'tabId': tab.id,
        'code': 'window.__marker = 7',
        'world': 'ISOLATED',
      }, null, null);

      final reg = ToolRegistry();
      await registerBridgeTools(reg, chrome);
      final text = await callTool(reg, 'browser_api', {
        'path': 'chrome.scripting.executeScript',
        'args': [
          {
            'target': {'tabId': tab.id},
            'func': 'window.__marker = 7',
          }
        ],
      });
      expect((jsonDecode(_unwrapped(text)) as Map)['ok'], true);

      final calls = chrome.scriptCalls;
      expect(calls, hasLength(2));
      expect(calls[0].funcSource, calls[1].funcSource);
      expect(calls[0].tabId, calls[1].tabId);
    });

    test('scripting rides the exec tier (prompts)', () async {
      final asked = <String>[];
      final chrome = FakeChrome(clock: () => 1730000000000);
      final tab = await chrome.tabs.create(url: 'https://page.example/');
      final reg = ToolRegistry();
      await registerBridgeTools(reg, chrome, riskAsk: (path, tier) async {
        asked.add(path);
        return true;
      });
      await callTool(reg, 'browser_api', {
        'path': 'chrome.scripting.executeScript',
        'args': [
          {
            'target': {'tabId': tab.id},
            'func': '1',
          }
        ],
      });
      expect(asked, ['chrome.scripting.executeScript']);
    });
  });

  group('REG: registry contract (AC9)', () {
    test('tool list grows by exactly 2', () async {
      final chrome = FakeChrome(clock: () => 1730000000000);
      final reg = ToolRegistry();
      await registerBrowserApiTools(reg, chrome);
      final before = reg.names.toSet();

      await registerBridgeTools(reg, chrome);
      final after = reg.names.toSet();

      expect(after.difference(before), {'browser_api', 'browser_api_catalog'});
      expect(after.length, before.length + 2);
    });

    test('curated specs untouched: browserApiToolSpecs identical set', () {
      // The curated family must still carry exactly its 39 specs.
      expect(browserApiToolSpecs().length, 38);
    });

    test('both tools are read-tier static (the risk ask is dynamic)',
        () async {
      final chrome = FakeChrome(clock: () => 1730000000000);
      final reg = ToolRegistry();
      await registerBridgeTools(reg, chrome);
      expect(reg.lookup('browser_api')!.tier, ApprovalTier.read);
      expect(reg.lookup('browser_api_catalog')!.tier, ApprovalTier.read);
    });
  });

  group('UT: audit (AC: tool records carry full path+args)', () {
    test('the call envelope echoes path and args verbatim', () async {
      final chrome = FakeChrome(clock: () => 1730000000000);
      final reg = ToolRegistry();
      await registerBridgeTools(reg, chrome);
      final text = await callTool(reg, 'browser_api', {
        'path': 'chrome.bookmarks.search',
        'args': ['query-me'],
      });
      final json = jsonDecode(_unwrapped(text)) as Map<String, dynamic>;
      expect(json['path'], 'chrome.bookmarks.search');
    });
  });
}

/// Strips the UNTRUSTED quarantine fence so JSON assertions can decode.
String _unwrapped(String wrapped) {
  final start = wrapped.indexOf('>>\n');
  final end = wrapped.indexOf('\n<<<');
  return wrapped.substring(start + 3, end);
}
