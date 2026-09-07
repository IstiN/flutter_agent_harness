// End-to-end test for the browser extension agent, driven over the REAL
// wire: launches Chrome for Testing with browser_ext unpacked, opens an
// extension page, connects a `fa-ui-v2` port and speaks the protocol a
// panel speaks — hello/attach (tools_state), settings_put with a REAL
// provider, then two real turns: a plain reply and one answered through
// the browser_active_tab tool.
//
// Usage (repo root):
//   FA_ZAI_KEY="<key>" FA_TEST_CHROME=<path> \
//     dart run scripts/e2e_extension_agent.dart [baseUrl] [model]
// Defaults: baseUrl https://api.z.ai/api/paas/v4, model glm-5.3-flash.
// Exit 0 = every step passed; failures print === FAIL lines.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

Future<void> main(List<String> args) async {
  final key = Platform.environment['FA_ZAI_KEY'];
  if (key == null || key.isEmpty) {
    stderr.writeln('FA_ZAI_KEY is required (the provider key to configure)');
    exit(2);
  }
  final baseUrl = args.isNotEmpty ? args[0] : 'https://api.z.ai/api/paas/v4';
  final model = args.length > 1 ? args[1] : 'glm-5.3-flash';

  final chrome = Platform.environment['FA_TEST_CHROME'] ?? 'google-chrome';
  final tmp = await Directory.systemTemp.createTemp('fa_ext_e2e');
  // Unpack the built zip — the exact artifact a user loads.
  final extDir = '${tmp.path}/ext';
  await Process.run('unzip', ['-q', 'build/fa-extension.zip', '-d', extDir]);
  if (!File('$extDir/manifest.json').existsSync()) {
    stderr.writeln('build/fa-extension.zip missing — run build_browser_ext.sh');
    exit(2);
  }
  final wsUrlCompleter = Completer<String>();
  final proc = await Process.start(chrome, [
    '--headless=new',
    '--user-data-dir=${tmp.path}',
    '--load-extension=$extDir',
    '--remote-debugging-port=0',
    '--no-first-run',
    '--disable-gpu',
    'about:blank',
  ]);
  proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((
    l,
  ) {
    final m = RegExp(r'DevTools listening on (ws://\S+)').firstMatch(l);
    if (m != null && !wsUrlCompleter.isCompleted) {
      wsUrlCompleter.complete(m.group(1)!);
    }
  });
  final wsUrl = await wsUrlCompleter.future.timeout(
    const Duration(seconds: 20),
    onTimeout: () => throw StateError('chrome devtools endpoint never came up'),
  );
  final ws = await WebSocket.connect(wsUrl);
  var msgId = 0;
  final pending = <int, Completer<Map<dynamic, dynamic>>>{};
  late final StreamSubscription<dynamic> wsSub;
  wsSub = ws.listen((raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    final id = msg['id'] as int?;
    if (id != null && pending.containsKey(id)) {
      pending
          .remove(id)!
          .complete(msg['result'] as Map<dynamic, dynamic>? ?? {});
    }
  });
  Future<Map<dynamic, dynamic>> send(
    String method, [
    Map<String, dynamic>? params,
    String? session,
  ]) {
    final id = ++msgId;
    final c = Completer<Map<dynamic, dynamic>>();
    pending[id] = c;
    ws.add(
      jsonEncode({
        'id': id,
        'method': method,
        'params': ?params,
        'sessionId': ?session,
      }),
    );
    return c.future;
  }

  // Wait for OUR extension's service worker (Chrome ships its own
  // component-extension workers — 'thunk.js' — that match a naive query).
  final ourId = extensionIdForPath(extDir);
  Map<dynamic, dynamic>? swTarget;
  for (var attempt = 0; attempt < 30 && swTarget == null; attempt++) {
    final targets = await send('Target.getTargets');
    final infos = targets['targetInfos'] as List;
    swTarget = infos.cast<Map<dynamic, dynamic>?>().firstWhere(
      (t) =>
          t != null &&
          (t['url'] as String?)!.startsWith('chrome-extension://$ourId/sw/'),
      orElse: () => null,
    );
    if (swTarget == null) {
      if (attempt % 5 == 4) {
        stderr.writeln(
          '=== targets so far: ${jsonEncode(
                (targets['targetInfos'] as List)
                    .map((t) => [t['type'], t['url']])
                    .take(12)
                    .toList(),
              )}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
  if (swTarget == null) {
    stderr.writeln('=== FAIL: extension service worker never registered');
    proc.kill();
    exit(1);
  }
  final sw = await send('Target.attachToTarget', {
    'targetId': swTarget['targetId'],
    'flatten': true,
  });
  final swSession = sw['sessionId'] as String;
  await send('Runtime.enable', null, swSession);
  stderr.writeln('=== sw target: ${swTarget['url'] as String}');
  final extOrigin = 'chrome-extension://$ourId';

  // Open the flutter panel page as the port client (the surface a real
  // panel uses). First navigations can race extension registration — retry.
  String pageSession = '';
  for (var attempt = 0; attempt < 6; attempt++) {
    final page = await send('Target.createTarget', {
      'url': '$extOrigin/panel/app/index.html',
    });
    final attached = await send('Target.attachToTarget', {
      'targetId': page['targetId'],
      'flatten': true,
    });
    pageSession = attached['sessionId'] as String;
    await send('Runtime.enable', null, pageSession);
    await Future<void>.delayed(const Duration(seconds: 2));
    final probe = await send('Runtime.evaluate', {
      'expression': "location.href",
      'returnByValue': true,
    }, pageSession);
    final href = probe['result']?['value'] as String? ?? '';
    if (href.startsWith('chrome-extension://')) break;
    stderr.writeln('=== nav retry $attempt: $href');
    await send('Target.closeTarget', {'targetId': page['targetId']});
  }

  // A known page to ask about later.
  await send('Target.createTarget', {'url': 'https://example.com/'});
  await Future<void>.delayed(const Duration(seconds: 2));

  final keyJson = jsonEncode(key);
  final driver =
      """
(async () => {
  const log = [];
  const fail = (m) => { log.push('FAIL: ' + m); };
  const ok = (m) => { log.push('PASS: ' + m); };
  const events = [];
  let port;
  try {
    port = chrome.runtime.connect({ name: 'fa-ui-v2' });
  } catch (e) { return JSON.stringify(['FAIL: port connect threw ' + e]); }
  port.onMessage.addListener((m) => events.push(m));
  const wait = (ms) => new Promise(r => setTimeout(r, ms));
  const until = async (pred, label, timeoutMs) => {
    const deadline = Date.now() + (timeoutMs || 30000);
    while (Date.now() < deadline) {
      if (pred()) return true;
      await wait(100);
    }
    fail('timeout waiting for ' + label);
    return false;
  };
  const kinds = () => events.map(e => e.kind);

  // 1. hello
  port.postMessage({ kind: 'hello', protoVersion: 2, capabilities: ['stream'] });
  if (!await until(() => kinds().includes('hello_ack'), 'hello_ack')) return done();
  ok('hello_ack');
  function done() { return JSON.stringify(log); }

  // 2. attach → attached + tools_state
  port.postMessage({ kind: 'attach' });
  if (!await until(() => kinds().includes('attached'), 'attached')) return done();
  ok('attached');
  if (!await until(() => kinds().includes('tools_state'), 'tools_state')) return done();
  const toolsMsg = [...events].reverse().find(e => e.kind === 'tools_state');
  const toolNames = (toolsMsg.tools || []).map(t => t.name);
  const enabledCount = (toolsMsg.tools || []).filter(t => t.enabled).length;
  (toolNames.length > 0 && enabledCount > 0)
    ? ok('tools_state: ' + toolNames.join(',') + ' (' + enabledCount + ' enabled)')
    : fail('tools_state empty or nothing enabled: ' + JSON.stringify(toolsMsg));

  // 3. configure the provider (settings_put)
  events.length = 0;
  port.postMessage({ kind: 'settings_put', settings: { faProvider: {
    baseUrl: ${jsonEncode(baseUrl)}, apiKey: $keyJson, model: ${jsonEncode(model)} } } });
  if (!await until(() => kinds().includes('settings_result'), 'settings_result')) return done();
  ok('settings_put accepted');

  // message_done fires for user AND tool records too — the turn is over
  // only when an ASSISTANT message_done lands.
  const assistantDones = () => events.filter(e => e.kind === 'message_done' &&
    e.message && e.message.role === 'assistant');
  const errs = () => events.filter(e => e.kind === 'error' ||
    (e.kind === 'stream' && e.event && e.event.type === 'error'));

  // 4. real turn: plain reply through the provider
  events.length = 0;
  port.postMessage({ kind: 'prompt', id: 'e2e-p1', text: 'Reply with exactly: OK' });
  await until(() => assistantDones().length > 0, 'plain assistant done', 120000);
  const text1 = assistantDones().map(e => e.message.text || '').join(' | ');
  errs().length === 0 && /OK/.test(text1)
    ? ok('plain turn replied: ' + JSON.stringify(text1.slice(0, 120)))
    : fail('plain turn: text=' + JSON.stringify(text1.slice(0, 200)) +
        ' errors=' + JSON.stringify(errs()).slice(0, 300));

  // 5. real turn through a browser tool; the SW gates tool calls behind
  // approvals — the panel answers them from its sheet, so do we. The
  // assistant's toolcall message ends (empty text) BEFORE the approval —
  // wait for the assistant count to GROW past that.
  events.length = 0;
  port.postMessage({ kind: 'prompt', id: 'e2e-p2',
    text: 'Call the browser_active_tab tool and reply with only the URL it reports.' });
  const approvalsSeen = () => events.filter(e => e.kind === 'approval_request');
  await until(() => approvalsSeen().length > 0, 'approval_request', 60000);
  const baseline = assistantDones().length;
  for (const e of approvalsSeen()) {
    port.postMessage({ kind: 'approval_response', id: e.id, decision: 'allow' });
  }
  await until(() => assistantDones().length > baseline,
      'post-approval assistant done', 120000);
  const text2 = assistantDones().map(e => e.message.text || '').join(' | ');
  const toolEvents = events.filter(e => e.kind === 'stream' && e.event &&
    (e.event.type === 'tool_result' || e.event.type === 'toolcall_end' ||
     e.event.type === 'tool_end' || e.event.type === 'tool_start'));
  text2.includes('example.com')
    ? ok('tool turn saw example.com: ' + JSON.stringify(text2.slice(0, 160)))
    : fail('tool turn: text=' + JSON.stringify(text2.slice(0, 300)) +
        ' toolEvents=' + JSON.stringify(toolEvents).slice(0, 400) +
        ' allEvents=' + JSON.stringify(events).slice(0, 1500));

  return done();
})()
""";
  final probe = await send('Runtime.evaluate', {
    'expression':
        "location.href + ' chrome=' + (typeof chrome) + ' runtime=' + (typeof chrome?.runtime)",
    'returnByValue': true,
  }, pageSession);
  stderr.writeln('=== probe: ${jsonEncode(probe['result'])}');
  final res = await send('Runtime.evaluate', {
    'expression': driver,
    'returnByValue': true,
    'awaitPromise': true,
    'timeout': 200000,
  }, pageSession);
  final value = res['result']?['value'];
  final lines = <String>[];
  if (value is String) {
    try {
      lines.addAll((jsonDecode(value) as List).cast<String>());
    } catch (_) {
      lines.add('FAIL: driver returned non-JSON: ${value.substring(0, 400)}');
    }
  } else {
    lines.add('FAIL: driver returned ${jsonEncode(res).substring(0, 400)}');
  }
  var failed = false;
  for (final l in lines) {
    stderr.writeln('=== $l');
    if (l.startsWith('FAIL')) failed = true;
  }
  if (lines.isEmpty) {
    stderr.writeln('=== FAIL: no report from the driver');
    failed = true;
  }

  wsSub.cancel();
  proc.kill();
  await tmp.delete(recursive: true).catchError((_) => tmp);
  exit(failed ? 1 : 0);
}

/// The unpacked-extension id: SHA-256 of the manifest `key` — first 16
/// bytes, hex digits mapped 0-9a-f → a-p (see check_extension_panel.dart).
String extensionIdForPath(String path) {
  final manifest =
      jsonDecode(File('$path/manifest.json').readAsStringSync())
          as Map<String, dynamic>;
  final key = manifest['key'] as String?;
  final List<int> input = key != null ? base64Decode(key) : utf8.encode(path);
  final digest = sha256.convert(input).bytes;
  const letters = 'abcdefghijklmnop';
  return digest
      .take(16)
      .map((b) => letters[(b >> 4) & 0xf] + letters[b & 0xf])
      .join();
}
