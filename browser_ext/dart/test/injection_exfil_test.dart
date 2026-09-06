// Prompt-injection + exfiltration gates (issue #30 v2.1):
//
// IT-S9 — the injection validator through inject_js / cdp_eval: login
// and SSO/OAuth-shaped pages refuse with 'login_form', keystroke-capture
// code refuses with 'keylogger_shaped' on every page, benign code and
// beforeunload value-capture pass (no over-block).
//
// IT-S8 — the exfil gate: visited-origin outbound actions are allowed,
// unvisited origins and page-derived sources require approval
// ('approval_required' with the gate's explanation), clipboard/mail
// payloads always count as data leaving the browser.
//
// Firewall — page-derived READ results (cdp_eval strings, history rows,
// bookmark titles) come back redacted through the core RedactionPipeline
// and wrapped in the quarantine fence.

import 'package:flutter_agent_harness/src/agent/tool_registry.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

import '../src/browser_api_tools.dart';
import '../src/fake_chrome.dart';
import '../src/security/exfil_gate.dart';
import '../src/security/injection_validator.dart';

PageClassification _page({
  bool password = false,
  bool form = false,
  bool loginUrl = false,
  String url = 'https://p.example/x',
}) => PageClassification(
  hasPasswordField: password,
  hasFormSubmit: form,
  loginShapedUrl: loginUrl,
  url: url,
);

(ToolRegistry, FakeChrome) _reg({
  PageClassifier? classifier,
  Set<String>? visited,
  Object? Function(String method, Map<String, Object?> params)? cdpResponder,
}) {
  final chrome = FakeChrome(cdpResponder: cdpResponder);
  final tools = BrowserApiToolSurface(
    chrome,
    pageClassifier: classifier ?? urlHeuristicClassifier,
    visitedOrigins: visited,
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

TypeMatcher<BrowserApiToolException> _err(String code) =>
    isA<BrowserApiToolException>().having((e) => e.code, 'code', code);

Matcher _errMsg(String code, Object message) =>
    _err(code).having((e) => e.message, 'message', message);

void main() {
  group('IT-S9: injection gate over the tool surface', () {
    test('inject_js refuses a password+submit page with login_form', () async {
      final (reg, chrome) = _reg(
        classifier: (tabId, url) async =>
            _page(password: true, form: true, url: url),
      );
      final t = await chrome.tabs.create(url: 'https://a.example/');
      await expectLater(
        _run(reg, 'inject_js', {'tabId': t.id, 'code': '1+1', 'world': 'MAIN'}),
        throwsA(_errMsg('login_form', contains('credential-shaped'))),
      );
    });

    test('loginShapedUrl + password field refuses too', () async {
      final (reg, chrome) = _reg(
        classifier: (tabId, url) async => _page(password: true, loginUrl: true),
      );
      final t = await chrome.tabs.create(url: 'https://id.example/sso');
      await expectLater(
        _run(reg, 'inject_js', {
          'tabId': t.id,
          'code': '1+1',
          'world': 'ISOLATED',
        }),
        throwsA(_err('login_form')),
      );
    });

    test('keylogger-shaped code refuses on a benign page', () async {
      final (reg, chrome) = _reg();
      final t = await chrome.tabs.create(url: 'https://a.example/');
      await expectLater(
        _run(reg, 'inject_js', {
          'tabId': t.id,
          'code': "document.addEventListener('keydown', e => {}); return 1;",
          'world': 'MAIN',
        }),
        throwsA(_err('keylogger_shaped')),
      );
    });

    test('cdp_eval follows the same rules', () async {
      final (loginReg, loginChrome) = _reg(
        classifier: (tabId, url) async => _page(password: true, form: true),
      );
      final lt = await loginChrome.tabs.create(url: 'https://a.example/');
      await expectLater(
        _run(loginReg, 'cdp_eval', {'tabId': lt.id, 'expression': '1+1'}),
        throwsA(_err('login_form')),
      );

      final (reg, chrome) = _reg();
      final t = await chrome.tabs.create(url: 'https://a.example/');
      await expectLater(
        _run(reg, 'cdp_eval', {
          'tabId': t.id,
          'expression': 'window.onkeyup = f',
        }),
        throwsA(_err('keylogger_shaped')),
      );
    });

    test('benign code on a benign page passes (both tools)', () async {
      final (reg, chrome) = _reg();
      final t = await chrome.tabs.create(url: 'https://a.example/');
      final out = await _run(reg, 'inject_js', {
        'tabId': t.id,
        'code': '1+1',
        'world': 'MAIN',
      });
      expect(out, contains('"ok":true'));

      final (cReg, cChrome) = _reg(
        cdpResponder: (method, params) => {
          'result': {'value': 42},
        },
      );
      final ct = await cChrome.tabs.create(url: 'https://a.example/');
      final cout = await _run(cReg, 'cdp_eval', {
        'tabId': ct.id,
        'expression': '6*7',
      });
      expect(cout, contains('"value":42'));
    });

    test('beforeunload + value capture passes — no over-block', () async {
      final (reg, chrome) = _reg();
      final t = await chrome.tabs.create(url: 'https://a.example/');
      final out = await _run(reg, 'inject_js', {
        'tabId': t.id,
        'code':
            "window.addEventListener('beforeunload', () => "
            "document.querySelector('#email').value); return 1;",
        'world': 'MAIN',
      });
      expect(out, contains('"ok":true'));
    });

    test('default URL heuristic alone never refuses a login-ish URL', () async {
      final (reg, chrome) = _reg();
      final t = await chrome.tabs.create(
        url: 'https://id.example/account/login',
      );
      final out = await _run(reg, 'inject_js', {
        'tabId': t.id,
        'code': '1+1',
        'world': 'ISOLATED',
      });
      expect(out, contains('"ok":true'));
    });
  });

  group('keylogger shapes (validator unit)', () {
    const validator = InjectionValidator();
    final benign = _page();

    test('validateCss is a passthrough', () {
      expect(validator.validateCss('a { color: red }').allowed, isTrue);
    });

    for (final (shape, code) in const [
      ("addEventListener 'keydown'", "document.addEventListener('keydown', f)"),
      ('addEventListener "keypress"', 'x.addEventListener("keypress", f)'),
      ('addEventListener keyup', 'window.addEventListener("keyup", f)'),
      ('document.onkey', 'document.onkeyup = f'),
      ('window.onkey', 'window.onkeydown = f'),
      ('receiver assignment', 'el.onkeydown = f'),
    ]) {
      test('refuses: $shape', () {
        final d = validator.validateJs(code: code, page: benign);
        expect(d.allowed, isFalse, reason: code);
        expect(d.code, 'keylogger_shaped');
      });
    }
  });

  group('IT-S8: exfil gate over tabs_open / downloads_start', () {
    test('tabs_open to a visited origin is allowed', () async {
      final (reg, chrome) = _reg(visited: {'https://a.example'});
      final out = await _run(reg, 'tabs_open', {'url': 'https://a.example/x'});
      expect(out, contains('opened tab'));
    });

    test(
      'tabs_open to an unvisited origin asks for approval, naming it',
      () async {
        final (reg, chrome) = _reg(visited: {'https://a.example'});
        await expectLater(
          _run(reg, 'tabs_open', {'url': 'https://unvisited.example/x'}),
          throwsA(
            _errMsg(
              'approval_required',
              allOf(
                contains('unvisited.example'),
                contains('tabs_open'.replaceAll('tabs_open', 'windowOpen')),
                contains('cross_origin'),
              ),
            ),
          ),
        );
      },
    );

    test(
      'downloads_start cross-origin requires approval; visited passes',
      () async {
        final (reg, chrome) = _reg(visited: {'https://a.example'});
        await expectLater(
          _run(reg, 'downloads_start', {
            'url': 'https://cdn.other.example/f.bin',
          }),
          throwsA(_err('approval_required')),
        );
        final out = await _run(reg, 'downloads_start', {
          'url': 'https://a.example/f.bin',
        });
        expect(out, contains('started download'));
      },
    );

    test('default surface keeps the gate off (legacy behavior)', () async {
      final (reg, chrome) = _reg();
      final out = await _run(reg, 'tabs_open', {
        'url': 'https://never-seen.example/',
      });
      expect(out, contains('opened tab'));
    });
  });

  group('exfil gate decisions (unit)', () {
    const gate = ExfilGate();
    const visited = {'https://a.example'};

    OutboundAction action(
      OutboundKind kind,
      ActionSource source, {
      String origin = 'https://a.example',
      String payload = '',
    }) => OutboundAction(
      kind: kind,
      targetOrigin: origin,
      payloadSnippet: payload,
      source: source,
    );

    test('realUser + visited is allowed — no false-positive lockout', () {
      final d = gate.evaluate(
        action(OutboundKind.fetch, ActionSource.realUser),
        userVisitedOrigins: visited,
      );
      expect(d.requiresApproval, isFalse);
    });

    test('realUser + unvisited origin → cross_origin approval', () {
      final d = gate.evaluate(
        action(
          OutboundKind.fetch,
          ActionSource.realUser,
          origin: 'https://x.example',
        ),
        userVisitedOrigins: visited,
      );
      expect(d.requiresApproval, isTrue);
      expect(d.attribution, 'cross_origin');
    });

    test('pageContent requires approval even to a visited origin', () {
      final d = gate.evaluate(
        action(OutboundKind.windowOpen, ActionSource.pageContent),
        userVisitedOrigins: visited,
      );
      expect(d.requiresApproval, isTrue);
      expect(d.attribution, 'page_derived');
    });

    test('toolOutput is page-derived too', () {
      final d = gate.evaluate(
        action(OutboundKind.fetch, ActionSource.toolOutput),
        userVisitedOrigins: visited,
      );
      expect(d.requiresApproval, isTrue);
      expect(d.attribution, 'page_derived');
    });

    test('clipboardWrite / mailSend with payload always require approval', () {
      for (final kind in [OutboundKind.clipboardWrite, OutboundKind.mailSend]) {
        final d = gate.evaluate(
          action(kind, ActionSource.realUser, payload: 'seed phrase'),
          userVisitedOrigins: visited,
        );
        expect(d.requiresApproval, isTrue, reason: '$kind');
        expect(d.attribution, 'data_exit');
      }
    });

    test('clipboardWrite with an empty payload to a visited origin passes', () {
      final d = gate.evaluate(
        action(OutboundKind.clipboardWrite, ActionSource.realUser),
        userVisitedOrigins: visited,
      );
      expect(d.requiresApproval, isFalse);
    });

    test('explain names kind, origin and attribution', () {
      final a = action(OutboundKind.windowOpen, ActionSource.pageContent);
      final text = gate.explain(
        a,
        gate.evaluate(a, userVisitedOrigins: visited),
      );
      expect(text, contains('windowOpen'));
      expect(text, contains('https://a.example'));
      expect(text, contains('page_derived'));
    });

    test('outboundOrigin parses origins, falls back off the http(s) path', () {
      expect(outboundOrigin('https://a.example/x?y=1'), 'https://a.example');
      expect(
        outboundOrigin('http://b.example:8080/p'),
        'http://b.example:8080',
      );
      expect(outboundOrigin('chrome://settings'), 'chrome://settings');
      expect(outboundOrigin('about:blank'), 'about://');
    });
  });

  group('firewall: page-derived reads come back masked + quarantined', () {
    test('cdp_eval string results mask planted secrets', () async {
      final (reg, chrome) = _reg(
        cdpResponder: (method, params) => {
          'result': {
            'value':
                '{"password": "hunter2"} and key sk-abcdefghijklmnopqrstuv',
          },
        },
      );
      final t = await chrome.tabs.create(url: 'https://a.example/');
      final out = await _run(reg, 'cdp_eval', {
        'tabId': t.id,
        'expression': 'document.body.innerText',
      });
      expect(out, contains('[REDACTED:credential]'));
      expect(out, contains('[REDACTED:OpenAI Key]'));
      expect(out, isNot(contains('hunter2')));
      expect(out, isNot(contains('sk-abcdefghijklmnopqrstuv')));
      expect(out, contains('<<<UNTRUSTED PAGE CONTENT source=cdp_eval'));
      expect(out, contains('<<<END UNTRUSTED>>>'));
    });

    test(
      'history_search rows mask a planted key and carry the fence',
      () async {
        final (reg, chrome) = _reg();
        chrome.seedHistory(
          url: 'https://docs.example/x',
          title: 'sk-abcdefghijklmnopqrstuv notes',
        );
        final out = await _run(reg, 'history_search', {'text': 'notes'});
        expect(out, contains('[REDACTED:OpenAI Key]'));
        expect(out, isNot(contains('sk-abcdefghijklmnopqrstuv')));
        expect(out, contains('<<<UNTRUSTED PAGE CONTENT source=history'));
      },
    );

    test('bookmarks_list rows carry the quarantine fence', () async {
      final (reg, chrome) = _reg();
      await chrome.bookmarks.create(title: 'GH', url: 'https://github.com');
      final out = await _run(reg, 'bookmarks_list');
      expect(out, contains('https://github.com'));
      expect(out, contains('<<<UNTRUSTED PAGE CONTENT source=bookmarks'));
      expect(out, contains('<<<END UNTRUSTED>>>'));
    });
  });
}
