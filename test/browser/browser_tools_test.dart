/// Tests for the `browser_*` tool family (issue #23): a scripted
/// [BrowserController] fake stands in for the bridge, so the table covers
/// happy paths, arg validation, error mapping, and availability gating
/// without a browser.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

final _png = Uint8List.fromList(const [1, 2, 3, 4]);

final class _FakeController implements BrowserController {
  final calls = <(String, Map<String, dynamic>)>[];
  BrowserToolException? error;
  bool truncatedDom = false;

  @override
  bool attached = true;

  @override
  void Function(bool attached)? onAvailabilityChanged;

  Future<Map<String, dynamic>> _op(String op, Map<String, dynamic> args) async {
    calls.add((op, args));
    final error = this.error;
    if (error != null) throw error;
    return switch (op) {
      'navigate' => {'tabId': 4, 'url': args['url'], 'title': 'Example'},
      'tabs' => {
        'tabs': [
          {
            'id': 1,
            'url': 'https://example.com/a',
            'title': 'A',
            'active': true,
            'groupId': 9,
          },
          {
            'id': 2,
            'url': 'https://example.com/b',
            'title': 'B',
            'active': false,
          },
        ],
      },
      'read_dom' => {
        'dom': '<html><body id="root"/></html>',
        'nodeCount': 42,
        'truncated': truncatedDom,
      },
      'eval' => {'result': 2},
      'screenshot' => {'pngBase64': base64Encode(_png)},
      'wait_for' => {'found': true, 'waitedMs': 123},
      _ => const {},
    };
  }

  @override
  Future<BrowserNavigation> navigate(String url, {int? tabId}) async {
    final r = await _op('navigate', {'url': url, 'tabId': ?tabId});
    return (
      tabId: r['tabId'] as int,
      url: r['url'] as String,
      title: r['title'] as String,
    );
  }

  @override
  Future<List<BrowserTab>> listTabs() async {
    final r = await _op('tabs', const {});
    return [
      for (final tab in (r['tabs'] as List).cast<Map>())
        (
          id: tab['id'] as int,
          url: tab['url'] as String,
          title: tab['title'] as String,
          active: tab['active'] as bool,
          groupId: tab['groupId'] as int?,
        ),
    ];
  }

  @override
  Future<void> switchTab(int tabId) async {
    await _op('switch_tab', {'tabId': tabId});
  }

  @override
  Future<void> click(String selector, {int? tabId}) async {
    await _op('click', {'selector': selector, 'tabId': ?tabId});
  }

  @override
  Future<void> type(
    String selector,
    String text, {
    bool submit = false,
    int? tabId,
  }) async {
    await _op('type', {
      'selector': selector,
      'text': text,
      'submit': submit,
      'tabId': ?tabId,
    });
  }

  @override
  Future<void> pressKey(String key, {String? selector, int? tabId}) async {
    await _op('press_key', {
      'key': key,
      'selector': ?selector,
      'tabId': ?tabId,
    });
  }

  @override
  Future<void> select(String selector, String value, {int? tabId}) async {
    await _op('select', {
      'selector': selector,
      'value': value,
      'tabId': ?tabId,
    });
  }

  @override
  Future<BrowserDom> readDom({
    String? selector,
    int? maxNodes,
    bool includeShadow = false,
    int? tabId,
  }) async {
    final r = await _op('read_dom', {
      'selector': ?selector,
      'maxNodes': ?maxNodes,
      'includeShadow': includeShadow,
      'tabId': ?tabId,
    });
    return (
      dom: r['dom'] as String,
      nodeCount: r['nodeCount'] as int,
      truncated: r['truncated'] as bool,
    );
  }

  @override
  Future<Object?> evalCode(String code, {int? tabId}) async {
    final r = await _op('eval', {'code': code, 'tabId': ?tabId});
    return r['result'];
  }

  @override
  Future<Uint8List> screenshot({int? tabId}) async {
    final r = await _op('screenshot', {'tabId': ?tabId});
    return base64Decode(r['pngBase64'] as String);
  }

  @override
  Future<BrowserWaitResult> waitFor({
    String? selector,
    String? text,
    required int timeoutMs,
    int? tabId,
  }) async {
    final r = await _op('wait_for', {
      'selector': ?selector,
      'text': ?text,
      'timeoutMs': timeoutMs,
      'tabId': ?tabId,
    });
    return (found: r['found'] as bool, waitedMs: r['waitedMs'] as int);
  }

  @override
  Future<void> taskEnd() async {
    await _op('task_end', const {});
  }
}

const _toolNames = [
  'browser_navigate',
  'browser_tabs',
  'browser_switch_tab',
  'browser_click',
  'browser_type',
  'browser_press_key',
  'browser_select',
  'browser_read_dom',
  'browser_eval',
  'browser_screenshot',
  'browser_wait_for',
];

/// (tool name, args, a substring the result text must contain, the op the
/// controller must have received).
const _happyPaths = <(String, Map<String, dynamic>, String, String)>[
  (
    'browser_navigate',
    {'url': 'https://example.com'},
    'navigated tab 4 to https://example.com',
    'navigate',
  ),
  ('browser_tabs', {}, 'https://example.com/a', 'tabs'),
  ('browser_switch_tab', {'tabId': 3}, 'switched to tab 3', 'switch_tab'),
  ('browser_click', {'selector': '#go'}, 'clicked #go', 'click'),
  (
    'browser_type',
    {'selector': '#q', 'text': 'hello'},
    'typed 5 characters into #q',
    'type',
  ),
  ('browser_press_key', {'key': 'Enter'}, 'pressed Enter', 'press_key'),
  (
    'browser_select',
    {'selector': '#s', 'value': 'b'},
    'selected "b"',
    'select',
  ),
  ('browser_read_dom', {}, '<html><body id="root"/></html>', 'read_dom'),
  ('browser_eval', {'code': '1+1'}, 'eval result: 2', 'eval'),
  ('browser_wait_for', {'text': 'done'}, 'after 123ms', 'wait_for'),
];

/// (tool name, args) — every call must fail with bad_args and never reach
/// the controller.
const _badArgs = <(String, Map<String, dynamic>)>[
  ('browser_navigate', {}),
  ('browser_switch_tab', {}),
  ('browser_click', {}),
  ('browser_type', {'selector': '#q'}),
  ('browser_type', {'text': 'x'}),
  ('browser_press_key', {'selector': '#q'}),
  ('browser_select', {'selector': '#s'}),
  ('browser_select', {'value': 'b'}),
  ('browser_eval', {}),
  ('browser_read_dom', {'maxNodes': 5001}),
  ('browser_wait_for', {}),
  ('browser_wait_for', {'text': 'x', 'timeoutMs': 30001}),
];

(_FakeController, Map<String, AgentTool>) _harness() {
  final controller = _FakeController();
  final tools = {
    for (final tool in browserTools(
      controller: controller,
      saveScreenshot: (png) async => 'shot.png',
    ))
      tool.name: tool,
  };
  return (controller, tools);
}

String _textOf(ToolExecutionResult result) => result.content
    .whereType<TextContent>()
    .map((block) => block.text)
    .join('\n');

void main() {
  group('browserTools', () {
    test('exposes exactly the eleven contract tools', () {
      expect(_harness().$2.keys.toSet(), _toolNames.toSet());
    });

    test('every tool is exec-tier', () {
      for (final entry in _harness().$2.entries) {
        expect(entry.value.tier, ApprovalTier.exec, reason: entry.key);
      }
    });

    test('every happy path reaches the scripted controller', () async {
      for (final (name, args, expectedText, expectedOp) in _happyPaths) {
        final (controller, tools) = _harness();
        expect(tools[name], isNotNull, reason: name);
        final result = await tools[name]!.execute(args, null, null);
        expect(_textOf(result), contains(expectedText), reason: name);
        expect(controller.calls.single.$1, expectedOp, reason: name);
      }
    });

    test('tabId pins ops; omitting it never sends the key', () async {
      final (controller, tools) = _harness();
      await tools['browser_click']!.execute(
        {'selector': '#go', 'tabId': 7},
        null,
        null,
      );
      expect(controller.calls.single.$2['tabId'], 7);
      await tools['browser_click']!.execute({'selector': '#go'}, null, null);
      expect(controller.calls.last.$2.containsKey('tabId'), isFalse);
    });

    test('read_dom passes nodeCount and the truncated flag through', () async {
      final (controller, tools) = _harness();
      controller.truncatedDom = true;
      final text = _textOf(
        await tools['browser_read_dom']!.execute({'maxNodes': 100}, null, null),
      );
      expect(text, contains('42 nodes'));
      expect(text, contains('TRUNCATED'));
      expect(controller.calls.single.$2['maxNodes'], 100);
    });

    test(
      'screenshot saves via the saver, inlines the image, links the path',
      () async {
        final saved = <Uint8List>[];
        final controller = _FakeController();
        final tools = {
          for (final tool in browserTools(
            controller: controller,
            saveScreenshot: (png) async {
              saved.add(png);
              return 'shot.png';
            },
          ))
            tool.name: tool,
        };
        final result = await tools['browser_screenshot']!.execute(
          {'tabId': 2},
          null,
          null,
        );
        expect(saved, [_png]);
        final text = _textOf(result);
        expect(text, contains('![screenshot](shot.png)'));
        expect(text, contains('saved screenshot to shot.png'));
        final image = result.content.whereType<ImageContent>().single;
        expect(image.mimeType, 'image/png');
        expect(base64Decode(image.data), _png);
        expect(controller.calls.single.$2['tabId'], 2);
      },
    );

    test(
      'controller failures throw with the contract code in the message',
      () async {
        final (controller, tools) = _harness();
        controller.error = BrowserToolException('node_vanished', '#go is gone');
        await expectLater(
          tools['browser_click']!.execute({'selector': '#go'}, null, null),
          throwsA(
            isA<BrowserToolException>()
                .having((e) => e.code, 'code', 'node_vanished')
                .having(
                  (e) => e.toString(),
                  'toString',
                  contains('node_vanished'),
                ),
          ),
        );
      },
    );

    test(
      'invalid args fail with bad_args before reaching the controller',
      () async {
        for (final (name, args) in _badArgs) {
          final (controller, tools) = _harness();
          await expectLater(
            tools[name]!.execute(args, null, null),
            throwsA(
              isA<BrowserToolException>().having(
                (e) => e.code,
                'code',
                'bad_args',
              ),
            ),
            reason: name,
          );
          expect(controller.calls, isEmpty, reason: name);
        }
      },
    );

    test(
      'wait_for dispatches selector vs text and defaults timeoutMs',
      () async {
        final (controller, tools) = _harness();
        await tools['browser_wait_for']!.execute(
          {'selector': '.a'},
          null,
          null,
        );
        expect(controller.calls.last.$2['selector'], '.a');
        expect(controller.calls.last.$2.containsKey('text'), isFalse);
        expect(controller.calls.last.$2['timeoutMs'], 10000);
        await tools['browser_wait_for']!.execute(
          {'text': 'done', 'timeoutMs': 5000},
          null,
          null,
        );
        expect(controller.calls.last.$2['text'], 'done');
        expect(controller.calls.last.$2.containsKey('selector'), isFalse);
        expect(controller.calls.last.$2['timeoutMs'], 5000);
      },
    );

    test('type forwards submit=true', () async {
      final (controller, tools) = _harness();
      final text = _textOf(
        await tools['browser_type']!.execute(
          {'selector': '#q', 'text': 'hi', 'submit': true},
          null,
          null,
        ),
      );
      expect(controller.calls.single.$2['submit'], true);
      expect(text, contains('pressed Enter'));
    });

    test('saveBrowserScreenshot writes generated/browser-<ts>.png', () async {
      final env = MemoryExecutionEnv();
      final path = await saveBrowserScreenshot(env, _png);
      expect(path, startsWith('generated/browser-'));
      expect(path, endsWith('.png'));
      expect((await env.readBinaryFile(path)).getOrThrow(), _png);
    });
  });

  group('browser availability', () {
    test(
      'absent capability disables the family at builtin scope with a reason',
      () {
        final resolution = resolveToolAvailability(
          capabilities: const {
            'browser': ToolCapability.absent('no browser extension connected'),
            'browser_eval': ToolCapability.absent(
              'no browser extension connected',
            ),
          },
          scopes: const [
            (ToolScope.project, ToolsConfig(tools: {'browser': true})),
          ],
        );
        for (final id in ['browser', 'browser_eval']) {
          final decision = resolution.byId[id]!;
          expect(decision.enabled, isFalse, reason: id);
          expect(decision.scope, ToolScope.builtin, reason: id);
          expect(decision.reason, isNotNull, reason: id);
        }
      },
    );

    test('browser_eval off in a scope hides only eval', () {
      final resolution = resolveToolAvailability(
        capabilities: const {
          'browser': ToolCapability.available(),
          'browser_eval': ToolCapability.available(),
        },
        scopes: [
          (ToolScope.project, ToolsConfig(tools: {'browser_eval': false})),
        ],
      );
      expect(resolution.byId['browser_eval']!.enabled, isFalse);
      expect(resolution.byId['browser_eval']!.scope, ToolScope.project);
      expect(resolution.byId['browser']!.enabled, isTrue);
    });

    test('reverse index keeps browser_eval on its own id', () {
      expect(toolAvailabilityIdOf('browser_eval'), 'browser_eval');
      for (final name in _toolNames.where((n) => n != 'browser_eval')) {
        expect(toolAvailabilityIdOf(name), 'browser', reason: name);
      }
    });

    test('the browser family lists every browser tool name', () {
      expect(coreToolFamilies['browser'], _toolNames.toSet());
      expect(coreToolFamilies['browser_eval'], {'browser_eval'});
    });
  });
}
