// Interactive UI driver for the extension panel: keeps a Chrome for
// Testing instance alive with the built extension loaded, and performs
// single actions per invocation so the flow can be driven step by step
// while inspecting screenshots between steps.
//
//   dart run scripts/ui_drive.dart boot           # launch chrome+panel
//   dart run scripts/ui_drive.dart shot [name]    # screenshot -> /tmp
//   dart run scripts/ui_drive.dart tap X Y        # mouse click
//   dart run scripts/ui_drive.dart type TEXT      # keyboard text
//   dart run scripts/ui_drive.dart key CODE       # special key (Enter=13)
//   dart run scripts/ui_drive.dart eval JS        # page JS (wires only)
//   dart run scripts/ui_drive.dart kill           # close chrome
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const debugPort = 9223;
const profileDir = '/tmp/fa_ui_drive_profile';
final chromeBin =
    '${Platform.environment['HOME']}/.cache/fa-chrome-for-testing/'
    'chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/'
    'Google Chrome for Testing';

Future<void> main(List<String> args) async {
  final cmd = args.first;
  if (cmd == 'kill') {
    await Process.run('pkill', ['-f', 'fa_ui_drive_profile']);
    exit(0);
  }
  if (cmd == 'boot') {
    await Process.run('unzip', [
      '-qo',
      'build/fa-extension.zip',
      '-d',
      'build/fa-extension',
    ]);

    final proc = await Process.start(chromeBin, [
      '--headless=new',
      '--user-data-dir=$profileDir',
      '--load-extension=${Directory.current.path}/build/fa-extension',
      '--remote-debugging-port=$debugPort',
      '--no-first-run',
      '--disable-gpu',
      '--window-size=1000,900',
      'about:blank',
    ]);
    proc.stderr.listen((_) {}, onDone: () {});
    await Future<void>.delayed(const Duration(seconds: 4));
    final ws = await _connect();
    final targets = await _sendFn('Target.getTargets', null, null);
    final infos = targets['targetInfos'] as List;
    final sw = infos.cast<Map<dynamic, dynamic>?>().firstWhere(
      (t) => t != null && (t['url'] as String?)!.contains('/sw/main.js'),
      orElse: () => null,
    );
    if (sw == null) {
      stderr.writeln('=== FATAL: extension did not load');
      exit(3);
    }
    final extOrigin = (sw['url'] as String).split('/sw/').first;
    final client = HttpClient();
    final req = await client.openUrl(
      'PUT',
      Uri.parse(
        'http://127.0.0.1:$debugPort/json/new?$extOrigin/panel/app/index.html',
      ),
    );
    await req.close();
    client.close();
    await Future<void>.delayed(const Duration(seconds: 8));
    final session = await _panelSession(ws);
    stderr.writeln('=== panel session: $session');
    exit(0);
  }
  final ws = await _connect();
  final session = (cmd == 'swlogs' || cmd == 'sweval')
      ? await _swSession(
          ws,
          poll: true,
          expr: (cmd == 'sweval' && args.length > 1) ? args[1] : null,
        )
      : await _panelSession(ws);
  final consoleLines = <String>[];
  uiDriveOnEvent = (msg) {
    if ((msg['sessionId'] as String?) != session) return;
    if (msg['method'] == 'Runtime.consoleAPICalled') {
      final params = (msg['params'] ?? {}) as Map<String, dynamic>;
      final text = (params['args'] as List? ?? [])
          .map((a) => (a as Map)['value'] ?? a['description'] ?? '')
          .join(' ');
      if (text.isNotEmpty) consoleLines.add('[console] $text');
    } else if (msg['method'] == 'Log.entryAdded') {
      final entry =
          ((msg['params'] ?? {}) as Map<String, dynamic>)['entry']
              as Map<String, dynamic>;
      consoleLines.add('[${entry['level']}] ${entry['text']}');
    }
  };
  if (cmd == 'swlogs' && session.isEmpty) {
    stderr.writeln('=== no service worker target found');
    exit(4);
  }
  final watchFor = (cmd == 'logs' || cmd == 'reload' || cmd == 'swlogs')
      ? (args.length > 1 ? int.parse(args[1]) : 12)
      : 1;
  Future<void> delay() async {
    await Future<void>.delayed(Duration(seconds: watchFor));
    for (final l in consoleLines) {
      stderr.writeln('LOG $l');
    }
  }

  switch (cmd) {
    case 'shot':
      await _send(ws, 'Page.enable', null, session);
      final res = await _send(ws, 'Page.captureScreenshot', {
        'format': 'png',
      }, session);
      stderr.writeln('=== res keys: ${res.keys.toList()}');
      if (res['_cdpError'] != null) {
        stderr.writeln('=== cdpError: ${jsonEncode(res['_cdpError'])}');
      }
      final data = res['data'] as String? ?? '';
      final name = args.length > 1 ? args[1] : 'ui';
      File('/tmp/ui_$name.png').writeAsBytesSync(base64Decode(data));
      stderr.writeln('=== /tmp/ui_$name.png');
    case 'tap':
      final x = int.parse(args[1]);
      final y = int.parse(args[2]);
      for (final entry in [
        {
          'type': 'mousePressed',
          'x': x,
          'y': y,
          'button': 'left',
          'clickCount': 1,
        },
        {
          'type': 'mouseReleased',
          'x': x,
          'y': y,
          'button': 'left',
          'clickCount': 1,
        },
      ]) {
        await _send(
          ws,
          'Input.dispatchMouseEvent',
          Map<String, dynamic>.from(entry),
          session,
        );
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
      stderr.writeln('=== tapped $x,$y');
    case 'type':
      for (final ch in args[1].runes) {
        await _send(ws, 'Input.dispatchKeyEvent', {
          'type': 'keyDown',
          'text': String.fromCharCode(ch),
          'unmodifiedText': String.fromCharCode(ch),
        }, session);
        await _send(ws, 'Input.dispatchKeyEvent', {
          'type': 'keyUp',
          'text': String.fromCharCode(ch),
          'unmodifiedText': String.fromCharCode(ch),
        }, session);
      }
      stderr.writeln('=== typed');
    case 'key':
      await _send(ws, 'Input.dispatchKeyEvent', {
        'type': 'rawKeyDown',
        'windowsVirtualKeyCode': int.parse(args[1]),
        'code': 'Enter',
      }, session);
      await _send(ws, 'Input.dispatchKeyEvent', {
        'type': 'keyUp',
        'windowsVirtualKeyCode': int.parse(args[1]),
        'code': 'Enter',
      }, session);
      stderr.writeln('=== key ${args[1]}');
    case 'eval':
    case 'sweval':
      final res = await _send(ws, 'Runtime.evaluate', {
        'expression': args[1],
        'returnByValue': true,
        'awaitPromise': true,
      }, session);
      stderr.writeln('=== ${jsonEncode(res['result'])}');
    case 'scroll':
      final sx = int.parse(args[1]);
      final sy = int.parse(args[2]);
      final dy = int.parse(args[3]);
      await _send(ws, 'Input.dispatchMouseEvent', {
        'type': 'mouseWheel',
        'x': sx,
        'y': sy,
        'deltaX': 0,
        'deltaY': dy,
      }, session);
      stderr.writeln('=== scrolled');
    case 'reload':
      await _send(ws, 'Page.reload', null, session);
      stderr.writeln('=== reloaded');
    case 'logs':
      break; // passive watch — handled below
  }
  await delay();
  exit(0);
}

Future<WebSocket> _connect() async {
  final meta = await _json('http://127.0.0.1:$debugPort/json/version');
  final wsUrl = (meta as Map)['webSocketDebuggerUrl'] as String;
  final ws = await WebSocket.connect(wsUrl);
  var id = 0;
  final pending = <int, Completer<Map<dynamic, dynamic>>>{};
  ws.listen((raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    final msgId = msg['id'] as int?;
    if (msgId != null && pending.containsKey(msgId)) {
      final result = (msg['result'] ?? const {}) as Map<dynamic, dynamic>;
      if (msg['error'] != null) result['_cdpError'] = msg['error'];
      pending.remove(msgId)!.complete(result);
      return;
    }
    if (msg['method'] != null) uiDriveOnEvent?.call(msg);
  });
  _sendFn = (method, params, session) {
    final c = Completer<Map<dynamic, dynamic>>();
    final msgId = ++id;
    pending[msgId] = c;
    ws.add(
      jsonEncode({
        'id': msgId,
        'method': method,
        'params': ?params,
        'sessionId': ?session,
      }),
    );
    return c.future;
  };
  return ws;
}

Future<Map<dynamic, dynamic>> Function(String, Map<String, dynamic>?, String?)
_sendFn = (_, _, _) async => <dynamic, dynamic>{};

void Function(Map<String, dynamic> event)? uiDriveOnEvent;

Future<Map<dynamic, dynamic>> _send(
  WebSocket ws,
  String method,
  Map<String, dynamic>? params,
  String? session,
) => _sendFn(method, params, session);

Future<String> _swSession(
  WebSocket ws, {
  bool poll = false,
  String? expr,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  Map<dynamic, dynamic>? sw;
  while (true) {
    final targets = await _sendFn('Target.getTargets', null, null);
    final infos = targets['targetInfos'] as List;
    sw = infos.cast<Map<dynamic, dynamic>?>().firstWhere(
      (t) =>
          t != null &&
          t['type'] == 'service_worker' &&
          (t['url'] as String?)!.contains('/sw/'),
      orElse: () => null,
    );
    if (sw != null || !poll || DateTime.now().isAfter(deadline)) break;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  if (sw == null) return '';
  final attached = await _sendFn('Target.attachToTarget', {
    'targetId': sw['targetId'],
    'flatten': true,
  }, null);
  final session = attached['sessionId'] as String;
  await _sendFn('Runtime.enable', null, session);
  await _sendFn('Log.enable', null, session);
  final probeExpr =
      expr ??
      r'JSON.stringify({faSw: typeof globalThis.faSw, faAgent: typeof globalThis.faAgent, keys: Object.keys(globalThis.faSw ?? {}), state: globalThis.faAgent ? globalThis.faAgent.getState() : null})';
  final probe = await _sendFn('Runtime.evaluate', {
    'expression': probeExpr,
    'returnByValue': true,
  }, session);
  stderr.writeln("=== sw eval: ${jsonEncode(probe['result'])}");
  return session;
}

Future<String> _panelSession(WebSocket ws) async {
  final targets = await _sendFn('Target.getTargets', null, null);
  final infos = targets['targetInfos'] as List;
  final page = infos.cast<Map<dynamic, dynamic>?>().firstWhere(
    (t) =>
        t != null &&
        (t['url'] as String?)!.contains('panel/app/index.html') &&
        t['type'] == 'page',
    orElse: () => null,
  );
  if (page == null) throw StateError('panel page not found');
  final attached = await _sendFn('Target.attachToTarget', {
    'targetId': page['targetId'],
    'flatten': true,
  }, null);
  final session = attached['sessionId'] as String;
  await _sendFn('Runtime.enable', null, session);
  await _sendFn('Log.enable', null, session);
  await _sendFn('Page.enable', null, session);
  return session;
}

Future<dynamic> _json(String url) async {
  final client = HttpClient();
  final request = await client.getUrl(Uri.parse(url));
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  client.close();
  return jsonDecode(body);
}
